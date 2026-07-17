#!/usr/bin/env python3
"""Canonical weight-first Vakili-R1 arithmetic and AdaPT LUT generation.

The hardware operator is called as ``R1(weight, activation)``.  AdaPT's
pinned CPU kernel indexes its table as ``lut[activation_byte][weight_byte]``;
the two orders are intentionally bridged here because R1 is not commutative.
"""

from __future__ import print_function

import hashlib
from pathlib import Path

import numpy as np


I32_MIN = -(2 ** 31)
I32_MAX = 2 ** 31 - 1


def _bit(value, index):
    return (value >> index) & 1


def vakili_r1_product(weight, activation):
    """Return the signed INT16 R1 product for raw two's-complement inputs."""
    a = int(weight) & 0xFF
    b = int(activation) & 0xFF

    ps1_term1 = ((1 ^ (_bit(a, 5) & _bit(b, 7))) << 2) \
        | ((_bit(a, 5) & _bit(b, 6)) << 1) \
        | (_bit(a, 5) & _bit(b, 5))
    ps1_term2 = ((1 ^ (_bit(a, 6) & _bit(b, 7))) << 3) \
        | ((_bit(a, 6) & _bit(b, 6)) << 2) \
        | ((_bit(a, 6) & _bit(b, 5)) << 1)
    ps1_term3 = ((_bit(a, 7) & _bit(b, 7)) << 4) \
        | ((1 ^ (_bit(a, 7) & _bit(b, 6))) << 3) \
        | ((1 ^ (_bit(a, 7) & _bit(b, 5))) << 2)
    ps1 = (ps1_term1 + ps1_term2 + ps1_term3) & 0x1F

    ps2_term1 = ((1 ^ (_bit(a, 2) & _bit(b, 7))) << 2) \
        | ((_bit(a, 2) & _bit(b, 6)) << 1) \
        | (_bit(a, 2) & _bit(b, 5))
    ps2_term2 = ((1 ^ (_bit(a, 3) & _bit(b, 7))) << 3) \
        | ((_bit(a, 3) & _bit(b, 6)) << 2) \
        | ((_bit(a, 3) & _bit(b, 5)) << 1)
    ps2_term3 = ((1 ^ (_bit(a, 4) & _bit(b, 7))) << 4) \
        | ((_bit(a, 4) & _bit(b, 6)) << 3) \
        | ((_bit(a, 4) & _bit(b, 5)) << 2)
    ps2 = (ps2_term1 + ps2_term2 + ps2_term3 + 8) & 0x3F

    ps3_term1 = ((_bit(a, 5) & _bit(b, 4)) << 2) \
        | ((_bit(a, 5) & _bit(b, 3)) << 1) \
        | (_bit(a, 5) & _bit(b, 2))
    ps3_term2 = ((_bit(a, 6) & _bit(b, 4)) << 3) \
        | ((_bit(a, 6) & _bit(b, 3)) << 2) \
        | ((_bit(a, 6) & _bit(b, 2)) << 1)
    ps3_term3 = ((1 ^ (_bit(a, 7) & _bit(b, 4))) << 4) \
        | ((1 ^ (_bit(a, 7) & _bit(b, 3))) << 3) \
        | ((1 ^ (_bit(a, 7) & _bit(b, 2))) << 2)
    ps3 = (ps3_term1 + ps3_term2 + ps3_term3) & 0x3F

    ps4_term1 = ((_bit(a, 2) & _bit(b, 4)) << 2) \
        | ((_bit(a, 2) & _bit(b, 3)) << 1) \
        | (_bit(a, 2) & _bit(b, 2))
    ps4_term2 = ((_bit(a, 3) & _bit(b, 4)) << 3) \
        | ((_bit(a, 3) & _bit(b, 3)) << 2) \
        | ((_bit(a, 3) & _bit(b, 2)) << 1)
    ps4_term3 = ((_bit(a, 4) & _bit(b, 4)) << 4) \
        | ((_bit(a, 4) & _bit(b, 3)) << 3) \
        | ((_bit(a, 4) & _bit(b, 2)) << 2)
    ps4 = (ps4_term1 + ps4_term2 + ps4_term3) & 0x3F

    ps5_term1 = ((_bit(a, 1) & _bit(b, 6)) << 1) \
        | (_bit(a, 1) & _bit(b, 5))
    ps5_term2 = ((_bit(a, 6) & _bit(b, 1)) << 1) \
        | (_bit(a, 6) & _bit(b, 0))
    ps5 = (ps5_term1 + ps5_term2) & 0x7

    raw = ((ps1 << 6) + (ps2 << 3) + (ps3 << 3) + ps4
           + (ps5 << 2)) & 0x7FF
    raw_signed = raw - 0x800 if raw & 0x400 else raw
    result = (raw_signed * 16) & 0xFFFF
    return result - 0x10000 if result & 0x8000 else result


