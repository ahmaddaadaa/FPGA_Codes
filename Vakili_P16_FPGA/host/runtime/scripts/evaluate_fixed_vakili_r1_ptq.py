#!/usr/bin/env python3
"""Measure fixed Vakili-R1 PTQ against the frozen hardware-exact baseline."""

from __future__ import print_function

import argparse
from pathlib import Path

import numpy as np

from export_hardware_exact_p16_reference import (
    VALIDATION_EXAMPLES,
    bank_weights,
    exact_inference,
    exact_truth_table_hash,
    load_and_validate_tensors,
    load_validation_samples,
    quantize_inputs,
    read_json,
    relu_shift_clip,
    repository_root,
    sha256_file,
    write_flat,
    write_json,
    write_rows,
)
from vakili_r1_reference import (
    build_adapt_activation_weight_lut,
    build_signed_activation_weight_truth_table,
    dense_vakili_r1,
    int16_table_sha256,
    write_adapt_header,
)


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
        default=root / ".cache/vakili_r1_ptq/reference",
    )
    parser.add_argument("--report-path", type=Path, default=None)
    parser.add_argument("--sample-start", type=int, default=0)
    parser.add_argument("--sample-count", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--output-chunk", type=int, default=8)
    parser.add_argument("--mnist-download", action="store_true")
    args = parser.parse_args()
    if args.sample_start < 0 or args.sample_start >= VALIDATION_EXAMPLES:
        parser.error("--sample-start must be between 0 and 9999")
    if args.sample_count < 1 or args.sample_start + args.sample_count > VALIDATION_EXAMPLES:
        parser.error("requested samples must fit the 10,000-image validation split")
    if args.batch_size < 1 or args.output_chunk < 1:
        parser.error("--batch-size and --output-chunk must be positive")
    return args


def approximate_inference(inputs, tensors, shifts, lut, batch_size, output_chunk):
    acc1, max1 = dense_vakili_r1(
        inputs, tensors["w1"], tensors["b1"], lut,
        batch_size, output_chunk, "vakili_r1_layer1",
    )
    hidden1 = relu_shift_clip(acc1, shifts[0])
    acc2, max2 = dense_vakili_r1(
        hidden1, tensors["w2"], tensors["b2"], lut,
        batch_size, output_chunk, "vakili_r1_layer2",
    )
    hidden2 = relu_shift_clip(acc2, shifts[1])
    logits, max3 = dense_vakili_r1(
        hidden2, tensors["w3"], tensors["b3"], lut,
        batch_size, output_chunk, "vakili_r1_layer3",
    )
    return logits.astype(np.int32), hidden1, hidden2, [max1, max2, max3]


def fraction_equal(values, target):
    return float(np.count_nonzero(values == target)) / values.size


def main():
    args = parse_args()
    root = repository_root()
    manifest = read_json(args.manifest)
    if manifest.get("status") != "frozen_hardware_exact_int8_development_baseline":
        raise RuntimeError("Manifest is not the frozen hardware-exact baseline")
    if manifest["selection_scope"].get("official_test_evaluated") is not False:
        raise RuntimeError("Development manifest unexpectedly exposes official test data")

    tensor_path, tensors = load_and_validate_tensors(root, manifest)
    shifts = manifest["quantization_contract"]["hidden_shifts"]
    input_scale = float(manifest["quantization_contract"]["input_scale"])
    exact_hash, exact_bytes = exact_truth_table_hash()
    if exact_hash != manifest["exact_multiplier_truth_table"]["sha256"]:
        raise RuntimeError("Frozen exact-multiplier contract changed")

    print("Building canonical weight-first Vakili-R1 truth tables...")
    signed_truth = build_signed_activation_weight_truth_table()
    adapt_lut = build_adapt_activation_weight_lut()
    signed_truth_hash = int16_table_sha256(signed_truth)
    adapt_lut_hash = int16_table_sha256(adapt_lut)
    swapped_pairs = int(np.count_nonzero(signed_truth != signed_truth.T))

    pixels, labels, names = load_validation_samples(
        args.data_root, args.mnist_download, args.sample_start, args.sample_count
    )
    inputs = quantize_inputs(pixels, input_scale)
    exact_logits, exact_hidden1, exact_hidden2, exact_maxima = exact_inference(
        inputs, tensors, shifts, args.batch_size
    )
    print("Evaluating fixed Vakili-R1 PTQ on {} samples...".format(args.sample_count))
    approx_logits, approx_hidden1, approx_hidden2, approx_maxima = approximate_inference(
        inputs, tensors, shifts, adapt_lut, args.batch_size, args.output_chunk
    )

    exact_predictions = np.argmax(exact_logits, axis=1)
    approx_predictions = np.argmax(approx_logits, axis=1)
    exact_correct = int(np.count_nonzero(exact_predictions == labels))
    approx_correct = int(np.count_nonzero(approx_predictions == labels))
    if args.sample_start == 0 and args.sample_count == VALIDATION_EXAMPLES:
        frozen_correct = manifest["development_validation"][
            "hardware_exact_int8_correct"
        ]
        if exact_correct != frozen_correct:
            raise RuntimeError(
                "Exact score {}/{} no longer matches frozen {}/{}".format(
                    exact_correct, VALIDATION_EXAMPLES,
                    frozen_correct, VALIDATION_EXAMPLES,
                )
            )

    difference = approx_logits.astype(np.int64) - exact_logits.astype(np.int64)
    exact_products = (
        np.arange(-128, 128, dtype=np.int16)[:, None]
        * np.arange(-128, 128, dtype=np.int16)[None, :]
    ).astype(np.int32)
    product_error = signed_truth.astype(np.int32) - exact_products

    args.output_dir.mkdir(parents=True, exist_ok=True)
    banks = bank_weights(tensors)
    write_rows(args.output_dir / "weight_banks.txt", banks)
    write_flat(
        args.output_dir / "biases.txt",
        np.concatenate((tensors["b1"], tensors["b2"], tensors["b3"])),
    )
    write_rows(args.output_dir / "inputs.txt", inputs)
    write_rows(args.output_dir / "logits.txt", approx_logits)
    write_rows(args.output_dir / "exact_logits.txt", exact_logits)
    write_flat(args.output_dir / "labels.txt", labels)
    write_flat(args.output_dir / "vakili_r1_activation_weight_truth.txt", signed_truth.ravel())
    (args.output_dir / "names.txt").write_text(
        "\n".join(names) + "\n", encoding="utf-8"
    )
    write_adapt_header(args.output_dir / "mul8s_vakili_r1_weight_first.h", adapt_lut)

    generated_names = [
        "weight_banks.txt", "biases.txt", "inputs.txt", "logits.txt",
        "exact_logits.txt", "labels.txt", "names.txt",
        "vakili_r1_activation_weight_truth.txt",
        "mul8s_vakili_r1_weight_first.h",
    ]
    report = {
        "schema_version": 1,
        "stage": "fixed_vakili_r1_ptq_python_reference",
        "status": "PASS",
        "accuracy_threshold_applied": False,
        "acceptance_decision": "NOT_YET_SET",
        "official_test_evaluated": False,
        "manifest": str(args.manifest.relative_to(root)),
        "manifest_sha256": sha256_file(args.manifest),
        "tensor_archive": str(tensor_path.relative_to(root)),
        "selected_candidate": manifest["selected_candidate"],
        "input_scale": input_scale,
        "weight_scales": manifest["quantization_contract"]["weight_scales"],
        "hidden_shifts": shifts,
        "sample_start": args.sample_start,
        "sample_count": args.sample_count,
        "fixed_r1_contract": {
            "hardware_call_order": "R1(weight, activation)",
            "adapt_lut_index_order": "lut[activation_byte][weight_byte]",
            "adapt_kernel_source": "dimdano/adapt@f0ffc2c20684eae7c063410d608c9846d806041e:adapt/cpu-kernels/axx_linear.cpp",
            "signed_activation_weight_truth_sha256": signed_truth_hash,
            "adapt_raw_byte_lut_sha256": adapt_lut_hash,
            "truth_table_bytes": int(signed_truth.nbytes),
            "ordered_pairs": 65536,
            "pairs_changed_by_operand_swap": swapped_pairs,
        },
        "operator_error_vs_exact": {
            "different_pairs": int(np.count_nonzero(product_error)),
            "mean_absolute_error": float(np.mean(np.abs(product_error))),
            "maximum_absolute_error": int(np.max(np.abs(product_error))),
            "mean_signed_error": float(np.mean(product_error)),
        },
        "frozen_exact": {
            "correct": exact_correct,
            "accuracy": float(exact_correct) / args.sample_count,
            "accumulator_maximum_absolute": exact_maxima,
            "hidden_zero_fraction": [
                fraction_equal(exact_hidden1, 0), fraction_equal(exact_hidden2, 0)
            ],
            "hidden_saturation_fraction": [
                fraction_equal(exact_hidden1, 127), fraction_equal(exact_hidden2, 127)
            ],
            "truth_table_sha256": exact_hash,
            "truth_table_bytes": exact_bytes,
        },
        "fixed_vakili_r1_ptq": {
            "correct": approx_correct,
            "accuracy": float(approx_correct) / args.sample_count,
            "accuracy_delta_from_exact": float(approx_correct - exact_correct) / args.sample_count,
            "prediction_disagreements": int(np.count_nonzero(
                approx_predictions != exact_predictions
            )),
            "prediction_disagreement_fraction": float(np.count_nonzero(
                approx_predictions != exact_predictions
            )) / args.sample_count,
            "logit_mean_absolute_difference": float(np.mean(np.abs(difference))),
            "logit_maximum_absolute_difference": int(np.max(np.abs(difference))),
            "accumulator_maximum_absolute": approx_maxima,
            "hidden_zero_fraction": [
                fraction_equal(approx_hidden1, 0), fraction_equal(approx_hidden2, 0)
            ],
            "hidden_saturation_fraction": [
                fraction_equal(approx_hidden1, 127), fraction_equal(approx_hidden2, 127)
            ],
        },
        "generated_file_sha256": {
            name: sha256_file(args.output_dir / name) for name in generated_names
        },
    }
    write_json(args.output_dir / "reference_report.json", report)
    if args.report_path is not None:
        write_json(args.report_path, report)

    print("FIXED_VAKILI_R1_PTQ_REFERENCE_PASS")
    print("Exact: {}/{} ({:.4%})".format(
        exact_correct, args.sample_count, float(exact_correct) / args.sample_count
    ))
    print("Vakili-R1 PTQ: {}/{} ({:.4%})".format(
        approx_correct, args.sample_count, float(approx_correct) / args.sample_count
    ))
    print("Prediction disagreements: {}/{}".format(
        int(np.count_nonzero(approx_predictions != exact_predictions)),
        args.sample_count,
    ))
    print("Signed truth-table SHA-256: {}".format(signed_truth_hash))
    print("AdaPT raw-byte LUT SHA-256: {}".format(adapt_lut_hash))
    print("Output: {}".format(args.output_dir))


if __name__ == "__main__":
    main()

