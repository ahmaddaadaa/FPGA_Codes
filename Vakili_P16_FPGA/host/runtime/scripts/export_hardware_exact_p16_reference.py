#!/usr/bin/env python3
"""Export and verify the frozen hardware-exact INT8 P16 reference package.

The official MNIST test split is intentionally unavailable to this program.
It reconstructs the deterministic 50,000/10,000 development split from the
official training set, validates every frozen tensor hash, runs an independent
integer reference, and emits P16 weight banks plus bit-exact test vectors.
"""

from __future__ import print_function

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


SPLIT_SEED = 20260714
TRAINING_EXAMPLES = 50000
VALIDATION_EXAMPLES = 10000
NUM_INPUTS = 784
NUM_HIDDEN1 = 64
NUM_HIDDEN2 = 32
NUM_OUTPUTS = 10
PARALLEL_LANES = 16
LAYER1_GROUPS = 4
LAYER2_GROUPS = 2
LAYER3_GROUPS = 1
W1_BANK_BASE = 0
W2_BANK_BASE = W1_BANK_BASE + LAYER1_GROUPS * NUM_INPUTS
W3_BANK_BASE = W2_BANK_BASE + LAYER2_GROUPS * NUM_HIDDEN1
WEIGHT_BANK_DEPTH = W3_BANK_BASE + LAYER3_GROUPS * NUM_HIDDEN2
I32_MIN = -(2 ** 31)
I32_MAX = 2 ** 31 - 1


def repository_root():
    return Path(__file__).resolve().parents[3]


