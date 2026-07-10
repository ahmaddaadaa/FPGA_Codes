#!/usr/bin/env python3
"""Compare a VHDL multiplier CSV against one or more ADAPT-style LUT headers.

Expected CSV columns: a,b,p_signed
Expected LUT header format: const int16_t lut [256][256] = { ... };

The script tries both common signed-int8 indexing conventions:
  twos:   lut[a & 0xff][b & 0xff]
  offset: lut[a + 128][b + 128]

It also tries simple output alignment transforms on the LUT values. This is useful
for Vakili because the wrapper may left-shift raw_result before exposing p.
"""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path
from typing import Callable, Iterable


def to_s16(x: int) -> int:
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def arshift_s16(x: int, sh: int) -> int:
    x = to_s16(x)
    return to_s16(x >> sh)


def lshift_s16(x: int, sh: int) -> int:
    return to_s16(x << sh)


def strip_c_comments(text: str) -> str:
    # Remove /* ... */ block comments.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    # Remove // line comments.
    text = re.sub(r"//.*?$", "", text, flags=re.MULTILINE)
    return text


def extract_initializer_body(text: str) -> str:
    text = strip_c_comments(text)

    # Find the lut declaration and the first initializer brace after '='.
    m = re.search(r"\blut\s*\[\s*256\s*\]\s*\[\s*256\s*\]\s*=", text)
    if not m:
        raise ValueError("Could not find lut[256][256] initializer")

    start_eq = m.end()
    start_brace = text.find("{", start_eq)
    if start_brace < 0:
        raise ValueError("Could not find opening brace for LUT initializer")

    depth = 0
    for i in range(start_brace, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start_brace + 1:i]

    raise ValueError("Could not find matching closing brace for LUT initializer")


def parse_lut_header(path: Path) -> list[list[int]]:
    text = path.read_text(errors="ignore")
    body = extract_initializer_body(text)

    nums = [int(m.group(0)) for m in re.finditer(r"-?\d+", body)]

    if len(nums) != 256 * 256:
        raise ValueError(f"{path}: expected 65536 LUT entries, parsed {len(nums)}")

    return [nums[i * 256:(i + 1) * 256] for i in range(256)]

def read_csv(path: Path) -> list[tuple[int, int, int]]:
    rows: list[tuple[int, int, int]] = []
    with path.open(newline="") as f:
        r = csv.DictReader(f)
        for row in r:
            rows.append((int(row["a"]), int(row["b"]), int(row["p_signed"])))
    if len(rows) != 256 * 256:
        print(f"Warning: CSV has {len(rows)} rows, expected 65536 for exhaustive int8 test")
    return rows


def transform_candidates() -> list[tuple[str, Callable[[int], int]]]:
    cands: list[tuple[str, Callable[[int], int]]] = [("identity", lambda x: to_s16(x))]
    for sh in range(1, 13):
        cands.append((f"lut << {sh}", lambda x, sh=sh: lshift_s16(x, sh)))
    for sh in range(1, 13):
        cands.append((f"lut >> {sh}", lambda x, sh=sh: arshift_s16(x, sh)))
    return cands


def compare_one(csv_rows: list[tuple[int, int, int]], lut_path: Path, show_mismatches: int) -> None:
    lut = parse_lut_header(lut_path)
    indexers = [
        ("twos", lambda a, b: (a & 0xFF, b & 0xFF)),
        ("offset", lambda a, b: (a + 128, b + 128)),
    ]

    best = None
    print(f"\n=== {lut_path} ===")

    for idx_name, indexer in indexers:
        for tr_name, tr in transform_candidates():
            matches = 0
            first_bad = []
            for a, b, p in csv_rows:
                ia, ib = indexer(a, b)
                lv = tr(lut[ia][ib])
                if lv == p:
                    matches += 1
                elif len(first_bad) < show_mismatches:
                    first_bad.append((a, b, p, lv, lut[ia][ib]))

            pct = 100.0 * matches / len(csv_rows)
            rec = (matches, pct, idx_name, tr_name, first_bad)
            if best is None or matches > best[0]:
                best = rec

            if matches == len(csv_rows):
                print(f"PERFECT MATCH: indexing={idx_name}, transform={tr_name}")
                return

    assert best is not None
    matches, pct, idx_name, tr_name, first_bad = best
    print(f"Best match: {matches}/{len(csv_rows)} = {pct:.4f}%")
    print(f"  indexing={idx_name}, transform={tr_name}")
    if first_bad:
        print("  First mismatches for best candidate: a,b,hdl_p,transformed_lut_p,raw_lut")
        for item in first_bad:
            print(f"    {item}")

    # Print useful probe values under the best candidate.
    lut = parse_lut_header(lut_path)
    idx_fn = dict(indexers)[idx_name]
    tr_fn = dict(transform_candidates())[tr_name]
    probes = [(0,0), (1,1), (1,127), (4,32), (8,16), (16,16), (32,4),
              (127,127), (-1,1), (-4,32), (-16,-16), (-128,-128)]
    hdl_map = {(a,b): p for a,b,p in csv_rows}
    print("  Probe comparison: a,b,hdl_p,transformed_lut_p,raw_lut,exact")
    for a, b in probes:
        ia, ib = idx_fn(a, b)
        raw = lut[ia][ib]
        print(f"    {a:4d},{b:4d},{hdl_map.get((a,b),'NA'):>7},{tr_fn(raw):>7},{raw:>7},{a*b:>7}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True, type=Path, help="CSV generated by tb_vakili_wrapper_csv")
    ap.add_argument("--lut", required=True, type=Path, nargs="+", help="One or more ADAPT-style LUT headers")
    ap.add_argument("--show-mismatches", type=int, default=8)
    args = ap.parse_args()

    rows = read_csv(args.csv)
    for lut_path in args.lut:
        compare_one(rows, lut_path, args.show_mismatches)


if __name__ == "__main__":
    main()
