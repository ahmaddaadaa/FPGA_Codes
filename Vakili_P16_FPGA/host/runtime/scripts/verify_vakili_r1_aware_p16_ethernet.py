#!/usr/bin/env python3
"""Connect to and verify either P16 arithmetic core over the UDP endpoint."""

import argparse
import socket
import struct
import time
from pathlib import Path

import numpy as np

from evaluate_fixed_vakili_r1_ptq import approximate_inference
from export_hardware_exact_p16_reference import (
    VALIDATION_EXAMPLES, exact_inference, load_and_validate_tensors,
    quantize_inputs, read_json, repository_root,
)
from vakili_r1_reference import build_adapt_activation_weight_lut
from verify_vakili_r1_aware_p16_uart import (
    load_selected_samples, make_packet as make_uart_packet,
    print_confusion_matrix, read_packet,
)

MAGIC = b"VAKI"
VERSION = 1
CMD_PING = 0x01
CMD_INFER = 0x02
CMD_WRITE_WEIGHT = 0x03
CMD_WRITE_BIAS = 0x04
RSP_PING = 0x81
RSP_INFER = 0x82
RSP_WRITE_WEIGHT = 0x83
RSP_WRITE_BIAS = 0x84
HEADER = struct.Struct("!4sBBBBIHH")
NUM_INPUTS = 784
NUM_OUTPUTS = 10
CORE_CLOCK_HZ = 100_000_000
CORE_LATENCY_CYCLES = 3407
MNIST_TEST_IMAGES = 10_000
MNIST_TRAIN_IMAGES = 60_000
MNIST_TOTAL_IMAGES = MNIST_TEST_IMAGES + MNIST_TRAIN_IMAGES
DIAGNOSTIC = struct.Struct("!6HI")
LIVE_DIAGNOSTIC = struct.Struct("!8H")
RECEIVE_DIAGNOSTIC = struct.Struct("!8H")
UART_CMD_READ_DIAGNOSTICS = 0x03
UART_RSP_DIAGNOSTICS = 0x83
DIAGNOSTIC_FLAGS = (
    "infer_command_seen",
    "ipv4_udp_app_valid",
    "lengths_and_image_valid",
    "request_accepted",
    "accelerator_busy_seen",
    "completion_seen",
    "inference_reply_queued",
    "bad_ethernet_fcs",
    "phy_rx_error",
    "request_rejected_busy",
)
LIVE_DIAGNOSTIC_FLAGS = (
    "response_valid",
    "awaiting_inference",
    "accelerator_busy",
    "rx_active",
    "rx_in_frame",
    "response_taken",
    "phy_crsdv",
    "phy_rx_error",
    "rmii_rx_enable_phase",
    "rmii_tx_enable_phase",
)
TX_STATE_NAMES = (
    "IDLE", "CHECKSUM", "CHECKSUM_FOLD", "CHECKSUM_FINAL", "BUILD",
    "PREAMBLE", "DATA", "FCS", "IFG",
)

DATASET_DISPLAY_NAMES = {
    "official-test": "MNIST test set",
    "development": "MNIST development set",
}


def packet(command, sequence, body=b"", address=0):
    if not 0 <= address <= 0xFFFF:
        raise ValueError("application address must fit in 16 bits")
    return HEADER.pack(MAGIC, VERSION, command, 0, HEADER.size,
                       sequence, len(body), address) + body


