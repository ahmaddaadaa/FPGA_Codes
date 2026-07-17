#!/usr/bin/env python3
"""Load frozen banked weights and biases through the FPGA UDP endpoint."""

import argparse
import socket
import time
from pathlib import Path

import numpy as np

from export_hardware_exact_p16_reference import (
    load_and_validate_tensors, read_json, repository_root,
)
from verify_vakili_r1_aware_p16_ethernet import (
    CMD_WRITE_BIAS, CMD_WRITE_WEIGHT, RSP_WRITE_BIAS, RSP_WRITE_WEIGHT,
    packet, transact,
)
from verify_vakili_r1_aware_p16_uart import build_banked_weight_rows


def upload_chunks(sock, endpoint, sequence, values, command, response,
                  chunk_bytes, retries, address_divisor, label):
    total = len(values)
    next_report = 8192
    for start in range(0, total, chunk_bytes):
        end = min(total, start + chunk_bytes)
        sequence = (sequence + 1) & 0xFFFFFFFF
        transact(
            sock, endpoint,
            packet(command, sequence, values[start:end],
                   address=start // address_divisor),
            response, sequence, 0, retries,
        )
        if end == total or end >= next_report:
            print("{}: {}/{} bytes".format(label, end, total))
            while next_report <= end:
                next_report += 8192
    return sequence


def main():
    root = repository_root()
    parser = argparse.ArgumentParser()
    parser.add_argument("--board-ip", default="192.168.7.2")
    parser.add_argument("--host-ip", default="192.168.7.1")
    parser.add_argument("--udp-port", type=int, default=5005)
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument(
        "--chunk-bytes", type=int, default=1024,
        help="parameter bytes per stop-and-wait UDP transaction (default: 1024)",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "architectures/vakili_adapt_ga_hls/models/manifests/"
        "vakili_r1_aware_development_frozen.json",
    )
    args = parser.parse_args()
    if not 4 <= args.chunk_bytes <= 1400:
        parser.error("--chunk-bytes must be between 4 and 1400")
    if args.retries < 0:
        parser.error("--retries cannot be negative")

    manifest = read_json(args.manifest)
    _, tensors = load_and_validate_tensors(root, manifest)
    weights = np.ascontiguousarray(
        build_banked_weight_rows(tensors), dtype=np.int8
    ).reshape(-1).tobytes()
    biases = np.ascontiguousarray(
        np.concatenate((tensors["b1"], tensors["b2"], tensors["b3"])),
        dtype=">i4",
    ).tobytes()

    endpoint = (args.board_ip, args.udp_port)
    sequence = int(time.time()) & 0xFFFFFFFF
    bias_chunk_bytes = args.chunk_bytes - (args.chunk_bytes % 4)
    start = time.perf_counter()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.host_ip, 0))
        sock.settimeout(args.timeout)
        print("Uploading frozen int8 weights over Ethernet...")
        sequence = upload_chunks(
            sock, endpoint, sequence, weights,
            CMD_WRITE_WEIGHT, RSP_WRITE_WEIGHT,
            args.chunk_bytes, args.retries, 1, "weights",
        )
        print("Uploading frozen int32 biases over Ethernet...")
        upload_chunks(
            sock, endpoint, sequence, biases,
            CMD_WRITE_BIAS, RSP_WRITE_BIAS,
            bias_chunk_bytes, args.retries, 4, "biases",
        )
    elapsed = time.perf_counter() - start
    total = len(weights) + len(biases)
    print("Ethernet parameter load complete: {} bytes in {:.3f} s "
          "({:.2f} KiB/s)".format(total, elapsed, total / elapsed / 1024.0))


if __name__ == "__main__":
    main()
