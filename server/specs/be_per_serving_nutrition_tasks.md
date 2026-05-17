# BE-Ask10 — Per-serving nutrition + unit families + flatten migrations + USDA/OFF ingest — Task Breakdown

16 sequential tasks on branch `be-per-serving-nutrition`. Each maps to one
commit; each ends green on `cargo check --workspace` minimum, with tests
added in their dedicated tasks. T01 (migration) gates all downstream work.

Design reference: [`be_per_serving_nutrition_design.md`](be_per_serving_nutrition_design.md)
Ask source: [`ask_10_per_serving_nutrition.md`](../../ask_10_per_serving_nutrition.md)
Ledger: [`backend_tickets_ledger.md`](backend_tickets_ledger.md) — BE / Ask 10

Open question pre-resolved: The architect flagged "Should `FoodService::create_custom`
keep auto-synthesizing a default `100 g` serving if the client sends an empty servings
list?" — **Answer: delete the synthesizer.** Per the user's "stop anchoring nutrition to
per-100g mass" directive. No engineer re-ask needed. See T08.

---

## T01 — Migration: flatten 0001..0009 into new `0001_initial.sql`

**Subject:** Delete old migration chain; replace with single flat `0001_initial.sql` that
implements the Ask 10 schema reshape.

**What changes:**
- Delete `server/migrations/0001_initial.sql` through `0009_oidc_handoff_codes.sql` (nine files).
- Create new `server/migrations/0001_initial.sql` verbatim per §3.2 of the design. Tables changed:
  `foods` (drops all `*_100g` columns), `servings` (`{amount, unit}` + per-serving nutrition),
  `food_log_entries` (drops `grams_total`, adds `entered_amount` + `entered_unit`). All other tables
  (`users`, `users_local_auth`, `local_auth_tokens`, `oidc_handoff_codes`, `food_import_batches`,
  `weights`, `goals`) are preserved verbatim from their last-applied form.
- Document the `_sqlx_migrations` reset runbook in `COOLIFY.md` (or `compose.coolify.yaml`
  operator comment) per §10 R1. The Coolify deploy requires either a fresh DB drop+recreate or
  a `DROP TABLE _sqlx_migrations` before the server boots against the new file.
- No Rust changes.

**Acceptance:**
- `cargo check --workspace` green.
- New migration file exists at `server/migrations/0001_initial.sql`.
- All nine old migration files are gone.
- Operator runbook for `_sqlx_migrations` reset is documented.

**Files touched:** 10 (delete 9, create 1, update deploy doc)

**Depends on:** none

**Design ref:** §3.1, §3.2, §10 R1 of be_per_serving_nutrition_design.md

---

## T02 — Core domain: new `unit.rs` + reshape `food.rs` / `serving.rs` / `log_entry.rs`

**Subject:** Add `Unit` + `UnitFamily` types; reshape all domain structs to the per-serving
nutrition model; delete `NutritionPer100g` and related ingest artifacts.

**What changes:**
- Create `server/crates/loseit-core/src/domain/unit.rs` per §4.1: `Unit` enum (12 variants),
  `UnitFamily` enum, `as_str`, `parse`, `family()`, `ratio_to_canonical()`. Confirm
  `rust_decimal_macros` is a workspace dep (R6 in design); add it to `server/Cargo.toml` if missing.
- Reshape `server/crates/loseit-core/src/domain/food.rs` per §4.2: drop `NutritionPer100g`,
  `nutrition` field on `Food`, `OffFoodUpsert`, `OffServing`, `SystemServing`. `FoodDraft` gains
  `servings: Vec<ServingDraft>`. `FoodSearchHit` + `ServingPreview` drop `calories_per_serving` /
  `grams`; gain `kcal: Decimal`, `amount: Decimal`, `unit: Unit`.
