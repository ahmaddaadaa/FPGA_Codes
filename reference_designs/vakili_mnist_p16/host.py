#!/usr/bin/env python3
"""Load and evaluate the Vakili MNIST P16 design over UDP."""

from __future__ import annotations

import argparse
import hashlib
import json
import socket
import struct
import time
from pathlib import Path

import numpy as np


MAGIC = b"VAKI"
VERSION = 1
HEADER = struct.Struct("!4sBBBBIHH")

CMD_PING = 0x01
CMD_INFER = 0x02
CMD_WRITE_WEIGHT = 0x03
CMD_WRITE_BIAS = 0x04
RSP_PING = 0x81
RSP_INFER = 0x82
RSP_WRITE_WEIGHT = 0x83
RSP_WRITE_BIAS = 0x84

NUM_INPUTS = 784
NUM_OUTPUTS = 10
P16_LANES = 16
WEIGHT_BANK_DEPTH = 3296
W2_BANK_BASE = 3136
W3_BANK_BASE = 3264
PARAMETER_FILE_SHA256 = "0f7aeea5b2b55c21b8bc2eb01c203e79896690578acb2fce529ceaeb721d95f0"
SOURCE_NPZ_SHA256 = "851294e5e760d3dc013e44736ca457b50a8faa9b9fbf3f4c19658c64d9800081"


def packet(command: int, sequence: int, body: bytes = b"", address: int = 0) -> bytes:
    if not 0 <= address <= 0xFFFF:
        raise ValueError("address does not fit in the protocol header")
    return HEADER.pack(
        MAGIC, VERSION, command, 0, HEADER.size,
        sequence, len(body), address,
    ) + body


def parse_response(data: bytes, command: int, sequence: int,
                   body_length: int) -> bytes:
    if len(data) != HEADER.size + body_length:
        raise RuntimeError(
            f"response has {len(data)} bytes; expected {HEADER.size + body_length}"
        )
    fields = HEADER.unpack_from(data)
    magic, version, actual_command, status, header_length, actual_sequence, length, _ = fields
    expected = (MAGIC, VERSION, command, 0, HEADER.size, sequence, body_length)
    actual = (
        magic, version, actual_command, status, header_length,
        actual_sequence, length,
    )
    if actual != expected:
        raise RuntimeError(
            "invalid response header: "
            f"command=0x{actual_command:02x}, status=0x{status:02x}, "
            f"sequence={actual_sequence}, length={length}"
        )
    return data[HEADER.size:]