def load_evaluation_dataset(args):
    """Load the requested finite dataset range without repeating images."""
    if args.dataset != "mnist":
        return load_selected_samples(args)

    from torchvision.datasets import MNIST

    stop = args.sample_start + args.sample_count
    pixel_parts = []
    label_parts = []
    names = []

    if args.sample_start < MNIST_TEST_IMAGES:
        test = MNIST(
            str(args.data_root), train=False, download=args.mnist_download)
        test_start = args.sample_start
        test_stop = min(stop, MNIST_TEST_IMAGES)
        pixel_parts.append(
            test.data[test_start:test_stop].numpy().reshape(-1, NUM_INPUTS))
        label_parts.append(test.targets[test_start:test_stop].numpy())
        names.extend(
            "mnist-test-{}".format(index)
            for index in range(test_start, test_stop)
        )

    if stop > MNIST_TEST_IMAGES:
        train = MNIST(
            str(args.data_root), train=True, download=args.mnist_download)
        train_start = max(0, args.sample_start - MNIST_TEST_IMAGES)
        train_stop = stop - MNIST_TEST_IMAGES
        pixel_parts.append(
            train.data[train_start:train_stop].numpy().reshape(-1, NUM_INPUTS))
        label_parts.append(train.targets[train_start:train_stop].numpy())
        names.extend(
            "mnist-train-{}".format(index)
            for index in range(train_start, train_stop)
        )

    pixels = np.concatenate(pixel_parts).astype(np.uint8, copy=False)
    labels = np.concatenate(label_parts).astype(np.int64, copy=False)
    if len(pixels) != args.sample_count:
        raise RuntimeError(
            "loaded {} MNIST images, expected {}".format(
                len(pixels), args.sample_count))
    return pixels, labels, names, {
        "name": "mnist_test_then_train",
        "sample_start": args.sample_start,
        "sample_count": args.sample_count,
    }


def parse_response(data, command, sequence, body_length):
    if len(data) != HEADER.size + body_length:
        raise RuntimeError("response length {} != {}".format(
            len(data), HEADER.size + body_length))
    magic, version, actual_command, status, header_length, actual_sequence, length, _ = HEADER.unpack_from(data)
    if (magic, version, actual_command, header_length, actual_sequence, length) != (
            MAGIC, VERSION, command, HEADER.size, sequence, body_length):
        raise RuntimeError(
            "invalid Ethernet response header: command=0x{:02x} "
            "sequence={} body={} bytes={}".format(
                actual_command, actual_sequence, length, len(data)))
    if status != 0:
        raise RuntimeError("board returned status 0x{:02x}".format(status))
    return data[HEADER.size:]


def transact(sock, address, request, response_command, sequence, body_length, retries):
    errors = []
    for attempt in range(1, retries + 2):
        try:
            sock.sendto(request, address)
            data, sender = sock.recvfrom(2048)
            if sender[0] != address[0]:
                errors.append("attempt {}: response from unexpected {}:{}".format(
                    attempt, *sender))
                continue
            body = parse_response(
                data, response_command, sequence, body_length)
            if attempt > 1:
                print("WARNING: Ethernet transaction sequence {} succeeded on "
                      "attempt {} after {}".format(
                          sequence, attempt, "; ".join(errors)))
            return body
        except socket.timeout:
            errors.append("attempt {}: timed out after {:.3f} s".format(
                attempt, sock.gettimeout()))
        except RuntimeError as exc:
            errors.append("attempt {}: {}".format(attempt, exc))
    raise RuntimeError("board did not return a valid response; {}".format(
        "; ".join(errors)))