def parse_args():
    root = repository_root()
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "architectures/vakili_adapt_ga_hls/models/manifests/"
        "hardware_exact_int8_development_frozen.json",
    )
    parser.add_argument("--data-root", type=Path, default=root / "data/MNIST")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=root / ".cache/hardware_exact_p16/reference",
    )
    parser.add_argument("--sample-start", type=int, default=0)
    parser.add_argument("--sample-count", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--mnist-download", action="store_true")
    args = parser.parse_args()
    if args.sample_start < 0 or args.sample_start >= VALIDATION_EXAMPLES:
        parser.error("--sample-start must be between 0 and 9999")
    if args.sample_count < 1:
        parser.error("--sample-count must be positive")
    if args.sample_start + args.sample_count > VALIDATION_EXAMPLES:
        parser.error("requested samples exceed the 10,000-image validation split")
    if args.batch_size < 1:
        parser.error("--batch-size must be positive")
    return args


def read_json(path):
    path = Path(path)
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def tensor_sha256(value):
    array = np.ascontiguousarray(value)
    digest = hashlib.sha256()
    digest.update(str(array.dtype).encode("ascii"))
    digest.update(str(tuple(array.shape)).encode("ascii"))
    digest.update(array.tobytes(order="C"))
    return digest.hexdigest()


def resolve_artifact(root, manifest, name):
    value = manifest["artifacts"][name]["repository_path"]
    path = root / value
    if not path.is_file():
        raise RuntimeError("Frozen artifact not found: {}".format(path))
    return path


def load_and_validate_tensors(root, manifest):
    artifact = manifest["artifacts"]["integer_tensors"]
    path = root / artifact["repository_path"]
    if not path.is_file():
        raise RuntimeError("Frozen tensor archive not found: {}".format(path))
    expected_shapes = {
        "w1": (NUM_HIDDEN1, NUM_INPUTS),
        "w2": (NUM_HIDDEN2, NUM_HIDDEN1),
        "w3": (NUM_OUTPUTS, NUM_HIDDEN2),
        "b1": (NUM_HIDDEN1,),
        "b2": (NUM_HIDDEN2,),
        "b3": (NUM_OUTPUTS,),
    }
    expected_dtypes = {
        "w1": np.dtype("int8"),
        "w2": np.dtype("int8"),
        "w3": np.dtype("int8"),
        "b1": np.dtype("int32"),
        "b2": np.dtype("int32"),
        "b3": np.dtype("int32"),
    }
    expected_hashes = artifact["tensor_sha256"]
    tensors = {}
    with np.load(str(path), allow_pickle=False) as archive:
        if sorted(archive.files) != sorted(expected_shapes):
            raise RuntimeError("Frozen archive contains unexpected tensor names")
        for name in sorted(expected_shapes):
            value = np.ascontiguousarray(archive[name])
            if value.shape != expected_shapes[name]:
                raise RuntimeError(
                    "{} shape {} does not match {}".format(
                        name, value.shape, expected_shapes[name]
                    )
                )
            if value.dtype != expected_dtypes[name]:
                raise RuntimeError(
                    "{} dtype {} does not match {}".format(
                        name, value.dtype, expected_dtypes[name]
                    )
                )
            actual_hash = tensor_sha256(value)
            if actual_hash != expected_hashes[name]:
                raise RuntimeError(
                    "{} hash {} does not match frozen {}".format(
                        name, actual_hash, expected_hashes[name]
                    )
                )
            tensors[name] = value
    return path, tensors


def validation_indices(dataset_size):
    import torch

    expected = TRAINING_EXAMPLES + VALIDATION_EXAMPLES
    if dataset_size != expected:
        raise RuntimeError(
            "Expected {} MNIST training images, found {}".format(
                expected, dataset_size
            )
        )
    generator = torch.Generator().manual_seed(SPLIT_SEED)
    return torch.randperm(dataset_size, generator=generator)[:VALIDATION_EXAMPLES]


def load_validation_samples(data_root, download, start, count):
    from torchvision.datasets import MNIST

    dataset = MNIST(str(data_root), train=True, download=download)
    indices = validation_indices(len(dataset))[start:start + count]
    pixels = dataset.data.index_select(0, indices).numpy().reshape(-1, NUM_INPUTS)
    labels = dataset.targets.index_select(0, indices).numpy().astype(np.int64)
    names = ["train_{:05d}".format(int(index)) for index in indices.tolist()]
    return pixels.astype(np.uint8), labels, names


def quantize_inputs(pixels, input_scale):
    values = np.rint(pixels.astype(np.float64) * (input_scale / 255.0))
    values = np.clip(values, 0, 127).astype(np.int8)
    return values


def dense_exact(inputs, weights, biases, batch_size, layer_name):
    outputs = np.empty((len(inputs), len(weights)), dtype=np.int64)
    maximum = 0
    for start in range(0, len(inputs), batch_size):
        end = min(len(inputs), start + batch_size)
        wide = (
            inputs[start:end].astype(np.int64)
            @ weights.astype(np.int64).T
            + biases.astype(np.int64)[None, :]
        )
        if np.any((wide < I32_MIN) | (wide > I32_MAX)):
            raise RuntimeError("{} overflowed signed INT32".format(layer_name))
        maximum = max(maximum, int(np.max(np.abs(wide))))
        outputs[start:end] = wide
    return outputs, maximum


def relu_shift_clip(accumulators, shift):
    # The negative test occurs before the shift. This also makes the Python
    # result independent of implementation-defined negative C++ right shift.
    shifted = np.right_shift(accumulators, shift)
    return np.where(accumulators < 0, 0, np.minimum(127, shifted)).astype(np.int8)


def exact_inference(inputs, tensors, shifts, batch_size):
    acc1, max1 = dense_exact(
        inputs, tensors["w1"], tensors["b1"], batch_size, "layer1"
    )
    hidden1 = relu_shift_clip(acc1, shifts[0])
    acc2, max2 = dense_exact(
        hidden1, tensors["w2"], tensors["b2"], batch_size, "layer2"
    )
    hidden2 = relu_shift_clip(acc2, shifts[1])
    logits, max3 = dense_exact(
        hidden2, tensors["w3"], tensors["b3"], batch_size, "layer3"
    )
    return logits.astype(np.int32), hidden1, hidden2, [max1, max2, max3]


def exact_truth_table_hash():
    operands = np.arange(-128, 128, dtype=np.int16)
    products = (operands[:, None] * operands[None, :]).astype("<i2", copy=False)
    return sha256_bytes(products.tobytes(order="C")), int(products.nbytes)


def bank_weights(tensors):
    banks = np.zeros((PARALLEL_LANES, WEIGHT_BANK_DEPTH), dtype=np.int8)
    for output in range(NUM_HIDDEN1):
        group, lane = divmod(output, PARALLEL_LANES)
        bank_index = W1_BANK_BASE + group * NUM_INPUTS
        banks[lane, bank_index:bank_index + NUM_INPUTS] = tensors["w1"][output]
    for output in range(NUM_HIDDEN2):
        group, lane = divmod(output, PARALLEL_LANES)
        bank_index = W2_BANK_BASE + group * NUM_HIDDEN1
        banks[lane, bank_index:bank_index + NUM_HIDDEN1] = tensors["w2"][output]
    for output in range(NUM_OUTPUTS):
        group, lane = divmod(output, PARALLEL_LANES)
        bank_index = W3_BANK_BASE + group * NUM_HIDDEN2
        banks[lane, bank_index:bank_index + NUM_HIDDEN2] = tensors["w3"][output]
    return banks


def unbank_weights(banks):
    result = {
        "w1": np.empty((NUM_HIDDEN1, NUM_INPUTS), dtype=np.int8),
        "w2": np.empty((NUM_HIDDEN2, NUM_HIDDEN1), dtype=np.int8),
        "w3": np.empty((NUM_OUTPUTS, NUM_HIDDEN2), dtype=np.int8),
    }
    for output in range(NUM_HIDDEN1):
        group, lane = divmod(output, PARALLEL_LANES)
        base = W1_BANK_BASE + group * NUM_INPUTS
        result["w1"][output] = banks[lane, base:base + NUM_INPUTS]
    for output in range(NUM_HIDDEN2):
        group, lane = divmod(output, PARALLEL_LANES)
        base = W2_BANK_BASE + group * NUM_HIDDEN1
        result["w2"][output] = banks[lane, base:base + NUM_HIDDEN1]
    for output in range(NUM_OUTPUTS):
        group, lane = divmod(output, PARALLEL_LANES)
        base = W3_BANK_BASE + group * NUM_HIDDEN2
        result["w3"][output] = banks[lane, base:base + NUM_HIDDEN2]
    return result


def write_rows(path, rows):
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        for row in rows:
            stream.write(" ".join(str(int(value)) for value in row))
            stream.write("\n")


def write_flat(path, values):
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        for value in values:
            stream.write(str(int(value)))
            stream.write("\n")


def main():
    args = parse_args()
    root = repository_root()
    manifest = read_json(args.manifest)
    expected_status = "frozen_hardware_exact_int8_development_baseline"
    if manifest.get("status") != expected_status:
        raise RuntimeError("Manifest is not the frozen development baseline")
    if manifest["selection_scope"].get("official_test_evaluated") is not False:
        raise RuntimeError("Development manifest unexpectedly exposes official test data")

    tensor_path, tensors = load_and_validate_tensors(root, manifest)
    shifts = manifest["quantization_contract"]["hidden_shifts"]
    input_scale = float(manifest["quantization_contract"]["input_scale"])
    truth_hash, truth_bytes = exact_truth_table_hash()
    expected_truth = manifest["exact_multiplier_truth_table"]
    if truth_hash != expected_truth["sha256"] or truth_bytes != expected_truth["byte_count"]:
        raise RuntimeError("Exact multiplier truth-table contract changed")

    pixels, labels, names = load_validation_samples(
        args.data_root,
        args.mnist_download,
        args.sample_start,
        args.sample_count,
    )
    inputs = quantize_inputs(pixels, input_scale)
    logits, hidden1, hidden2, accumulator_maxima = exact_inference(
        inputs, tensors, shifts, args.batch_size
    )
    predictions = np.argmax(logits, axis=1)
    correct = int(np.count_nonzero(predictions == labels))

    if args.sample_start == 0 and args.sample_count == VALIDATION_EXAMPLES:
        expected_correct = manifest["development_validation"][
            "hardware_exact_int8_correct"
        ]
        if correct != expected_correct:
            raise RuntimeError(
                "Full validation score {}/{} does not match frozen {}/{}".format(
                    correct,
                    args.sample_count,
                    expected_correct,
                    VALIDATION_EXAMPLES,
                )
            )

    banks = bank_weights(tensors)
    roundtrip = unbank_weights(banks)
    for name in ("w1", "w2", "w3"):
        if not np.array_equal(roundtrip[name], tensors[name]):
            raise RuntimeError("P16 bank round-trip failed for {}".format(name))

    args.output_dir.mkdir(parents=True, exist_ok=True)
    write_rows(args.output_dir / "weight_banks.txt", banks)
    write_flat(
        args.output_dir / "biases.txt",
        np.concatenate((tensors["b1"], tensors["b2"], tensors["b3"])),
    )
    write_rows(args.output_dir / "inputs.txt", inputs)
    write_rows(args.output_dir / "logits.txt", logits)
    write_flat(args.output_dir / "labels.txt", labels)
    (args.output_dir / "names.txt").write_text(
        "\n".join(names) + "\n", encoding="utf-8"
    )

    generated_names = [
        "weight_banks.txt",
        "biases.txt",
        "inputs.txt",
        "logits.txt",
        "labels.txt",
        "names.txt",
    ]
    generated_hashes = {
        name: sha256_file(args.output_dir / name) for name in generated_names
    }
    report = {
        "schema_version": 1,
        "stage": "hardware_exact_p16_python_reference",
        "status": "PASS",
        "official_test_evaluated": False,
        "manifest": str(args.manifest.relative_to(root)),
        "manifest_sha256": sha256_file(args.manifest),
        "tensor_archive": str(tensor_path.relative_to(root)),
        "tensor_sha256": manifest["artifacts"]["integer_tensors"][
            "tensor_sha256"
        ],
        "selected_candidate": manifest["selected_candidate"],
        "input_scale": input_scale,
        "weight_scales": manifest["quantization_contract"]["weight_scales"],
        "hidden_shifts": shifts,
        "sample_start": args.sample_start,
        "sample_count": args.sample_count,
        "correct": correct,
        "accuracy": float(correct) / args.sample_count,
        "accumulator_maximum_absolute": accumulator_maxima,
        "hidden_zero_fraction": [
            float(np.count_nonzero(hidden1 == 0)) / hidden1.size,
            float(np.count_nonzero(hidden2 == 0)) / hidden2.size,
        ],
        "hidden_saturation_fraction": [
            float(np.count_nonzero(hidden1 == 127)) / hidden1.size,
            float(np.count_nonzero(hidden2 == 127)) / hidden2.size,
        ],
        "exact_multiplier": {
            "verified_pairs": 65536,
            "truth_table_sha256": truth_hash,
            "truth_table_bytes": truth_bytes,
        },
        "p16_weight_banks": [PARALLEL_LANES, WEIGHT_BANK_DEPTH],
        "weight_bank_roundtrip": "PASS",
        "generated_file_sha256": generated_hashes,
    }
    write_json(args.output_dir / "reference_report.json", report)

    print("HARDWARE_EXACT_P16_REFERENCE_PASS")
    print("Samples: {}/{} correct ({:.4%})".format(
        correct, args.sample_count, float(correct) / args.sample_count
    ))
    print("Exact multiplier pairs: 65536")
    print("Exact truth-table SHA-256: {}".format(truth_hash))
    print("P16 banks: {} x {}".format(PARALLEL_LANES, WEIGHT_BANK_DEPTH))
    print("Output: {}".format(args.output_dir))


if __name__ == "__main__":
    main()
