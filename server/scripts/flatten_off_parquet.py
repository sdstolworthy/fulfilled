#!/usr/bin/env python3
"""Flatten a current-format OpenFoodFacts parquet into the flat schema the
Rust ingest binary expects.

The 2025+ OFF parquet packs nutrition into a list-of-structs column
(`nutriments`) keyed by nutrient name. The Rust parser at
`crates/loseit-ingest/src/parquet_source.rs` was written against the
older flat layout with columns like `energy-kcal_100g`. Until that
parser is updated to read the nested form, this script bridges the gap:
it reads the source parquet, picks the per-100g value out of the
nutriments list for each nutrient we care about, and writes a new
parquet whose schema matches the existing parser.

Usage:
    python flatten_off_parquet.py INPUT.parquet OUTPUT.parquet

Runs DuckDB in-process; no external DB needed. Memory footprint is
bounded by DuckDB's spill-to-disk; it should fit comfortably in a few
GB even on the full ~7.5 GB OFF dump.
"""

from __future__ import annotations

import sys
from pathlib import Path

import duckdb

# Nutrient names to pull out of the `nutriments` list, mapped to the flat
# column names the Rust parser expects.
NUTRIENT_MAP: list[tuple[str, str]] = [
    ("energy-kcal", "energy-kcal_100g"),
    ("proteins", "proteins_100g"),
    ("carbohydrates", "carbohydrates_100g"),
    ("fat", "fat_100g"),
    ("fiber", "fiber_100g"),
    ("sugars", "sugars_100g"),
    ("sodium", "sodium_100g"),
    ("saturated-fat", "saturated-fat_100g"),
]


def build_query(input_path: str, output_path: str) -> str:
    # DuckDB note: `unnest()` doesn't expose struct fields by name, so we
    # use `list_filter` to slice the nutriments list down to the single
    # element with the right `name`, take its first item (`[1]`, NULL-safe
    # on empty), and then field-access the per-100g value.
    nutrient_projections = ",\n        ".join(
        f"list_filter(nutriments, n -> n.name = '{name}')[1].\"100g\" "
        f"AS \"{flat_name}\""
        for name, flat_name in NUTRIENT_MAP
    )
    return f"""
        COPY (
            SELECT
                code,
                product_name,
                brands,
                categories_tags,
                nutriscore_grade,
                completeness,
                serving_size,
                serving_quantity,
                {nutrient_projections}
            FROM read_parquet('{input_path}')
        ) TO '{output_path}' (FORMAT PARQUET, COMPRESSION ZSTD);
    """


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} INPUT.parquet OUTPUT.parquet", file=sys.stderr)
        return 2
    input_path = Path(argv[1]).resolve()
    output_path = Path(argv[2]).resolve()
    if not input_path.exists():
        print(f"error: input not found: {input_path}", file=sys.stderr)
        return 1

    con = duckdb.connect()
    con.execute(build_query(str(input_path), str(output_path)))
    con.close()
    print(f"wrote {output_path} ({output_path.stat().st_size / 1e9:.2f} GB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