def print_diagnostics(body):
    if len(body) not in (
            DIAGNOSTIC.size,
            DIAGNOSTIC.size + LIVE_DIAGNOSTIC.size,
            DIAGNOSTIC.size + LIVE_DIAGNOSTIC.size + RECEIVE_DIAGNOSTIC.size):
        raise RuntimeError("diagnostic body has unsupported length {}".format(
            len(body)))
    flags, frame_bytes, image_bytes, body_length, udp_length, ip_length, sequence = DIAGNOSTIC.unpack(
        body[:DIAGNOSTIC.size])
    stages = [name for bit, name in enumerate(DIAGNOSTIC_FLAGS)
              if flags & (1 << bit)]
    print("FPGA diagnostics: flags=0x{:04x} [{}]".format(
        flags, ", ".join(stages) if stages else "no inference observed"))
    print("  last inference: sequence={} frame={} image={} body={} udp={} ip={}".format(
        sequence, frame_bytes, image_bytes, body_length, udp_length, ip_length))
    if len(body) > DIAGNOSTIC.size:
        (live_flags, tx_state, tx_data_length, tx_byte_index,
         tx_dibit_index, tx_ifg_dibit, rx_frame_index,
         response_kind) = LIVE_DIAGNOSTIC.unpack(
             body[DIAGNOSTIC.size:
                  DIAGNOSTIC.size + LIVE_DIAGNOSTIC.size])
        live = [name for bit, name in enumerate(LIVE_DIAGNOSTIC_FLAGS)
                if live_flags & (1 << bit)]
        tx_state_name = (TX_STATE_NAMES[tx_state]
                         if tx_state < len(TX_STATE_NAMES)
                         else "UNKNOWN_{}".format(tx_state))
        print("  live endpoint: flags=0x{:04x} [{}] tx_state={} "
              "tx_length={} tx_byte={} tx_dibit={} ifg_dibit={} "
              "rx_frame={} response_kind={}".format(
                  live_flags, ", ".join(live) if live else "idle",
                  tx_state_name, tx_data_length, tx_byte_index,
                  tx_dibit_index, tx_ifg_dibit, rx_frame_index,
                  response_kind))
    if len(body) > DIAGNOSTIC.size + LIVE_DIAGNOSTIC.size:
        (carrier_events, sfd_events, completed_frames, good_fcs_frames,
         no_sfd_events, last_preamble_dibits, last_completed_frame_bytes,
         last_command) = RECEIVE_DIAGNOSTIC.unpack(
             body[DIAGNOSTIC.size + LIVE_DIAGNOSTIC.size:])
        print("  RMII receive: carrier={} sfd={} completed={} good_fcs={} "
              "no_sfd={} last_preamble_dibits={} last_frame={} "
              "last_command=0x{:02x}".format(
                  carrier_events, sfd_events, completed_frames,
                  good_fcs_frames, no_sfd_events,
                  last_preamble_dibits, last_completed_frame_bytes,
                  last_command & 0xFF))
    return flags


def query_diagnostics(sock, endpoint, sequence, retries):
    body = transact(sock, endpoint, packet(CMD_PING, sequence), RSP_PING,
                    sequence, DIAGNOSTIC.size, retries)
    return print_diagnostics(body)


def query_uart_diagnostics(port="COM5", baud=1_000_000, timeout=2.0):
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("Install pyserial in the active Windows environment") from exc
    print("Reading out-of-band Ethernet diagnostics over {}...".format(port))
    with serial.Serial(port, baud, timeout=timeout) as device:
        time.sleep(0.05)
        device.reset_input_buffer()
        device.write(make_uart_packet(UART_CMD_READ_DIAGNOSTICS))
        device.flush()
        command, _, payload = read_packet(device)
    if command != UART_RSP_DIAGNOSTICS or len(payload) != 48:
        raise RuntimeError(
            "unexpected UART diagnostics response command=0x{:02x} bytes={}".format(
                command, len(payload)))
    return print_diagnostics(payload)