def build_signed_activation_weight_truth_table():
    """Build signed-order truth[activation + 128][weight + 128]."""
    table = np.empty((256, 256), dtype=np.int16)
    for activation_index, activation in enumerate(range(-128, 128)):
        for weight_index, weight in enumerate(range(-128, 128)):
            table[activation_index, weight_index] = vakili_r1_product(
                weight, activation
            )
    return table


def build_adapt_activation_weight_lut():
    """Build raw-byte ``lut[activation_byte][weight_byte]`` for AdaPT."""
    table = np.empty((256, 256), dtype=np.int16)
    for activation_byte in range(256):
        for weight_byte in range(256):
            table[activation_byte, weight_byte] = vakili_r1_product(
                weight_byte, activation_byte
            )
    return table


def int16_table_sha256(table):
    encoded = np.ascontiguousarray(table, dtype="<i2")
    return hashlib.sha256(encoded.tobytes(order="C")).hexdigest()


def dense_vakili_r1(
    inputs,
    weights,
    biases,
    lut,
    batch_size,
    output_chunk,
    layer_name,
):
    """Evaluate one dense layer through the activation-major R1 LUT."""
    if inputs.dtype != np.int8 or weights.dtype != np.int8:
        raise TypeError("{} expects INT8 inputs and weights".format(layer_name))
    if output_chunk < 1:
        raise ValueError("output_chunk must be positive")
    outputs = np.empty((len(inputs), len(weights)), dtype=np.int64)
    weight_bytes = weights.astype(np.uint8)
    maximum = 0
    for sample_start in range(0, len(inputs), batch_size):
        sample_end = min(len(inputs), sample_start + batch_size)
        activation_bytes = inputs[sample_start:sample_end].astype(np.uint8)
        for output_start in range(0, len(weights), output_chunk):
            output_end = min(len(weights), output_start + output_chunk)
            products = lut[
                activation_bytes[:, None, :],
                weight_bytes[None, output_start:output_end, :],
            ]
            wide = np.sum(products, axis=2, dtype=np.int64)
            wide += biases[None, output_start:output_end].astype(np.int64)
            if np.any((wide < I32_MIN) | (wide > I32_MAX)):
                raise RuntimeError("{} overflowed signed INT32".format(layer_name))
            maximum = max(maximum, int(np.max(np.abs(wide))))
            outputs[
                sample_start:sample_end, output_start:output_end
            ] = wide
    return outputs, maximum


def write_adapt_header(path, lut):
    """Write the header format required by pinned AdaPT's axx_linear.cpp."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("#pragma once\n#include <stdint.h>\n\n")
        stream.write("// lut[activation_byte][weight_byte]; R1(weight, activation)\n")
        stream.write("const int16_t lut[256][256] = {\n")
        for row_index, row in enumerate(lut):
            suffix = "," if row_index != 255 else ""
            stream.write("    {")
            stream.write(", ".join(str(int(value)) for value in row))
            stream.write("}" + suffix + "\n")
        stream.write("};\n")
    if path.is_file() and path.read_bytes() == temporary.read_bytes():
        temporary.unlink()
    else:
        temporary.replace(path)