- Reshape `server/crates/loseit-core/src/domain/serving.rs` per §4.3: `Serving` gains `amount`,
  `unit: Unit`, `kcal`, and 7 optional macro fields; `label` becomes `Option<String>`. Drop `grams`.
  New `ServingDraft` and `ServingPatch`. `sodium_mg` is mg-native throughout (no more g→mg dance).
- Reshape `server/crates/loseit-core/src/domain/log_entry.rs` per §4.4: `FoodLogEntry` drops
  `grams_total`; gains `entered_amount: Decimal`, `entered_unit: Unit`. `LogDraft` drops `quantity`
  (service-derived); gains `entered_amount` + `entered_unit`. `LogPatch`, `PersistedLogEntry`,
  `RecomputedSnapshot` updated to match.
- Re-export `Unit`, `UnitFamily` from `domain/mod.rs`.

**Acceptance:**
- `cargo check -p loseit-core` green (downstream crates will break; that is expected — T03–T08 fix them layer by layer).
- `NutritionPer100g`, `OffFoodUpsert`, `OffServing`, `SystemServing` are gone.

**Files touched:** 5 (unit.rs new; food.rs, serving.rs, log_entry.rs, domain/mod.rs edited; Cargo.toml if rust_decimal_macros missing)

**Depends on:** T01 (migration must be in place before domain types can reference Unit CHECK values)

**Design ref:** §4.1–§4.4 of be_per_serving_nutrition_design.md

---

## T03 — Repo traits: `FoodRepository` / `ServingRepository` / `LogRepository` signatures

**Subject:** Update all three repo trait definitions in `loseit-core` to match the new domain
shapes; add `FoodDraftWithServings`.

**What changes:**
- `server/crates/loseit-core/src/repo/food.rs` (trait):
  - `create_custom` → `create_custom_with_servings(owner, draft, servings: Vec<ServingDraft>)`.
  - Add `update_custom_with_servings(owner, id, patch, Option<Vec<ServingDraft>>)`.
  - Rename `upsert_off_batch` → `upsert_external_food_batch(batch: Vec<FoodDraftWithServings>)`.
  - `find_or_create_quick_add` return type updates to new `Serving` shape.
- Add `FoodDraftWithServings { draft: FoodDraft, quality_score: i16, servings: Vec<ServingDraft> }` to `food.rs` or a new `ingest.rs` domain module.
- `server/crates/loseit-core/src/repo/serving.rs` (trait): `create` / `update` adapt to `ServingDraft` / `ServingPatch`.
- `server/crates/loseit-core/src/repo/log.rs` (trait): signatures unchanged at the trait level; the persisted type changes propagate automatically from T02.

**Acceptance:**
- `cargo check -p loseit-core` green.
- Trait methods match their new signatures; `FoodDraftWithServings` is exported.

**Files touched:** 3–4 (repo/food.rs, repo/serving.rs, repo/log.rs, possibly repo/mod.rs)

**Depends on:** T02 (domain types must exist before traits can reference them)

**Design ref:** §6.2 of be_per_serving_nutrition_design.md

---

## T04 — Pg repos: `PgFoodRepository` rewrite

**Subject:** Rewrite `PgFoodRepository` against the new schema: drop all `*_100g` column
bindings; implement transactional `create_custom_with_servings` and `update_custom_with_servings`.

**What changes:**
- `server/crates/loseit-db/src/food_repo.rs`:
  - `SELECT_FOOD_COLS` shrinks: remove `energy_kcal_100g, protein_100g, carbs_100g, fat_100g,
    fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g`.
  - `create_custom_with_servings`: transaction wrapping one food INSERT + N serving INSERTs.
  - `update_custom_with_servings`: optional full-list serving replace inside the same txn
    (`DELETE FROM servings WHERE food_id = $1; INSERT ... ` per §5.5).
  - `find_or_create_quick_add`: provisions `{amount: 1, unit: 'serving', kcal: 1.0, source: 'system', is_default: true}`.
  - `upsert_external_food_batch`: per-food UPSERT on food row + atomic serving replace per §7.4.
  - Remove every `*_100g` bind parameter from INSERT / UPDATE.