def arguments():
    root = repository_root()
    parser = argparse.ArgumentParser()
    parser.add_argument("--test-connect", action="store_true",
                        help="ping the FPGA endpoint without loading parameters or running inference")
    parser.add_argument("--board-ip", default="192.168.7.2")
    parser.add_argument("--host-ip", default="192.168.7.1")
    parser.add_argument("--udp-port", type=int, default=5005)
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--uart-diagnostic-port", default="COM5")
    parser.add_argument("--uart-diagnostic-baud", type=int, default=1_000_000)
    parser.add_argument("--uart-diagnostic-timeout", type=float, default=2.0)
    parser.add_argument(
        "--diagnostics", action="store_true",
        help="print detailed Ethernet endpoint diagnostics")
    parser.add_argument(
        "--uart-diagnostics", action="store_true",
        help="also query the optional legacy UART diagnostic interface")
    parser.add_argument(
        "--no-uart-diagnostics", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--dataset", choices=("mnist", "official-test", "development"),
        default="mnist",
        help=("dataset to evaluate; mnist uses the 10,000 test images first, "
              "followed by the 60,000 training images"))
    parser.add_argument(
        "--sample-start", type=int, default=0,
        help="zero-based position in the selected finite dataset")
    parser.add_argument(
        "--sample-count", type=int, default=VALIDATION_EXAMPLES,
        help="number of images to evaluate (default: 10000; maximum: 70000)")
    parser.add_argument(
        "--progress-every", type=int, default=1,
        help="print progress every N images; use 0 for summary only")
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--output-chunk", type=int, default=8)
    parser.add_argument("--show-confusion", action="store_true")
    parser.add_argument("--mnist-download", action="store_true")
    parser.add_argument("--data-root", type=Path, default=root / "data/MNIST")
    parser.add_argument(
        "--arithmetic", choices=("vakili-r1", "exact"),
        default="vakili-r1",
        help="software reference arithmetic expected from the programmed P16 image",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "architectures/vakili_adapt_ga_hls/models/manifests/vakili_r1_aware_development_frozen.json",
    )
    args = parser.parse_args()
    if args.sample_count < 1:
        parser.error("--sample-count must be positive")
    if args.sample_start < 0:
        parser.error("--sample-start cannot be negative")
    dataset_size = (
        MNIST_TOTAL_IMAGES if args.dataset == "mnist"
        else VALIDATION_EXAMPLES
    )
    if args.sample_start + args.sample_count > dataset_size:
        parser.error(
            "requested range exceeds the selected dataset's {} images".format(
                dataset_size))
    if args.progress_every < 0:
        parser.error("--progress-every cannot be negative")
    return args


