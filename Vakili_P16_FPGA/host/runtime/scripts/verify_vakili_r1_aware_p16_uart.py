#!/usr/bin/env python3
"""Verify the banked R1-aware P16 FPGA over the existing UART protocol."""

from __future__ import print_function

import argparse
import hashlib
import json
import struct
import time
from pathlib import Path

import numpy as np

from evaluate_fixed_vakili_r1_ptq import approximate_inference
from export_hardware_exact_p16_reference import (
    VALIDATION_EXAMPLES,
    exact_inference,
    load_and_validate_tensors,
    load_validation_samples,
    quantize_inputs,
    read_json,
    repository_root,
    sha256_file,
    write_json,
)
from vakili_r1_reference import (
    build_adapt_activation_weight_lut,
    int16_table_sha256,
)


START_BYTE = 0xAA
CMD_WRITE_WEIGHT = 0x01
CMD_WRITE_BIAS = 0x02
CMD_WRITE_INPUT = 0x03
CMD_START = 0x04
CMD_READ_OUTPUT = 0x05
CMD_STATUS = 0x06
CMD_STREAM_INPUT = 0x07
CMD_ACK = 0xF0
CMD_OUTPUT_DATA = 0x81
CMD_STATUS_DATA = 0x86
CMD_ERROR = 0xFF
MAX_PAYLOAD = 16
NUM_OUTPUTS = 10
P16_LANES = 16
WEIGHT_BANK_DEPTH = 3296
W2_BANK_BASE = 3136
W3_BANK_BASE = 3264
WEIGHT_WIRE_WORDS = P16_LANES * WEIGHT_BANK_DEPTH
STREAM_IMAGE_BYTES = 784
CORE_CLOCK_HZ = 100_000_000
CORE_LATENCY_CYCLES = 3407
EXPECTED_FP32_SHA256 = (
    "ad1fb7db0eced5d01d8e9f42da7eb23568fcdfd2ceaa3681cc551f1465223d1f"
)


def parse_args():
    root = repository_root()
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="COM5")
    parser.add_argument(
        "--dataset",
        choices=("development", "official-test"),
        default="official-test",
        help=(
            "development uses the frozen 10,000-image split from MNIST train; "
            "official-test uses canonical unshuffled MNIST test indices"
        ),
    )
    parser.add_argument("--baud", type=int, default=1_000_000)
    parser.add_argument(
        "--transport",
        choices=("stream-image", "chunked-v1"),
        default="stream-image",
        help=(
            "stream-image sends one 784-byte image command; chunked-v1 keeps "
            "the legacy forty-nine acknowledged input writes"
        ),
    )
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--sample-start", type=int, default=0)
    parser.add_argument("--sample-count", type=int, default=VALIDATION_EXAMPLES)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--output-chunk", type=int, default=8)
    parser.add_argument("--inter-packet-delay", type=float, default=0.001)
    parser.add_argument("--inference-timeout", type=float, default=2.0)
    parser.add_argument("--poll-delay", type=float, default=0.001)
    parser.add_argument("--skip-parameter-load", action="store_true")
    parser.add_argument("--show-confusion", action="store_true")
    parser.add_argument("--mnist-download", action="store_true")
    parser.add_argument(
        "--fp32-checkpoint",
        type=Path,
        default=root / "artifacts/mnist_fp32_baseline/final_mild_ls000/"
        "mnist_fp32_baseline.pt",
        help="Frozen FP32 behavioral reference checkpoint",
    )
    parser.add_argument(
        "--skip-fp32-reference",
        action="store_true",
        help="Run without the optional FP32 behavioral comparison",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "architectures/vakili_adapt_ga_hls/models/manifests/"
        "vakili_r1_aware_development_frozen.json",
    )
    parser.add_argument("--data-root", type=Path, default=root / "data/MNIST")
    parser.add_argument("--bitstream", type=Path, default=None)
    parser.add_argument("--report-path", type=Path, default=None)
    args = parser.parse_args()
    if args.sample_start < 0 or args.sample_start >= VALIDATION_EXAMPLES:
        parser.error("--sample-start must be between 0 and 9999")
    if args.sample_count < 1 or args.sample_start + args.sample_count > VALIDATION_EXAMPLES:
        parser.error("requested samples must fit the selected 10,000-image MNIST split")
    if args.batch_size < 1 or args.output_chunk < 1:
        parser.error("batch and output chunk sizes must be positive")
    if args.inter_packet_delay < 0 or args.poll_delay < 0:
        parser.error("delays cannot be negative")
    return args