**Acceptance:**
- `cargo check -p loseit-db` green.

**Files touched:** 1

**Depends on:** T03 (repo traits must exist before Pg impls)

**Design ref:** §6.2 of be_per_serving_nutrition_design.md

---

## T05 — Pg repos: `PgServingRepository` rewrite

**Subject:** Rewrite `PgServingRepository` to carry `amount`, `unit`, and all per-serving
nutrition columns.

**What changes:**
- `server/crates/loseit-db/src/serving_repo.rs`:
  - `SELECT_COLS` expands to include `amount`, `unit`, `kcal`, `protein_g`, `carbs_g`, `fat_g`,
    `fiber_g`, `sugar_g`, `sodium_mg`, `saturated_fat_g`. Drop `grams`.
  - `create` rewrites its INSERT column list and bind parameters against `ServingDraft`.
  - `update` rewrites its UPDATE column list and bind parameters against `ServingPatch`.
  - `set_default` is unchanged (partial unique index mechanics are unchanged).

**Acceptance:**
- `cargo check -p loseit-db` green.

**Files touched:** 1

**Depends on:** T03 (ServingRepository trait), T04 (PgFoodRepository owns the food FK side)

**Design ref:** §6.2 of be_per_serving_nutrition_design.md

---

## T06 — Pg repos: `PgLogRepository` rewrite

**Subject:** Rewrite `PgLogRepository` to drop `grams_total` and add `entered_amount` /
`entered_unit` across all SQL paths.

**What changes:**
- `server/crates/loseit-db/src/log_repo.rs`:
  - Drop `grams_total` from every column list and every UNNEST binding. Per §6.1 this touches
    lines 40, 71, 91–92, 109, 122, 182, 428, 445, 472, 500, 565, 593.
  - Add `entered_amount` (numeric) + `entered_unit` (text) to SELECT, INSERT, UPDATE, and
    `create_many`'s UNNEST arrays. The UNNEST signature: drop one `numeric[]` (grams_total),
    add one `numeric[]` (entered_amount) + one `text[]` (entered_unit).
  - `SELECT_COLS` denormalization JOIN (`food_name`, `serving_name`) stays unchanged from Ask 9.
  - `create_many_sql_has_no_inline_comments` regression test must still pass.

**Acceptance:**
- `cargo check -p loseit-db` green.
- `cargo test -p loseit-db` (if any; the `create_many_sql_has_no_inline_comments` test at minimum).

**Files touched:** 1

**Depends on:** T03 (LogRepository trait)

**Design ref:** §6.1, §6.2 of be_per_serving_nutrition_design.md

---

## T07 — In-memory fakes: `loseit-testing/src/{foods,servings,logs}.rs`

**Subject:** Mirror T04–T06 changes in the in-memory fake repos used by all non-Pg tests.

**What changes:**
- `server/crates/loseit-testing/src/foods.rs`: implement `create_custom_with_servings`,
  `update_custom_with_servings`, `upsert_external_food_batch`. `find_or_create_quick_add`
  provisions `{amount: 1, unit: Serving, kcal: 1.0, source: System, is_default: true}`.
  Drop all `*_100g` field handling.
- `server/crates/loseit-testing/src/servings.rs`: `create` / `update` adapt to new
  `ServingDraft` / `ServingPatch`; `grams` field removed; nutrition fields added.
- `server/crates/loseit-testing/src/logs.rs`: drop `grams_total`; add `entered_amount` +
  `entered_unit` round-trip per §6.3. `set_food_repo_for_sentinel_filter` wiring stays unchanged.
  `resolve_names` helper from Ask 9 stays unchanged.

**Acceptance:**
- `cargo check -p loseit-testing` green.
- `cargo test -p loseit-testing` green (all existing in-memory repo tests pass).

**Files touched:** 3

**Depends on:** T03 (traits), T04–T06 (Pg side must be done so the testing side has a parallel to mirror)

