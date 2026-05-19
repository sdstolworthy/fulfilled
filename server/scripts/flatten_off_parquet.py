#!/usr/bin/env python3
"""Flatten a current-format OpenFoodFacts parquet into the flat schema the
Rust ingest binary expects.

The 2025+ OFF parquet packs nutrition into a list-of-structs column
(`nutriments`) keyed by nutrient name, and packages localized text
fields like `product_name` as `struct(lang, text)[]`. The Rust parser
at `crates/loseit-ingest/src/parquet_source.rs` was written against
the older flat layout. Until the Rust side learns to unpack nested
columns directly, this script bridges the gap: it reads the source
parquet, picks the per-100g value out of the nutriments list, picks
an English (or fallback) text out of each localized struct, and
writes a new parquet whose schema matches the Rust projection.

Usage:
    python flatten_off_parquet.py INPUT.parquet OUTPUT.parquet

Runs DuckDB in-process; no external DB needed. Memory footprint is
bounded by DuckDB's spill-to-disk; the full ~7.5 GB OFF dump fits
comfortably in a few GB of RAM.

Output schema mirrors `PROJECTED_COLUMNS` in `parquet_source.rs`.
Keep them aligned — when you add a new column there, add it here.
"""

from __future__ import annotations

import sys
from pathlib import Path

import duckdb

# Nutrient names to pull out of the `nutriments` list, mapped to the flat
# column names the Rust parser expects. `energy-kj` is included so the
# Phase 1.1 kJ→kcal fallback can fire on rows that ship kJ but no kcal.
NUTRIENT_MAP: list[tuple[str, str]] = [
    ("energy-kcal", "energy-kcal_100g"),
    ("energy-kj", "energy-kj_100g"),
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
    nutrient_projections = ",\n            ".join(
        f"list_filter(nutriments, n -> n.name = '{name}')[1].\"100g\" "
        f"AS \"{flat_name}\""
        for name, flat_name in NUTRIENT_MAP
    )
    # `product_name` is a `list<struct<lang, text>>` in the modern dump.
    # Prefer English, then OFF's "main" canonical entry, then anything
    # non-null. The triple COALESCE is so a missing English variant
    # never blocks ingest — non-English brands are still valuable.
    return f"""
        COPY (
            SELECT
                code,
                COALESCE(
                    list_filter(product_name, p -> p.lang = 'en')[1]."text",
                    list_filter(product_name, p -> p.lang = 'main')[1]."text",
                    list_filter(product_name, p -> p."text" IS NOT NULL)[1]."text"
                ) AS product_name,
                brands,
                categories_tags,
                nutriscore_grade,
                completeness,
                serving_size,
                serving_quantity,
                {nutrient_projections},
                states_tags,
                obsolete,
                -- Rust side expects a string `"on"` for "explicitly no
                -- nutrition data" — mirror the OFF JSON sentinel.
                CASE WHEN no_nutrition_data THEN 'on' ELSE NULL END
                    AS no_nutrition_data,
                last_modified_t,
                data_quality_errors_tags
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
