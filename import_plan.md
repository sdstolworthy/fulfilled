# Fulfilled food-database import plan

**Status:** draft, awaiting review · **Owner:** backend · **Created:** 2026-05-19

This plan lays out the strategy to import the Open Food Facts (OFF) and USDA
FoodData Central (FDC) databases into Postgres so that `/foods/search` returns
real products instead of test fixtures. It synthesizes three research/audit
passes (OFF dataset, FDC dataset, current `loseit-ingest` crate).

The pipeline already exists end-to-end (`loseit-ingest` CLI → `IngestService` →
`PgFoodRepository::upsert_external_food_batch` → `food_import_batches`
provenance). It has not been run against real dumps yet because the audit
surfaced multiple silent-data-loss and silent-corruption bugs. **Phase 1 below
is what blocks the first real import; everything else is operational polish.**

---

## 1. Goal & success criteria

- Run a full OFF import (the HuggingFace `food.parquet` slim subset, ~4.5M rows)
  and a full USDA FDC import (Branded + Foundation + SR Legacy combined zip,
  ~1.9M + ~8k rows) end-to-end against the production database.
- `food_import_batches` ends with `status='completed'` for each source and
  reasonable `records_seen / records_upserted / records_skipped` ratios
  (skipped < 25% for OFF, < 5% for USDA).
- `/foods/search?q=…` returns kcal-correct hits across both English and
  non-English brands.
- License attribution surfaces (OFF ODbL) are wired into the FE about page
  before any user-facing OFF data ships.

A run is **not** successful if any of these are true:
- Branded USDA kcal values are off by ~3–5× (the per-serving footgun).
- > 10% of OFF rows are silently dropped because the parser saw kJ-only energy.
- One bad row aborts the entire import (`?`-bubbled error halts at row N).
- The same Branded product appears once from OFF and again from USDA without a
  unifying GTIN.

---

## 2. Data sources

### 2.1 OFF — HuggingFace Parquet (recommended)

- **URL:** `https://huggingface.co/datasets/openfoodfacts/product-database/resolve/main/food.parquet`
- **Size:** ~3–4 GB on disk; ~4.5M rows
- **Cadence:** regenerated nightly by `openfoodfacts-exports`
- **Why parquet over JSONL:** flat-ish projection, already columnar, no struct
  flattening for the fields we care about, ~6× smaller than the JSONL gz
- **License:** ODbL v1.0 (database) + DbCL v1.0 (records) + CC-BY-SA 3.0
  (images). **Share-alike applies** to any derived public database — we do not
  redistribute the DB, so this only obligates us to attribute, not to relicense
  our own code.
- **Required attribution:** visible "Open Food Facts" + link to
  `https://world.openfoodfacts.org` on any screen that surfaces OFF data, plus
  the dump date stamped in `food_import_batches.source_etag` / `source_url`.

### 2.2 USDA FDC — Combined JSON dump

- **Datasets we ingest:** Branded (~1.9M), Foundation (~300), SR Legacy
  (~7,800). **Skip** Survey (FNDDS — mixed-dish, not consumer SKUs) and
  Experimental.
- **Distribution:** `https://fdc.nal.usda.gov/download-datasets/` — one zip per
  dataset (`FoodData_Central_branded_food_json_<date>.zip`, etc.). The combined
  csv bundle exists but the JSON ones are easier to ingest because our reader
  is already JSON.
- **Cadence:** Foundation bi-annual, SR Legacy frozen, Branded monthly via API
  but the *download* refreshes only twice a year (April/October).
- **License:** US public domain / CC0. Cite as "U.S. Department of Agriculture,
  Agricultural Research Service. FoodData Central, YYYY." No logo required.
- **Live API fallback:** `https://api.nal.usda.gov/fdc/v1/`, 1,000
  req/hour/IP with a registered key — useful for re-enrichment of a single
  fdcId, not for bulk.

### 2.3 Acquisition (operator steps)