class Board:
    def __init__(self, host_ip: str, board_ip: str, port: int,
                 timeout: float, retries: int) -> None:
        self.endpoint = (board_ip, port)
        self.retries = retries
        self.sequence = int(time.time()) & 0xFFFFFFFF
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((host_ip, 0))
        self.sock.settimeout(timeout)

    def close(self) -> None:
        self.sock.close()

    def __enter__(self) -> "Board":
        return self

    def __exit__(self, _type, _value, _traceback) -> None:
        self.close()

    def request(self, command: int, response: int, body: bytes = b"",
                address: int = 0, response_bytes: int = 0) -> bytes:
        self.sequence = (self.sequence + 1) & 0xFFFFFFFF
        request = packet(command, self.sequence, body, address)
        errors = []
        for attempt in range(self.retries + 1):
            try:
                self.sock.sendto(request, self.endpoint)
                data, sender = self.sock.recvfrom(2048)
                if sender[0] != self.endpoint[0]:
                    raise RuntimeError(f"response came from {sender[0]}")
                return parse_response(
                    data, response, self.sequence, response_bytes
                )
            except (socket.timeout, RuntimeError) as exc:
                errors.append(f"attempt {attempt + 1}: {exc}")
        raise RuntimeError("; ".join(errors))

    def ping(self) -> None:
        self.request(CMD_PING, RSP_PING, response_bytes=16)

    def upload(self, values: bytes, command: int, response: int,
               chunk_bytes: int, address_divisor: int, label: str) -> None:
        total = len(values)
        for start in range(0, total, chunk_bytes):
            end = min(total, start + chunk_bytes)
            self.request(
                command,
                response,
                body=values[start:end],
                address=start // address_divisor,
            )
            if end == total or end % 8192 == 0:
                print(f"{label}: {end}/{total} bytes")

    def infer(self, image: np.ndarray) -> tuple[np.ndarray, int]:
        body = np.ascontiguousarray(image, dtype=np.int8).reshape(-1).tobytes()
        if len(body) != NUM_INPUTS:
            raise ValueError(f"image has {len(body)} bytes; expected {NUM_INPUTS}")
        response = self.request(
            CMD_INFER, RSP_INFER, body=body, response_bytes=44
        )
        cycles = struct.unpack_from("!I", response, 0)[0]
        logits = np.asarray(struct.unpack("!10i", response[4:44]), dtype=np.int32)
        return logits, cycles


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_parameters(path: Path) -> dict[str, np.ndarray]:
    if file_sha256(path) != PARAMETER_FILE_SHA256:
        raise RuntimeError(f"parameter file hash does not match: {path}")
    shapes = {
        "w1": (64, 784),
        "w2": (32, 64),
        "w3": (10, 32),
        "b1": (64,),
        "b2": (32,),
        "b3": (10,),
    }
    payload = json.loads(path.read_text(encoding="utf-8"))
    metadata = {"format", "source_npz_sha256"}
    if set(payload) != set(shapes) | metadata:
        raise RuntimeError("parameter file contains unexpected fields")
    if payload["format"] != "vakili-mnist-p16-v1":
        raise RuntimeError("unsupported parameter format")
    if payload["source_npz_sha256"] != SOURCE_NPZ_SHA256:
        raise RuntimeError("parameter source hash does not match")

    result = {}
    for name, shape in shapes.items():
        values = np.asarray(payload[name])
        size = int(np.prod(shape))
        if values.ndim != 1 or values.size != size or values.dtype.kind not in "iu":
            raise RuntimeError(f"{name}: expected {size} integer values")
        expected_dtype = np.dtype("int8" if name.startswith("w") else "int32")
        limits = np.iinfo(expected_dtype)
        if np.any(values < limits.min) or np.any(values > limits.max):
            raise RuntimeError(f"{name}: value does not fit {expected_dtype}")
        result[name] = np.ascontiguousarray(
            values.astype(expected_dtype).reshape(shape)
        )
    return result


def bank_weights(tensors: dict[str, np.ndarray]) -> bytes:
    rows = np.zeros((WEIGHT_BANK_DEPTH, P16_LANES), dtype=np.int8)
    layers = (
        ("w1", 0),
        ("w2", W2_BANK_BASE),
        ("w3", W3_BANK_BASE),
    )
    for name, bank_base in layers:
        weights = tensors[name]
        output_count, input_count = weights.shape
        for output in range(output_count):
            group, lane = divmod(output, P16_LANES)
            start = bank_base + group * input_count
            rows[start:start + input_count, lane] = weights[output]
    return rows.tobytes(order="C")


def upload_parameters(board: Board, path: Path, chunk_bytes: int) -> None:
    tensors = load_parameters(path)
    weights = bank_weights(tensors)
    biases = np.concatenate(
        (tensors["b1"], tensors["b2"], tensors["b3"])
    ).astype(">i4", copy=False).tobytes()
    board.upload(
        weights, CMD_WRITE_WEIGHT, RSP_WRITE_WEIGHT,
        chunk_bytes, 1, "weights",
    )
    bias_chunk = chunk_bytes - chunk_bytes % 4
    board.upload(
        biases, CMD_WRITE_BIAS, RSP_WRITE_BIAS,
        bias_chunk, 4, "biases",
    )