**Design ref:** §6.3 of be_per_serving_nutrition_design.md

---

## T08 — Service layer: `FoodService` + `LogService` rewrite

**Subject:** Rewrite the conversion path in `LogService::create`, add `entered_amount` /
`entered_unit` fields throughout, and remove the synthesized-default-100g-serving from
`FoodService::create_custom`.

**What changes:**
- `server/crates/loseit-core/src/service/log.rs`:
  - `create`: implement §5.1 conversion + validation flow. Cross-family guard → 400
    `Validation("unit_family_mismatch")`. Within-family conversion to derive `quantity`.
    `Count` strict-unit: `piece` against `serving` → same `Validation`. Quantity guard: `q > 0 && q < 10_000`.
    New `compute_snapshot`: `q * s.<nutrient>` — drop all per-100g scaling and the g→mg sodium dance.
  - `quick_add`: implement §5.2 mechanics. `entered_amount = calories_kcal`, `entered_unit = Unit::Serving`.
  - `update`: if `entered_amount`, `entered_unit`, or `serving_id` changes, re-run §5.1 pipeline;
    replace `grams_total` overflow guard with `quantity > 0 && quantity < 10_000` guard.
  - `copy_day`: preserve `entered_amount` + `entered_unit` verbatim; `quantity` preserved across copy.
- `server/crates/loseit-core/src/service/food.rs`:
  - `create_custom` §5.4: validate `servings.len() >= 1`; **do not synthesize a default `100 g`
    serving** — the synthesizer at `service/food.rs:175-184` is deleted. Service calls
    `create_custom_with_servings`. If no serving has `is_default = true`, mark the first.
  - `update_custom` §5.5: full-list serving replace when `servings` patch is present; runs in
    one transaction.
- Add unit tests (in `loseit-core/tests/` or inline) per §8 service layer test spec:
  Volume within-family, Mass within-family, cross-family rejection, Count strict-unit,
  Count exact-unit, quick-add path, empty-servings rejection, multi-default rejection.

**Acceptance:**
- `cargo check --workspace` green — this is the integration point that closes compilation
  across service, repo, and handler layers.
- `cargo test -p loseit-core` passes; new service unit tests pass.

**Files touched:** 2 source + 1–2 test files

**Depends on:** T07 (in-memory fakes must be ready before service tests can run)

**Design ref:** §5.1–§5.5 of be_per_serving_nutrition_design.md

---

## T09 — HTTP handlers: `routes/foods.rs` DTOs + handlers

**Subject:** Update food route DTOs and handlers for the per-serving nutrition wire shape;
drop `NutritionPer100g` from all request/response bodies.

**What changes:**
- `server/crates/loseit-api/src/routes/foods.rs`:
  - `CreateFoodBody`: drop `nutrition` field; add `servings: Vec<ServingBody>` required ≥1
    (service validates; handler passes through).
  - `PatchFoodBody`: same drop + add optional `servings`.
  - Add `ServingBody` with `label?`, `amount`, `unit` (string → `Unit::parse`), `kcal`,
    all optional macro fields, `is_default?`, `sort_order?`.
  - `FoodDetailResponse`: drop `nutrition`; `servings[0]` carries `amount`, `unit`, `kcal`,
    per-nutrient fields. `ServingPreview` / `ServingResponse` updated accordingly.
  - `POST /foods/{food_id}/servings` body shape updates to `ServingBody`.
  - In `PATCH /foods/{id}` OpenAPI prose: document that `servings` full-list replace
    invalidates existing log-entry `serving_id` pointers (log entries retain frozen snapshot
    and denormalized `serving_name`). See §10 R4.

**Acceptance:**
- `cargo check --workspace` green.
- Existing HTTP test files compile (updated call sites in `http_foods.rs`, `http_servings.rs`
  may already fail compilation here — that is acceptable; they are rewritten in T12).

**Files touched:** 1

**Depends on:** T08 (service must compile before handlers call it)