def selected_sample_sha256(pixels, labels):
    digest = hashlib.sha256()
    digest.update(np.ascontiguousarray(pixels, dtype=np.uint8).tobytes())
    digest.update(np.ascontiguousarray(labels, dtype="<i8").tobytes())
    return digest.hexdigest()


def load_selected_samples(args):
    if args.dataset == "development":
        pixels, labels, names = load_validation_samples(
            args.data_root,
            args.mnist_download,
            args.sample_start,
            args.sample_count,
        )
        metadata = {
            "name": "mnist_training_development_validation",
            "split": "official_train",
            "selection": "seeded development permutation",
            "official_test_evaluated": False,
        }
    else:
        from torchvision.datasets import MNIST

        dataset = MNIST(
            str(args.data_root),
            train=False,
            download=args.mnist_download,
        )
        stop = args.sample_start + args.sample_count
        pixels = (
            dataset.data[args.sample_start:stop]
            .numpy()
            .reshape(-1, 28 * 28)
            .astype(np.uint8)
        )
        labels = (
            dataset.targets[args.sample_start:stop]
            .numpy()
            .astype(np.int64)
        )
        names = [
            "mnist-{}".format(index)
            for index in range(args.sample_start, stop)
        ]
        metadata = {
            "name": "mnist_official_test",
            "split": "official_test",
            "selection": "canonical unshuffled indices",
            "official_test_evaluated": True,
        }

    metadata.update({
        "sample_start": args.sample_start,
        "sample_count": args.sample_count,
        "sample_sha256": selected_sample_sha256(pixels, labels),
        "complete_split": (
            args.sample_start == 0 and args.sample_count == VALIDATION_EXAMPLES
        ),
    })
    metadata["evaluation_scope"] = (
        "complete_split" if metadata["complete_split"] else "subset"
    )
    metadata["final_accuracy_report"] = bool(
        metadata["official_test_evaluated"] and metadata["complete_split"]
    )
    return pixels, labels, names, metadata


def print_confusion_matrix(confusion):
    print("\nConfusion matrix (rows=true label, columns=predicted label):")
    print("     " + " ".join("{:4d}".format(index) for index in range(NUM_OUTPUTS)))
    for label in range(NUM_OUTPUTS):
        row = " ".join(
            "{:4d}".format(int(confusion[label, prediction]))
            for prediction in range(NUM_OUTPUTS)
        )
        print("{:4d}: {}".format(label, row))


def load_fp32_predictions(checkpoint, pixels, batch_size):
    """Evaluate the frozen original FP32 model on the selected raw pixels."""
    import torch

    from establish_mnist_fp32_baseline import MnistMlp

    if not checkpoint.is_file():
        raise RuntimeError(
            "Frozen FP32 checkpoint was not found: {}. Use "
            "--skip-fp32-reference only when that comparison is intentionally "
            "unavailable.".format(checkpoint)
        )
    actual_sha256 = sha256_file(checkpoint)
    if actual_sha256 != EXPECTED_FP32_SHA256:
        raise RuntimeError(
            "FP32 checkpoint SHA-256 {} does not match frozen {}".format(
                actual_sha256, EXPECTED_FP32_SHA256
            )
        )

    value = torch.load(str(checkpoint), map_location="cpu")
    if isinstance(value, dict):
        for key in ("state_dict", "model_state_dict", "model"):
            nested = value.get(key)
            if isinstance(nested, dict):
                value = nested
                break
    if not isinstance(value, dict):
        raise RuntimeError("FP32 checkpoint is not a state dictionary")

    state = {}
    for name, tensor in value.items():
        if not isinstance(tensor, torch.Tensor):
            continue
        name = str(name)
        if name.startswith("module."):
            name = name[len("module."):]
        state[name] = tensor

    model = MnistMlp()
    result = model.load_state_dict(state, strict=False)
    required = {
        "fc1.weight", "fc1.bias", "bc1.weight", "bc1.bias",
        "bc1.running_mean", "bc1.running_var",
        "fc2.weight", "fc2.bias", "bc2.weight", "bc2.bias",
        "bc2.running_mean", "bc2.running_var",
        "fc3.weight", "fc3.bias",
    }
    missing = sorted(required.intersection(result.missing_keys))
    if missing:
        raise RuntimeError(
            "FP32 checkpoint is missing required tensors: {}".format(
                ", ".join(missing)
            )
        )
    model.cpu()
    model.eval()

    values = torch.from_numpy(
        np.ascontiguousarray(pixels, dtype=np.float32)
    ).div_(255.0)
    predictions = []
    with torch.no_grad():
        for start in range(0, len(values), batch_size):
            outputs = model(values[start:start + batch_size])
            predictions.append(outputs.argmax(dim=1).cpu().numpy())
    return np.concatenate(predictions).astype(np.int64), actual_sha256