def main():
    args = arguments()
    endpoint = (args.board_ip, args.udp_port)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.host_ip, 0))
        sock.settimeout(args.timeout)
        sequence = int(time.time()) & 0xFFFFFFFF
        if args.test_connect:
            if args.diagnostics:
                query_diagnostics(sock, endpoint, sequence, args.retries)
            else:
                transact(
                    sock, endpoint, packet(CMD_PING, sequence), RSP_PING,
                    sequence, DIAGNOSTIC.size, args.retries)
            print("Ethernet connection successful")
            print("FPGA endpoint: {}:{}".format(*endpoint))
            return

        root = repository_root()
        manifest = read_json(args.manifest)
        _, tensors = load_and_validate_tensors(root, manifest)
        pixels, labels, names, _metadata = load_evaluation_dataset(args)
        inputs = quantize_inputs(
            pixels, float(manifest["quantization_contract"]["input_scale"]))
        shifts = manifest["quantization_contract"]["hidden_shifts"]
        if args.arithmetic == "exact":
            reference_logits, _, _, _ = exact_inference(
                inputs, tensors, shifts, args.batch_size)
            reference_name = "exact INT8"
        else:
            reference_logits, _, _, _ = approximate_inference(
                inputs, tensors, shifts, build_adapt_activation_weight_lut(),
                args.batch_size, args.output_chunk)
            reference_name = "Vakili R1"

        correct = 0
        prediction_matches = 0
        logit_vector_matches = 0
        logit_value_mismatches = 0
        confusion = np.zeros((10, 10), dtype=np.int64)
        start = time.perf_counter()
        for offset in range(args.sample_count):
            values = inputs[offset]
            sequence = (sequence + 1) & 0xFFFFFFFF
            body = np.asarray(values, dtype=np.int8).tobytes()
            if len(body) != NUM_INPUTS:
                raise RuntimeError("quantized image is not 784 bytes")
            try:
                response = transact(
                    sock, endpoint, packet(CMD_INFER, sequence, body),
                    RSP_INFER, sequence, 44, args.retries)
            except RuntimeError as inference_error:
                if args.diagnostics:
                    print("Inference response failed; querying FPGA stage diagnostics...")
                    if (args.uart_diagnostics and
                            not args.no_uart_diagnostics):
                        try:
                            query_uart_diagnostics(
                                args.uart_diagnostic_port,
                                args.uart_diagnostic_baud,
                                args.uart_diagnostic_timeout)
                        except RuntimeError as uart_diagnostic_error:
                            print("UART diagnostic query failed: {}".format(
                                uart_diagnostic_error))
                    diagnostic_sequence = (sequence ^ 0x80000000) & 0xFFFFFFFF
                    try:
                        query_diagnostics(
                            sock, endpoint, diagnostic_sequence, args.retries)
                    except RuntimeError as diagnostic_error:
                        print("FPGA diagnostic query also failed: {}".format(
                            diagnostic_error))
                raise inference_error
            logits = np.asarray(struct.unpack("!10i", response[4:44]), dtype=np.int32)
            prediction = int(np.argmax(logits))
            expected_logits = reference_logits[offset]
            label = int(labels[offset])
            expected = int(np.argmax(expected_logits))
            correct += prediction == label
            prediction_matches += prediction == expected
            vector_matches = bool(np.all(logits == expected_logits))
            logit_vector_matches += vector_matches
            logit_value_mismatches += int(np.count_nonzero(
                logits != expected_logits))
            confusion[label, prediction] += 1
            done = offset + 1
            show_progress = (
                args.progress_every > 0 and
                (done == 1 or done == args.sample_count or
                 done % args.progress_every == 0)
            )
            if show_progress:
                name = names[offset]
                print("{:6d}/{:<6d} {:>20s} label={} reference={} fpga={} "
                      "accuracy={:6.2f}% reference_match={:6.2f}%".format(
                          done, args.sample_count, name, label, expected,
                          prediction, 100.0 * correct / done,
                          100.0 * prediction_matches / done))
        elapsed = time.perf_counter() - start

    compute_throughput = CORE_CLOCK_HZ / CORE_LATENCY_CYCLES
    compute_time_us = 1_000_000.0 / compute_throughput
    if (args.dataset == "mnist" and
            args.sample_start + args.sample_count <= MNIST_TEST_IMAGES):
        dataset_name = "MNIST test set"
    elif args.dataset == "mnist":
        dataset_name = "MNIST"
    else:
        dataset_name = DATASET_DISPLAY_NAMES[args.dataset]

    def summary_value(label, value):
        print("  {:<34} {}".format(label + ":", value))

    print("\nEthernet evaluation summary")
    summary_value("Dataset", dataset_name)
    summary_value("FPGA arithmetic", reference_name)
    summary_value("Images evaluated", args.sample_count)
    summary_value(
        "Ethernet throughput",
        "{:.2f} images/s ({:.2f} s)".format(
            args.sample_count / elapsed, elapsed),
    )
    summary_value(
        "FPGA throughput estimate",
        "{:.2f} images/s ({:.2f} us/image)".format(
            compute_throughput, compute_time_us),
    )
    print("")
    summary_value(
        "FPGA prediction accuracy",
        "{}/{} = {:.2f}%".format(
            correct, args.sample_count,
            100.0 * correct / args.sample_count),
    )
    summary_value(
        "FPGA vs. ref model predictions",
        "{}/{} = {:.2f}%".format(
            prediction_matches, args.sample_count,
            100.0 * prediction_matches / args.sample_count),
    )
    summary_value(
        "Logit vectors vs. ref model",
        "{}/{} = {:.2f}%".format(
            logit_vector_matches, args.sample_count,
            100.0 * logit_vector_matches / args.sample_count),
    )
    if args.show_confusion:
        print_confusion_matrix(confusion)
    if logit_value_mismatches:
        raise RuntimeError(
            "FPGA logits differ from the reference model ({} values)".format(
                logit_value_mismatches))


if __name__ == "__main__":
    main()