**Design ref:** §4.2, §4.3, §10 R4 of be_per_serving_nutrition_design.md

---

## T10 — HTTP handlers: `routes/log.rs` DTOs + handlers

**Subject:** Update log route DTOs and handlers: drop `quantity` from create/patch wire,
add `entered_amount` + `entered_unit`, drop `grams_total` from response.

**What changes:**
- `server/crates/loseit-api/src/routes/log.rs`:
  - `CreateLogBody`: drop `quantity`; add `entered_amount: Decimal` (required),
    `entered_unit: String` (required, parsed to `Unit` at handler entry).
  - `PatchLogBody`: drop `quantity`; add optional `entered_amount` + `entered_unit`.
  - `LogEntryResponse`: drop `grams_total`; add `entered_amount: Decimal` (required),
    `entered_unit: String` (required); `quantity: Decimal` stays on the wire (FE uses it
    for stepper math).
  - Cross-family rejection: map `ServiceError::Validation("unit_family_mismatch")` to 400
    with `code: "unit_family_mismatch"` in the structured error envelope. Use or add a new
    `ApiError` variant as appropriate — do not invent a new error shape.
  - Lines 146 + 173 (`grams_total` DTO field and mapping) are deleted per §6.1 audit.

**Acceptance:**
- `cargo check --workspace` green.

**Files touched:** 1

**Depends on:** T08 (LogService must compile), T09 (food handler must be done first to avoid
merge conflicts on shared error-mapping code)

**Design ref:** §4.4, §6.1, §10 D5 of be_per_serving_nutrition_design.md

---

## T11 — OpenAPI: `server/specs/openapi.yaml` delta

**Subject:** Apply the full Ask 10 OpenAPI schema delta: new `Unit` enum, reshaped `Serving`
and `ServingCreate`, dropped `NutritionPer100g`, reshaped `LogEntry` / `LogCreate` / `LogPatch`.

**What changes:**
- `server/specs/openapi.yaml`:
  - Delete `NutritionPer100g` schema and all `$ref` sites to it on `FoodDetail` + `FoodCreate`.
  - Add `Unit` enum schema: `{type: string, enum: [g, kg, oz, lb, ml, l, cup, fl_oz, tbsp, tsp, serving, piece]}`.
  - `Serving` schema: drop `grams`; add `amount` (required), `unit` (required → `Unit` ref),
    `kcal` (required), `protein_g` / `carbs_g` / `fat_g` / `fiber_g` / `sugar_g` /
    `sodium_mg` / `saturated_fat_g` (all nullable). `label` becomes nullable. Required list:
    `[id, amount, unit, kcal, is_default, source, sort_order]`.
  - `ServingCreate` + `ServingPatch`: mirror serving shape for request bodies.
  - `FoodDetail`: drop `nutrition`; `servings` required, `minItems: 1`.
  - `FoodCreate`: drop `nutrition`; add `servings: [ServingCreate]` required `minItems: 1`.
  - `FoodPatch`: drop `nutrition`; add optional `servings: [ServingCreate]`.
  - `LogEntry`: drop `grams_total`; add `entered_amount` (required number),
    `entered_unit` (required → `Unit` ref); `quantity` stays (required).
  - `LogCreate`: drop `quantity`; add `entered_amount` (required number), `entered_unit`
    (required → `Unit` ref).
  - `LogPatch`: drop `quantity`; add optional `entered_amount` + `entered_unit`.
  - `Errors` section: document `unit_family_mismatch` error code.

**Acceptance:**
- `cargo check --workspace` still green (spec is doc-only).
- OpenAPI lints clean (run `server/scripts/` lint tooling if present).

**Files touched:** 1

**Depends on:** T10 (wire shape must be stable before spec reflects it — keeps spec and impl
in the same commit window)

**Design ref:** §10c of ask_10_per_serving_nutrition.md; §9 T11 of be_per_serving_nutrition_design.md

---

## T12 — HTTP tests: `loseit-api/tests/http_foods.rs` rewrite