def evaluate(board: Board, args: argparse.Namespace) -> None:
    try:
        from torchvision.datasets import MNIST
    except ImportError as exc:
        raise RuntimeError("install the packages in requirements.txt") from exc

    dataset = MNIST(
        str(args.data_root),
        train=args.train,
        download=args.download,
    )
    count = args.count if args.count is not None else len(dataset) - args.start
    stop = args.start + count
    if args.start < 0 or count < 1 or stop > len(dataset):
        raise ValueError(
            f"requested range {args.start}:{stop} exceeds {len(dataset)} images"
        )
    pixels = dataset.data[args.start:stop].numpy().reshape(-1, NUM_INPUTS)
    labels = dataset.targets[args.start:stop].numpy().astype(np.int64)
    inputs = np.rint(pixels.astype(np.float64) * (127.0 / 255.0))
    inputs = np.clip(inputs, 0, 127).astype(np.int8)

    correct = 0
    started = time.perf_counter()
    last_cycles = 0
    for index, image in enumerate(inputs, 1):
        logits, last_cycles = board.infer(image)
        prediction = int(np.argmax(logits))
        correct += prediction == int(labels[index - 1])
        if args.progress and (index == 1 or index == count or index % args.progress == 0):
            print(
                f"{index:6d}/{count:<6d} label={int(labels[index - 1])} "
                f"fpga={prediction} accuracy={100.0 * correct / index:6.2f}%"
            )
    elapsed = time.perf_counter() - started
    split = "training" if args.train else "test"
    print("\nMNIST FPGA evaluation")
    print(f"  Dataset:       MNIST {split} set")
    print(f"  Images:        {count}")
    print(f"  Accuracy:      {correct}/{count} = {100.0 * correct / count:.2f}%")
    print(f"  Throughput:    {count / elapsed:.2f} images/s")
    print(f"  Elapsed time:  {elapsed:.2f} s")
    print(f"  Core cycles:   {last_cycles}")


def add_evaluation_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--data-root", type=Path, default=Path("data/MNIST"))
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--train", action="store_true", help="use the 60,000-image training set")
    parser.add_argument("--start", type=int, default=0)
    parser.add_argument("--count", type=int, default=None)
    parser.add_argument("--progress", type=int, default=100)


def arguments() -> argparse.Namespace:
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--board-ip", default="192.168.7.2")
    parser.add_argument("--host-ip", default="192.168.7.1")
    parser.add_argument("--port", type=int, default=5005)
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--retries", type=int, default=2)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("ping")

    load_parser = subparsers.add_parser("load")
    load_parser.add_argument(
        "--parameters", type=Path,
        default=root / "model" / "parameters.json",
    )
    load_parser.add_argument("--chunk-bytes", type=int, default=1024)

    evaluate_parser = subparsers.add_parser("evaluate")
    add_evaluation_arguments(evaluate_parser)

    run_parser = subparsers.add_parser("run")
    run_parser.add_argument(
        "--parameters", type=Path,
        default=root / "model" / "parameters.json",
    )
    run_parser.add_argument("--chunk-bytes", type=int, default=1024)
    add_evaluation_arguments(run_parser)

    args = parser.parse_args()
    if args.retries < 0:
        parser.error("--retries cannot be negative")
    if hasattr(args, "chunk_bytes") and not 4 <= args.chunk_bytes <= 1400:
        parser.error("--chunk-bytes must be between 4 and 1400")
    if hasattr(args, "progress") and args.progress < 0:
        parser.error("--progress cannot be negative")
    return args


def main() -> None:
    args = arguments()
    with Board(
        args.host_ip, args.board_ip, args.port, args.timeout, args.retries
    ) as board:
        if args.command == "ping":
            board.ping()
            print(f"FPGA endpoint is responding at {args.board_ip}:{args.port}")
            return
        if args.command in ("load", "run"):
            upload_parameters(board, args.parameters, args.chunk_bytes)
            print("parameter load complete")
        if args.command in ("evaluate", "run"):
            evaluate(board, args)


if __name__ == "__main__":
    main()