def checksum(value):
    return sum(value) & 0xFF


def make_packet(command, address=0, payload=b""):
    length = len(payload)
    header = bytes((
        START_BYTE,
        command & 0xFF,
        (address >> 8) & 0xFF,
        address & 0xFF,
        (length >> 8) & 0xFF,
        length & 0xFF,
    ))
    body = header + payload
    return body + bytes((checksum(body),))


def read_exact(serial_port, count):
    value = serial_port.read(count)
    if len(value) != count:
        raise RuntimeError("UART timeout: expected {} bytes, received {}".format(
            count, len(value)
        ))
    return value


def read_packet(serial_port):
    while True:
        value = read_exact(serial_port, 1)[0]
        if value == START_BYTE:
            break
    remainder = read_exact(serial_port, 5)
    command = remainder[0]
    address = (remainder[1] << 8) | remainder[2]
    length = (remainder[3] << 8) | remainder[4]
    payload = read_exact(serial_port, length)
    received_checksum = read_exact(serial_port, 1)[0]
    expected_checksum = checksum(bytes((START_BYTE,)) + remainder + payload)
    if received_checksum != expected_checksum:
        raise RuntimeError("UART response checksum mismatch")
    if command == CMD_ERROR:
        code = payload[0] if payload else None
        raise RuntimeError("FPGA returned protocol error {}".format(code))
    return command, address, payload


def send_packet(serial_port, command, address=0, payload=b"", delay=0.0):
    serial_port.write(make_packet(command, address, payload))
    serial_port.flush()
    if delay:
        time.sleep(delay)


def send_with_ack(serial_port, command, address=0, payload=b"", delay=0.0):
    send_packet(serial_port, command, address, payload, delay)
    response, _, response_payload = read_packet(serial_port)
    if response != CMD_ACK or response_payload != bytes((command,)):
        raise RuntimeError(
            "Unexpected ACK for command 0x{:02x}: command=0x{:02x}, payload={}".format(
                command, response, response_payload.hex()
            )
        )
    if delay:
        time.sleep(delay)


def write_int8_values(serial_port, command, values, delay, label):
    values = np.asarray(values, dtype=np.int8).reshape(-1)
    total = len(values)
    for start in range(0, total, MAX_PAYLOAD):
        end = min(total, start + MAX_PAYLOAD)
        payload = values[start:end].tobytes(order="C")
        send_with_ack(serial_port, command, start, payload, delay)
        if label and (end == total or end % 4096 == 0):
            print("{}: {}/{}".format(label, end, total))


def write_int32_values(serial_port, command, values, delay, label):
    values = np.asarray(values, dtype="<i4").reshape(-1)
    words_per_packet = MAX_PAYLOAD // 4
    total = len(values)
    for start in range(0, total, words_per_packet):
        end = min(total, start + words_per_packet)
        payload = values[start:end].tobytes(order="C")
        send_with_ack(serial_port, command, start, payload, delay)
        if label and (end == total or end % 32 == 0):
            print("{}: {}/{}".format(label, end, total))