**Subject:** Rewrite the foods HTTP test suite against the per-serving nutrition wire shape.

**What changes:**
- `server/crates/loseit-api/tests/http_foods.rs`:
  - Drop every test that sends or asserts `nutrition_per_100g` on food create/response.
  - Add `servings` round-trip: `POST /foods` with `{name, servings: [{amount: 1, unit: 'cup', kcal: 200}]}`
    → 201, serving echoed with `amount` + `unit` + `kcal`.
  - Add empty-servings rejection: `POST /foods` with `servings: []` → 400.
  - Add kcal-required test: serving missing `kcal` → 400.
  - Add macros-nullable test: serving with only `kcal` → 201 (protein/carbs/fat fields absent or null).
  - Add serving full-list replace: `PATCH /foods/{id}` with new `servings` list → 200,
    log entry `serving_id` becomes null, snapshot preserved.
  - Update any `AppState::from_ports` call sites affected by signature drift.

**Acceptance:**
- `cargo test -p loseit-api --test http_foods` passes (all cases).

**Files touched:** 1

**Depends on:** T09, T11

**Design ref:** §8 (HTTP layer) of be_per_serving_nutrition_design.md

---

## T13 — HTTP tests: `loseit-api/tests/http_log.rs` rewrite

**Subject:** Rewrite the log HTTP test suite: drop all `grams_total` assertions; add
`entered_amount` / `entered_unit` round-trips; add cross-family 400 and within-family
volume conversion test.

**What changes:**
- `server/crates/loseit-api/tests/http_log.rs`:
  - Delete all 14 `grams_total` assertion sites per the §6.1 audit.
  - Add `entered_amount` + `entered_unit` round-trip: create entry, `GET /log`, assert fields present.
  - Add cross-family 400: `POST /log` with `entered_unit='g'` against a volumetric serving
    → 400 `code: "unit_family_mismatch"`.
  - Add within-family Volume conversion: `POST /log` with `entered_amount=4, entered_unit='fl_oz'`
    against a `{1, cup, 200 kcal}` serving → 201, `quantity ≈ 0.5`, `calories_kcal = 100`.
    Pin `quantity` to `0.169` precision as described in §10 R2: `round(4 * 29.5735… / 236.5882…, 3)`.
  - Add `Count` cross-unit 400: `entered_unit='piece'` against `{1, serving}` → 400 `unit_family_mismatch`.
  - Add quick-add returns `entered_unit = "serving"`: `POST /log/quick_add` → response has
    `entered_amount = <kcal>`, `entered_unit = "serving"`.
  - Add R3 regression: PATCH `serving_id` to a Mass serving without updating `entered_unit`
    (still Volume) → 400 `unit_family_mismatch`.
  - `GET /log?from=…&to=…` results: assert `entered_amount` + `entered_unit` present; assert
    `grams_total` absent.

**Acceptance:**
- `cargo test -p loseit-api --test http_log` passes (all cases).

**Files touched:** 1

**Depends on:** T10, T11

**Design ref:** §8 (HTTP layer), §10 R2, R3 of be_per_serving_nutrition_design.md

---

## T14 — Ingest core: new `OffSource` / `UsdaSource` normalizers

**Subject:** Rewrite `loseit-core::service::ingest` normalizers to emit `FoodDraftWithServings`
directly; implement OFF serving_size parser and USDA portion mapper per §7.