```bash
# stage on the BE host under /opt/loseit/import/<date>/
mkdir -p /opt/loseit/import/2026-05-19 && cd $_

# OFF parquet
curl -L -o off-food.parquet \
  https://huggingface.co/datasets/openfoodfacts/product-database/resolve/main/food.parquet
sha256sum off-food.parquet | tee off-food.parquet.sha256

# USDA — three zips
for ds in branded_food foundation_food sr_legacy_food; do
  curl -L -o usda-${ds}.zip \
    "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_${ds}_json_2025-12-18.zip"
  sha256sum usda-${ds}.zip | tee usda-${ds}.zip.sha256
  unzip usda-${ds}.zip
done
```

The exact filename suffix (`2025-12-18`) tracks the most recent FDC release;
re-derive it from the [download index](https://fdc.nal.usda.gov/download-datasets/)
before kicking off an import.

---

## 3. Current pipeline (from the audit)

Five-line summary so reviewers don't need to re-read the audit:

1. CLI at `loseit-ingest/src/main.rs:66-147` dispatches by `--source {off,usda}`
   + `--format {jsonl,parquet}` into `IngestService::run_off|run_usda`.
2. Sources implement `FoodRecordSource` / `UsdaSource`
   (`loseit-core/src/service/ingest.rs:87-102`) — OFF parquet via
   `parquet_source.rs`, OFF JSONL via `jsonl.rs`, USDA via `usda_jsonl.rs`.
3. Normalization in `loseit-core/src/service/ingest.rs` (per-100g → per-serving,
   companion `{100, g}` serving, sodium sanity clamp).
4. Write path is `PgFoodRepository::upsert_external_food_batch`
   (`loseit-db/src/food_repo.rs:448-559`) — per-food `INSERT ... ON CONFLICT`
   plus a per-food transaction for `DELETE servings; INSERT serving × N`.
5. Provenance lives in `food_import_batches` (`batch_repo.rs`): `source_url`,
   `source_etag`, `records_seen|upserted|skipped`, `status`, `error`. Counters
   are bumped per batch by `BatchRepository::bump_counts`.

---

## 4. Phased fix plan

Each item below has: **audit-rank → fix → file:line target → test target →
phase**. Phase numbers are merge-order, not parallelism (Phase 1 must land
before Phase 2 is meaningful, etc.).

### Phase 1 — Correctness blockers (must land before first real import)

| # | Fix | Touchpoints | Test |
|---|-----|-------------|------|
| 1.1 | Read OFF `energy-kj_100g`; derive `kcal = kj / 4.184` when `energy-kcal_100g` is missing | `loseit-ingest/src/jsonl.rs` (OffRaw), `parquet_source.rs` (PROJECTED_COLUMNS, decoder), `loseit-core/src/service/ingest.rs::accept_and_normalize_off` | new unit test: kJ-only row → emits serving with kcal/4.184 ± 0.01 |
| 1.2 | Rescale USDA **Branded** nutrients from per-serving → per-100 g using `servingSize` + `servingSizeUnit` (`g`/`GRM`/`ml`/`MLT`) | `loseit-ingest/src/usda_jsonl.rs` (UsdaRaw — wire `servingSize`, `servingSizeUnit`, `dataType`), `loseit-core/src/service/ingest.rs::accept_and_normalize_usda` | new unit test: 30g cookie reporting 140 kcal/serving → 466 kcal/100g; mirror for ml |
| 1.3 | Tolerate textual nutrient values (`"trace"`, `"<0.5"`, comma-decimal `"1,5"`) instead of dropping the whole line | `loseit-ingest/src/jsonl.rs::deserialize_number_or_string`-style enum for every nutrient field on `OffRaw` | unit tests for each variant; pin the existing "whole line dropped on serde failure" behavior as a regression marker |
| 1.4 | Per-field sanity clamps: `kcal_100g ∈ (0, 900]`; each macro `∈ [0, 100] g/100g`; clamp sodium already exists | `loseit-core/src/service/ingest.rs::accept_and_normalize_off` and `_usda` | unit tests: 5000 kcal → null + log; -2g protein → null |
| 1.5 | Make per-row `upsert_external_food_batch` failures **skip-and-log** instead of aborting; bump `records_skipped` | `loseit-db/src/food_repo.rs:448-559`, plumb `Vec<SkipReason>` back to `IngestService` | integration test: inject a bad row via in-memory repo; pipeline finishes with `status='completed'` and `records_skipped == 1` |
| 1.6 | Filter OFF rows with `states_tags ∋ {en:to-be-deleted, en:obsolete}` or `obsolete == true` | `OffRaw` + `PROJECTED_COLUMNS` add `states_tags`, `obsolete`; drop predicate in `accept_and_normalize_off` | unit tests: spam/joke fixture rows are dropped; valid rows pass |
| 1.7 | Drop all-zero / no-data OFF rows: skip when `no_nutrition_data == "on"` (already?) OR `kcal_100g == 0` AND every macro is 0/None | `accept_and_normalize_off` | unit test: all-zero row dropped |

### Phase 2 — Operational robustness (so we can rerun and watch progress)

| # | Fix | Touchpoints | Test |
|---|-----|-------------|------|
| 2.1 | Compute file SHA-256 + size, pass as `source_etag`; short-circuit when a `status='completed'` batch already has that etag | `loseit-ingest/src/main.rs`, `batch_repo.rs::start` | integration test: second run with same etag → no-op |
| 2.2 | `tracing::info!` per chunk: `processed=X seen=Y skipped=Z throughput=R/s ETA=…` | `IngestService::run_inner` / `run_usda_inner` | manual: tail logs during a smoke run |
| 2.3 | Loud-fail when USDA `data_type` enum is unknown; bump a `records_rejected_at_db` counter rather than silently `continue` | `food_repo.rs:521-531`, new column? or fold into `skipped` with a log line | unit test in the repo layer |

### Phase 3 — Performance & throughput (so a full run is < 1h, not 4h+)

| # | Fix | Touchpoints | Test |
|---|-----|-------------|------|
| 3.1 | Wrap each food's UPSERT + serving DELETE+INSERT in a **single** transaction (atomicity) | `food_repo.rs::upsert_external_food_batch` | unit test: connection-drop mid-write leaves food with **no** new state |
| 3.2 | Batch 100–500 foods per outer transaction | same | benchmark: 10k-row dummy import drops from ~Ns to ~N/5s |
| 3.3 | Switch the serving INSERT loop to `COPY ... FROM STDIN` (via `sqlx::copy_in_raw`) | `food_repo.rs::insert_serving_in_tx` and call sites | benchmark: serving write throughput ≥ 5× |

### Phase 4 — Data quality & cross-source dedup

| # | Fix | Touchpoints | Test |
|---|-----|-------------|------|
| 4.1 | On USDA Branded import, stamp `foods.barcode = gtinUpc` (string, preserve leading zeros) so the OFF UPSERT `ON CONFLICT (barcode)` deduplicates | `usda_jsonl.rs` raw struct + `food_repo.rs` upsert | unit test: import OFF row for barcode `X`, then USDA Branded for same `X` → single row |
| 4.2 | Normalize OFF `code` strictly as string with preserved leading zeros end-to-end (it already is — verify with a leading-zero fixture) | `OffRaw.code`, parquet column type | regression test for `"0049000028911"` |
| 4.3 | Track per-batch dedupe stats (`records_merged` separate from `records_skipped`) | `BatchRepository::bump_counts` schema | unit |
| 4.4 | Stale-row drop: skip OFF rows with `last_modified_t` older than 5 years (configurable) | `OffRaw.last_modified_t` + drop predicate | unit |

### Phase 5 — License & app wire-up (FE coordination required)

| # | Fix | Touchpoints | Test |
|---|-----|-------------|------|
| 5.1 | About-page attribution row for OFF (ODbL — required) and USDA (CC0 — courtesy citation) | FE `lib/features/settings/about_screen.dart` (deferred — FE audit) | manual visual check |
| 5.2 | Per-food badge on search hits: "OFF" / "USDA" so users know provenance | FE search row (deferred — FE audit) | manual |

Phase 5 ships **after** the FE audit lifts. Until then, ingest can run safely
because the BE doesn't surface attribution itself — the legal obligation only
kicks in when OFF data is shown to users, and the FE doesn't read /foods yet
for real users in production.

---

## 5. Run procedure (post-Phase-1)

```bash
# from server/
cargo run --release -p loseit-ingest -- \
  --source off \
  --format parquet \
  --input /opt/loseit/import/2026-05-19/off-food.parquet \
  --source-url https://huggingface.co/datasets/openfoodfacts/product-database

cargo run --release -p loseit-ingest -- \
  --source usda \
  --format jsonl \
  --input /opt/loseit/import/2026-05-19/FoodData_Central_branded_food_json_2025-12-18.json \
  --source-url https://fdc.nal.usda.gov/download-datasets/

# repeat for foundation_food + sr_legacy_food
```

Run on a host with at least 4 GB RAM and direct Postgres reach. The container
image already includes the binary (see `crates/loseit-ingest/Dockerfile` if it
exists; otherwise build statically and `scp`). **For the first real import,
run a 10k-row `--limit` smoke first**, sanity-check ratios in
`food_import_batches`, then run unbounded.

---

## 6. Post-import verification

Run these queries before opening the floodgates:

```sql
-- 6.1 batch-level sanity
SELECT source, status, records_seen, records_upserted, records_skipped,
       records_seen - records_upserted - records_skipped AS unaccounted
FROM food_import_batches ORDER BY created_at DESC LIMIT 10;

-- 6.2 kcal distribution sanity (should peak 100-500, drop off above 700)
SELECT width_bucket(kcal_100g, 0, 1000, 20) AS bucket, COUNT(*)
FROM servings WHERE serving_size_g = 100 GROUP BY bucket ORDER BY bucket;

-- 6.3 cross-source dedup: shared GTIN should appear once
SELECT barcode, COUNT(*) FROM foods
WHERE barcode IS NOT NULL GROUP BY barcode HAVING COUNT(*) > 1 LIMIT 20;

-- 6.4 random product spot-checks
SELECT id, source, name, brands FROM foods
WHERE name ILIKE 'oreo%' ORDER BY random() LIMIT 5;
```

If 6.1 shows `unaccounted > 0`, the skip-and-log path (1.5) is leaking; if 6.2
has > 1% over kcal=900 the sanity clamp (1.4) is broken; if 6.3 has many
multi-row groups the Branded GTIN merge (4.1) hasn't run.

---

## 7. Open decisions

These are not blockers for Phase 1 but the operator should pick a default
before the first prod import:

- **OFF country filter:** ingest all `countries_tags`, or restrict to
  `en:united-states` for the v1? Smaller index + faster search vs missing brands
  for non-US users. *Recommend: ingest all; ranker can prefer `en:united-states`
  at query time.*
- **OFF completeness threshold:** drop rows with `completeness < 0.5`?
  *Recommend: yes for v1; revisit if search results feel sparse.*
- **USDA Survey (FNDDS):** include the dataset? It logs "as eaten" (mixed
  dishes) which is useful for restaurant entries but inflates index size with
  duplicates of branded products. *Recommend: skip for v1.*
- **USDA Foundation vs SR Legacy on overlapping foods:** Foundation has
  Atwater-specific kcal (more accurate); SR Legacy has wider coverage. When
  both have the same description, which wins? *Recommend: prefer Foundation
  (newer + analytically derived); fall back SR Legacy.*

---

## 8. Next steps

1. Review this plan; align on Phase-1 scope and the open decisions in §7.
2. Dispatch Phase 1 (TPM → engineer pipeline) to land fixes 1.1–1.7 as one
   sequenced PR — they share the `OffRaw` / `UsdaRaw` / `accept_and_normalize_*`
   surface and are best landed together.
3. Smoke-run 10k-row OFF + 10k-row USDA-Branded imports against a scratch DB;
   verify §6 queries.
4. Land Phase 2 (etag + progress logs) so reruns are safe + observable.
5. Run full prod import behind a feature flag (read path off until §6 spot
   checks pass).
6. Phase 3 / Phase 4 as follow-ups; Phase 5 once the FE audit lifts.

---

## References

- OFF data portal: <https://world.openfoodfacts.org/data>
- OFF HuggingFace parquet: <https://huggingface.co/datasets/openfoodfacts/product-database>
- OFF nutrients handling: <https://wiki.openfoodfacts.org/Nutrients_handling_in_Open_Food_Facts>
- FDC downloads: <https://fdc.nal.usda.gov/download-datasets/>
- FDC API guide: <https://fdc.nal.usda.gov/api-guide/>
- FDC Foundation Foods docs: <https://fdc.nal.usda.gov/Foundation_Foods_Documentation/>
- FDC Branded docs: <https://fdc.nal.usda.gov/GBFPD_Documentation/>