def build_banked_weight_rows(tensors):
    """Convert output-major model tensors to [bank_address, lane] wire rows."""
    rows = np.zeros((WEIGHT_BANK_DEPTH, P16_LANES), dtype=np.int8)
    layer_specs = (
        ("w1", (64, 784), 0),
        ("w2", (32, 64), W2_BANK_BASE),
        ("w3", (10, 32), W3_BANK_BASE),
    )
    for name, expected_shape, bank_base in layer_specs:
        weights = np.asarray(tensors[name], dtype=np.int8)
        if weights.shape != expected_shape:
            raise RuntimeError(
                "{} has shape {}, expected {}".format(
                    name, weights.shape, expected_shape
                )
            )
        output_count, input_count = weights.shape
        for output_index in range(output_count):
            group_index = output_index // P16_LANES
            lane_index = output_index % P16_LANES
            address = bank_base + group_index * input_count
            rows[address:address + input_count, lane_index] = weights[output_index]
    return rows


def write_banked_int8_weights(serial_port, rows, delay):
    """Upload one 16-lane row per packet using {bank address, lane} addresses."""
    rows = np.asarray(rows, dtype=np.int8)
    if rows.shape != (WEIGHT_BANK_DEPTH, P16_LANES):
        raise RuntimeError("Unexpected banked weight shape {}".format(rows.shape))
    for bank_address, values in enumerate(rows):
        wire_address = bank_address * P16_LANES
        send_with_ack(
            serial_port,
            CMD_WRITE_WEIGHT,
            wire_address,
            values.tobytes(order="C"),
            delay,
        )
        completed = wire_address + P16_LANES
        if completed == WEIGHT_WIRE_WORDS or completed % 4096 == 0:
            print("weights: {}/{}".format(completed, WEIGHT_WIRE_WORDS))


def write_streamed_image(serial_port, values):
    values = np.asarray(values, dtype=np.int8).reshape(-1)
    if len(values) != STREAM_IMAGE_BYTES:
        raise RuntimeError(
            "Streamed image has {} bytes, expected {}".format(
                len(values), STREAM_IMAGE_BYTES
            )
        )
    send_with_ack(
        serial_port,
        CMD_STREAM_INPUT,
        address=0,
        payload=values.tobytes(order="C"),
        delay=0.0,
    )


def run_fpga_inference(serial_port, inputs, args):
    if args.transport == "stream-image":
        write_streamed_image(serial_port, inputs)
    else:
        write_int8_values(
            serial_port, CMD_WRITE_INPUT, inputs, args.inter_packet_delay, None
        )
    send_with_ack(
        serial_port, CMD_START, delay=args.inter_packet_delay
    )

    deadline = time.time() + args.inference_timeout
    while time.time() < deadline:
        send_packet(
            serial_port, CMD_STATUS, delay=args.inter_packet_delay
        )
        command, _, payload = read_packet(serial_port)
        if command != CMD_STATUS_DATA or len(payload) != 1:
            raise RuntimeError("Unexpected status response")
        busy = bool(payload[0] & 0x01)
        done = bool(payload[0] & 0x02)
        if done and not busy:
            break
        time.sleep(args.poll_delay)
    else:
        raise RuntimeError("FPGA inference timed out")

    send_packet(serial_port, CMD_READ_OUTPUT, delay=args.inter_packet_delay)
    command, _, payload = read_packet(serial_port)
    if command != CMD_OUTPUT_DATA or len(payload) != NUM_OUTPUTS * 4:
        raise RuntimeError("Unexpected output response")
    return np.asarray(struct.unpack("<{}i".format(NUM_OUTPUTS), payload), dtype=np.int32)