**What changes:**
- `server/crates/loseit-core/src/service/ingest.rs`:
  - Rename `FoodRecordSource` to `OffSource`; add `UsdaSource` trait (each emits source-specific records).
  - Add `accept_and_normalize_off(record) -> Option<FoodDraftWithServings>` implementing
    §7.1 rules: parse `serving_size` via the 12-unit pattern table; emit `{amount, unit}`
    serving + companion `{100, g}` when OFF provides per-100g data; drop rows with no
    recoverable nutrition.
    Sodium: multiply OFF `sodium_g_100g` by 1000 for `serving.sodium_mg`; run
    `SODIUM_GRAMS_SANITY_THRESHOLD = 50.0` check before conversion (still g/100g space).
  - Add `accept_and_normalize_usda(record) -> Option<FoodDraftWithServings>` implementing
    §7.2 rules: iterate `foodPortions[]`, map `measureUnit.name` to `Unit` (fallback to
    `{gramWeight, Gram}`), compute `nutrient_per_100g * gramWeight / 100`.
  - Delete `materialize_servings` (§7.4 says it's gone).
  - Delete `OffFoodUpsert` (replaced by `FoodDraftWithServings`).
  - Add unit tests on normalizers with fixture rows per §8 ingest test spec: `"30 g"` → `Gram`;
    `"1 cup (240 ml)"` → `{1, Cup}`; pure-volume row with per-100g-only → dropped;
    per-100g present → both `{amount, unit}` + `{100, g}` emitted; USDA `"tablespoon"` → `Tablespoon`;
    USDA unmapped → `{gramWeight, g}` fallback; sodium > 50 g/100g nulls field, not row.

**Acceptance:**
- `cargo check -p loseit-core` green.
- `cargo test -p loseit-core` passes (normalizer unit tests).

**Files touched:** 1

**Depends on:** T02 (domain types and `FoodDraftWithServings` from T03)

**Design ref:** §7.1–§7.4 of be_per_serving_nutrition_design.md

---

## T15 — Ingest binary: `loseit-ingest` sources adapt to new record shape

**Subject:** Update `loseit-ingest::JsonlSource` and `ParquetSource` to expose the raw
serving fields the new normalizer consumes; wire up `run_off` / `run_usda` in the binary.

**What changes:**
- `server/crates/loseit-ingest/src/` (JsonlSource, ParquetSource files):
  - `OffRaw` struct: keep `serving_size`, per-100g, and per-serving nutrition fields from OFF.
    `into_record` exposes all fields required by `accept_and_normalize_off`.
  - `ParquetSource`: update column projections to match. No schema rename — OFF/USDA source
    files don't change shape.
  - Binary entrypoint: wire `IngestService::run_off` / `run_usda` to the two sources.
    `--limit` smoke harness exercises `upsert_external_food_batch` against the new Pg repo
    (requires a live DB at integration-test time; skip in CI if no DB present).

**Acceptance:**
- `cargo check -p loseit-ingest` green.
- Binary compiles and `--limit 1` runs without panic against a populated Pg DB (manual smoke
  check; not gated in CI).

**Files touched:** 2–3

**Depends on:** T14 (normalizer traits), T04 (`upsert_external_food_batch` on PgFoodRepository)

**Design ref:** §7.4 of be_per_serving_nutrition_design.md

---

## T16 — Ingest tests + workspace test-count gate

**Subject:** Add fixture-based integration tests for the OFF + USDA normalizers; run
`cargo test --workspace` and assert the count is ≥ 245.

**What changes:**
- `server/crates/loseit-ingest/tests/` (or `loseit-core/tests/ingest_normalizer.rs`):
  - OFF normalizer fixtures (see §8 ingest layer):
    - `"30 g"` → single `{30, Gram}` serving, `is_default = true`.
    - `"1 cup (240 ml)"` → `{1, Cup}` serving `is_default = true` + `{100, Gram}` companion.
    - Pure-volume serving with no OFF per-serving nutrition → row dropped.
    - Per-100g nutrition present + no `serving_size` → single `{100, Gram}` serving only.
  - USDA normalizer fixtures:
    - `foodPortions` with `measureUnit.name = "tablespoon"` → `Tablespoon` serving.
    - Unmapped measureUnit → fallback `{gramWeight, Gram}` serving.
    - Empty `foodPortions` + no `energy-kcal` nutrient → food dropped.
  - Sodium sanity: OFF row with `sodium_g_100g > 50` → `serving.sodium_mg = null`; food not dropped.
- Final check: `cargo test --workspace` passes; assert total count ≥ 245. If count is below
  target, add missing unit tests to the failing layer before closing the task.

**Acceptance:**
- `cargo test --workspace` passes.
- Total passing test count ≥ 245 (D8).

**Files touched:** 1–2 test files

**Depends on:** T14, T15

**Design ref:** §8 (ingest layer), §2 D8 of be_per_serving_nutrition_design.md

---

## Notes for engineers

**T01 gates everything.** The migration file defines the schema contract for all subsequent
layers. No engineer should start T02 until T01 is merged and the dev Postgres has been
reset. See §10 R1 for the `_sqlx_migrations` runbook — this is the single highest-risk
deploy step. On local dev: drop and recreate the database before running the server.

**T02 breaks the workspace deliberately.** After T02 merges, `cargo check --workspace` will
fail across `loseit-db`, `loseit-testing`, `loseit-api`, and `loseit-ingest`. This is
expected. T03–T08 repair each layer in order. The golden rule: each task from T03 onward
should leave its own crate green (`cargo check -p <crate>`) even if the full workspace
isn't green until T08.

**T08 is the workspace integration point.** T08 is the first task where `cargo check
--workspace` must pass again. Engineers working T03–T07 should coordinate so that T08
is not started until all of T03–T07 are merged.

**Synthesized default `100 g` serving is gone — confirmed.** The architect flagged the open
question in the design doc. The user directive is "stop anchoring nutrition to per-100g
mass." The synthesizer at `service/food.rs:175-184` is deleted in T08. Client must supply
≥ 1 serving in `POST /foods`. No re-ask needed.

**Decimal rounding in T08 (R2).** The `quantity` multiplier is `NUMERIC(8,3)` — rounded to 3
decimal places before storage. The snapshot uses the **rounded** `q`, not the exact rational.
Add a test pinning: `entered_amount=200g` against `{1, lb, 300 kcal}` serving →
`quantity = 0.441`, `calories_kcal = round(0.441 * 300, 2) = 132.30`. This pins the R2
invariant.

**R3 regression must be in T13.** If a user PATCHes `serving_id` from a Volume serving to a
Mass serving without patching `entered_unit`, the existing Volume `entered_unit` will fail
cross-family validation. T08's update path must validate the post-patch `(entered_unit,
serving.unit)` pair. T13 adds the regression test. Do not skip.

**T14–T16 are the ingest tail.** They are sequenced after T13 in this tracker (single-commit-
per-task discipline). However, they are logically independent of T09–T13 once T01 and T02 are
merged — if two engineers are available, T14 can start after T03 (domain types + trait) is
done, in parallel with the API/handler work.

**FE handoff trigger (R7 + notify clause in ask).** The FE reshape starts when T11 (OpenAPI
spec) lands on main. Once T09 + T10 + T11 are merged and deployed, flip status in
`ask_10_per_serving_nutrition.md` and add a `Backend reply:` paragraph. The FE has ~3–5 days
of rewrites; do not merge T11 to main until T12 + T13 are also passing.

**`rust_decimal_macros` workspace dep (R6).** The `dec!()` macro in `unit.rs` (T02) requires
`rust_decimal_macros` as a dependency. Check `server/Cargo.toml` `[workspace.dependencies]`;
add it in T02 if missing.

**`upsert_external_food_batch` replaces servings on re-import (R5).** Every re-import of an
OFF/USDA food atomically replaces its servings. Log entries whose `serving_id` points to
a replaced serving get `serving_id = NULL` (FK → `SET NULL`). The snapshot survives; the
pointer is lost. This is acceptable v1 ingest behavior — document in the ingest binary's
`--help` text.

**Final verification commands:**

```bash
export PATH="$HOME/.cargo/bin:$PATH"
cargo check --manifest-path /workplace/fulfilled/server/Cargo.toml --workspace
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-core
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-testing
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-api --test http_foods
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-api --test http_log
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            --workspace   # must report ≥ 245 passing
```