def main():
    args = parse_args()
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("Install pyserial in the active Windows environment") from exc

    root = repository_root()
    manifest = read_json(args.manifest)
    if manifest.get("status") != "frozen_fixed_vakili_r1_aware_development_candidate":
        raise RuntimeError("Manifest is not the frozen R1-aware candidate")
    tensor_path, tensors = load_and_validate_tensors(root, manifest)
    if sha256_file(tensor_path) != manifest["artifacts"]["integer_tensors"]["sha256"]:
        raise RuntimeError("Integer archive SHA-256 mismatch")

    lut = build_adapt_activation_weight_lut()
    if int16_table_sha256(lut) != manifest["vakili_r1_contract"]["adapt_raw_byte_lut_sha256"]:
        raise RuntimeError("Vakili-R1 LUT hash mismatch")

    pixels, labels, names, dataset_metadata = load_selected_samples(args)
    inputs = quantize_inputs(
        pixels, float(manifest["quantization_contract"]["input_scale"])
    )
    r1_logits, _, _, _ = approximate_inference(
        inputs,
        tensors,
        manifest["quantization_contract"]["hidden_shifts"],
        lut,
        args.batch_size,
        args.output_chunk,
    )
    exact_logits, _, _, _ = exact_inference(
        inputs,
        tensors,
        manifest["quantization_contract"]["hidden_shifts"],
        args.batch_size,
    )
    fp32_predictions = None
    fp32_sha256 = None
    if not args.skip_fp32_reference:
        fp32_predictions, fp32_sha256 = load_fp32_predictions(
            args.fp32_checkpoint, pixels, args.batch_size
        )

    r1_predictions = np.argmax(r1_logits, axis=1)
    exact_predictions = np.argmax(exact_logits, axis=1)

    banked_weights = build_banked_weight_rows(tensors)
    flat_biases = np.concatenate((
        tensors["b1"], tensors["b2"], tensors["b3"]
    )).astype(np.int32, copy=False)
    if banked_weights.size != WEIGHT_WIRE_WORDS or len(flat_biases) != 106:
        raise RuntimeError("Unexpected parameter storage count")

    quantization = manifest["quantization_contract"]
    model_weight_count = sum(
        int(np.asarray(tensors[name]).size) for name in ("w1", "w2", "w3")
    )
    dataset_label = (
        "official MNIST test split"
        if args.dataset == "official-test"
        else "frozen MNIST development-validation split"
    )
    print(
        "Loaded Vakili-R1 LUT reference: SHA-256 {}".format(
            manifest["vakili_r1_contract"]["adapt_raw_byte_lut_sha256"]
        )
    )
    print("Loaded frozen checkpoint and prepared FPGA memories")
    print("  weights: {} int8 model values".format(model_weight_count))
    print("  banked:  {} int8 storage values".format(banked_weights.size))
    print("  biases:  {} int32 values".format(len(flat_biases)))
    print(
        "  scales:  w1={}, w2={}, w3={}".format(
            *quantization["weight_scales"]
        )
    )
    print(
        "  shifts:  hidden1={}, hidden2={}".format(
            *quantization["hidden_shifts"]
        )
    )
    print(
        "  MNIST input: normalized, input_scale={}".format(
            quantization["input_scale"]
        )
    )
    print("  dataset:  {}".format(dataset_label))
    print("  scope:    {}".format(dataset_metadata["evaluation_scope"]))
    if args.dataset == "official-test" and not dataset_metadata["complete_split"]:
        print("  note:     official-test subset only; not the final accuracy report")
    print("  selection SHA-256: {}".format(dataset_metadata["sample_sha256"]))
    print("References:")
    print("  r1:    bit-exact Vakili-R1 hardware oracle")
    print("  exact: exact-multiply INT8 counterfactual using the same tensors")
    if fp32_predictions is not None:
        print("  fp32:  frozen original FP32 model ({})".format(fp32_sha256))
    else:
        print("  fp32:  intentionally skipped")
    print("Model: 784 -> 64 -> 32 -> 10")
    print("Number of test vectors: {}".format(args.sample_count))
    print("UART transport: {}".format(args.transport))
    print("\nOpening {} at {} baud...".format(args.port, args.baud))
    actual_logits = []
    running_correct = 0
    running_r1_matches = 0
    confusion = np.zeros((NUM_OUTPUTS, NUM_OUTPUTS), dtype=np.int64)
    with serial.Serial(args.port, baudrate=args.baud, timeout=args.timeout) as device:
        time.sleep(0.5)
        device.reset_input_buffer()
        device.reset_output_buffer()
        if not args.skip_parameter_load:
            print("Uploading frozen INT8 weights...")
            write_banked_int8_weights(
                device, banked_weights, args.inter_packet_delay
            )
            print("Uploading frozen INT32 biases...")
            write_int32_values(
                device, CMD_WRITE_BIAS, flat_biases,
                args.inter_packet_delay, "biases"
            )

        print("\nRunning {} MNIST sample(s) from {}...".format(
            len(inputs), dataset_label
        ))
        inference_wall_start = time.perf_counter()
        for index, input_values in enumerate(inputs):
            actual = run_fpga_inference(device, input_values, args)
            actual_logits.append(actual)

            label = int(labels[index])
            r1_prediction = int(r1_predictions[index])
            exact_prediction = int(exact_predictions[index])
            fp32_prediction = (
                int(fp32_predictions[index])
                if fp32_predictions is not None else None
            )
            fpga_prediction = int(np.argmax(actual))
            if fpga_prediction == label:
                running_correct += 1
            if fpga_prediction == r1_prediction:
                running_r1_matches += 1
            confusion[label, fpga_prediction] += 1

            completed = index + 1
            print(
                "{:4d}/{:<4d} {:>12s} label={} r1={} exact={} fp32={} fpga={} "
                "acc={:6.2f}% r1_match={:6.2f}%".format(
                    completed,
                    len(inputs),
                    names[index],
                    label,
                    r1_prediction,
                    exact_prediction,
                    fp32_prediction if fp32_prediction is not None else "-",
                    fpga_prediction,
                    100.0 * running_correct / completed,
                    100.0 * running_r1_matches / completed,
                )
            )
        inference_wall_seconds = time.perf_counter() - inference_wall_start

    actual_logits = np.stack(actual_logits).astype(np.int32, copy=False)
    difference = actual_logits.astype(np.int64) - r1_logits.astype(np.int64)
    logit_mismatches = int(np.count_nonzero(difference))
    actual_predictions = np.argmax(actual_logits, axis=1)
    prediction_mismatches = int(np.count_nonzero(
        r1_predictions != actual_predictions
    ))
    r1_prediction_matches = args.sample_count - prediction_mismatches
    exact_logit_vector_matches = int(np.count_nonzero(
        np.all(difference == 0, axis=1)
    ))
    correct = int(np.count_nonzero(actual_predictions == labels))
    exact_correct = int(np.count_nonzero(exact_predictions == labels))
    fpga_exact_matches = int(np.count_nonzero(
        actual_predictions == exact_predictions
    ))
    r1_exact_disagreements = int(np.count_nonzero(
        r1_predictions != exact_predictions
    ))
    fp32_correct = None
    fpga_fp32_matches = None
    r1_fp32_disagreements = None
    if fp32_predictions is not None:
        fp32_correct = int(np.count_nonzero(fp32_predictions == labels))
        fpga_fp32_matches = int(np.count_nonzero(
            actual_predictions == fp32_predictions
        ))
        r1_fp32_disagreements = int(np.count_nonzero(
            r1_predictions != fp32_predictions
        ))
    status = "PASS" if logit_mismatches == 0 and prediction_mismatches == 0 else "FAIL"

    report = {
        "schema_version": 2,
        "stage": "vakili_r1_aware_p16_fpga_uart_equivalence",
        "status": status,
        "official_test_evaluated": dataset_metadata["official_test_evaluated"],
        "complete_official_test_evaluated": bool(
            dataset_metadata["final_accuracy_report"]
        ),
        "final_accuracy_report": bool(dataset_metadata["final_accuracy_report"]),
        "model_id": manifest["model_id"],
        "dataset": dataset_metadata,
        "manifest": args.manifest.resolve().relative_to(root.resolve()).as_posix(),
        "manifest_sha256": sha256_file(args.manifest),
        "tensor_archive_sha256": sha256_file(tensor_path),
        "port": args.port,
        "baud": args.baud,
        "transport": {
            "protocol": args.transport,
            "image_transactions_per_sample": (
                1 if args.transport == "stream-image" else 49
            ),
            "stream_image_command": (
                "0x07" if args.transport == "stream-image" else None
            ),
            "stream_image_bytes": (
                STREAM_IMAGE_BYTES if args.transport == "stream-image" else None
            ),
            "inference_wall_seconds": inference_wall_seconds,
            "observed_images_per_second": (
                args.sample_count / inference_wall_seconds
            ),
        },
        "accelerator_core": {
            "clock_hz": CORE_CLOCK_HZ,
            "latency_cycles": CORE_LATENCY_CYCLES,
            "latency_seconds": CORE_LATENCY_CYCLES / float(CORE_CLOCK_HZ),
            "ideal_images_per_second": (
                float(CORE_CLOCK_HZ) / CORE_LATENCY_CYCLES
            ),
        },
        "parameters_uploaded": not args.skip_parameter_load,
        "weight_wire_layout": "bank_address[15:4]_lane[3:0]",
        "weight_wire_words": WEIGHT_WIRE_WORDS,
        "sample_start": args.sample_start,
        "sample_count": args.sample_count,
        "network_logits": int(r1_logits.size),
        "network_logit_mismatches": logit_mismatches,
        "network_prediction_mismatches": prediction_mismatches,
        "reference_prediction_matches": r1_prediction_matches,
        "exact_logit_vector_matches": exact_logit_vector_matches,
        "maximum_absolute_logit_difference": int(np.max(np.abs(difference))),
        "label_correct": correct,
        "label_accuracy": float(correct) / args.sample_count,
        "confusion_matrix": confusion.tolist(),
        "references": {
            "vakili_r1_hardware_oracle": {
                "role": "bit-exact implementation oracle",
                "fpga_prediction_matches": r1_prediction_matches,
                "fpga_exact_logit_vector_matches": exact_logit_vector_matches,
                "fpga_individual_logit_mismatches": logit_mismatches,
            },
            "exact_int8_counterfactual": {
                "role": "exact multiplication with the same R1-aware integer tensors",
                "label_correct": exact_correct,
                "label_accuracy": float(exact_correct) / args.sample_count,
                "fpga_prediction_matches": fpga_exact_matches,
                "prediction_disagreements_with_r1": r1_exact_disagreements,
            },
            "fp32_baseline": (
                {
                    "role": "frozen original behavioral reference",
                    "checkpoint": args.fp32_checkpoint.resolve().relative_to(
                        root.resolve()
                    ).as_posix(),
                    "checkpoint_sha256": fp32_sha256,
                    "label_correct": fp32_correct,
                    "label_accuracy": float(fp32_correct) / args.sample_count,
                    "fpga_prediction_matches": fpga_fp32_matches,
                    "prediction_disagreements_with_r1": r1_fp32_disagreements,
                }
                if fp32_predictions is not None else None
            ),
        },
        "bitstream_sha256": (
            sha256_file(args.bitstream) if args.bitstream is not None else None
        ),
    }
    if args.report_path is not None:
        write_json(args.report_path, report)

    print("\nMNIST summary")
    print(
        "  UART throughput (observed):                  {:.2f} images/s ({:.2f} s)".format(
            args.sample_count / inference_wall_seconds,
            inference_wall_seconds,
        )
    )
    print(
        "  P16 core-only throughput:         {:.2f} images/s ({} cycles)".format(
            float(CORE_CLOCK_HZ) / CORE_LATENCY_CYCLES,
            CORE_LATENCY_CYCLES,
        )
    )
    print("")
    print(
        "  FPGA vs label accuracy:          {}/{} = {:.2f}%".format(
            correct,
            args.sample_count,
            100.0 * correct / args.sample_count,
        )
    )
    print(
        "  FPGA vs simulation:      {}/{} = {:.2f}%".format(
            r1_prediction_matches,
            args.sample_count,
            100.0 * r1_prediction_matches / args.sample_count,
        )
    )
    print(
        "  Exact FPGA logit vectors vs R1:  {}/{} = {:.2f}%".format(
            exact_logit_vector_matches,
            args.sample_count,
            100.0 * exact_logit_vector_matches / args.sample_count,
        )
    )
    print(
        "  FPGA vs exact-INT8 predictions:  {}/{} = {:.2f}%".format(
            fpga_exact_matches,
            args.sample_count,
            100.0 * fpga_exact_matches / args.sample_count,
        )
    )
    if fp32_predictions is not None:
        print(
            "  FP32 baseline accuracy:          {}/{} = {:.2f}%".format(
                fp32_correct,
                args.sample_count,
                100.0 * fp32_correct / args.sample_count,
            )
        )
        print(
            "  FPGA vs FP32 predictions:        {}/{} = {:.2f}%".format(
                fpga_fp32_matches,
                args.sample_count,
                100.0 * fpga_fp32_matches / args.sample_count,
            )
        )
    if args.show_confusion:
        print_confusion_matrix(confusion)

    print("\nVAKILI_R1_AWARE_P16_FPGA_UART_{}".format(status))
    if status != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
