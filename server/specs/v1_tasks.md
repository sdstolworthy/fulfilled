# v1 Task List

Derived from the architect's v1 plan (`NEXT_STEPS.md` Priority 1 items 1–7).
Each task is sized for a single developer agent in one ~30–60 min session.
"Owner agent profile" is a hint for which kind of agent to dispatch.

**Lead decisions already baked in (do not re-litigate):**
- Sodium: stored per-100g in grams (per OFF). `LogService::compute_snapshot`
  converts grams → mg when filling the `sodium_mg` snapshot column. Ingest
  logs a `tracing::warn!` if `sodium_100g > 50` (i.e. someone uploaded mg by
  mistake).
- New migration `migrations/0002_search_support.sql` is allowed.
  `0001_initial.sql` is frozen.
- Resumability for ingest is chunk-boundary granular. Upserts are
  idempotent; no sidecar progress file.
- Search total: separate `count(*)` query. Defer "more than N" UX.
- Search visibility: viewer sees all `source='off'` foods **plus** their
  own `source='user'` customs.
- Adding servings to OFF foods: reject with a 409/`conflict` carrying the
  message `"OFF foods are read-only; clone as a custom food to add servings"`.
- "Frequent" window: hardcoded 30 days, defined as
  `const FREQUENT_WINDOW_DAYS: i64 = 30;` in `LogService`.

**Workspace conventions enforced in every task:**
- Repo traits in `loseit-core/src/repo/`, `#[async_trait]`.
- Concrete sqlx repos in `loseit-db/src/`. Use **function-style**
  `sqlx::query_as::<_, Row>("…")` — never `query!` macros. No compile-time
  DB. Match the patterns in `user_repo.rs` and `weight_repo.rs`.
- Services in `loseit-core/src/service/`, hold `Arc<dyn Repo>`, return
  `CoreResult<T>`.
- Routes in `loseit-api/src/routes/`, return `Result<Json<T>, ApiError>`.
- Composition root updates in `loseit-api/src/server.rs`
  (`AppState::from_ports` + `build_state` + `router`).
- For each new repo trait, add an `InMemoryXxxRepository` in
  `loseit-testing/`. The fake is the test seam.
- TDD: every task lands tests in the same PR. Service tests against
  in-memory fakes; HTTP tests in `crates/loseit-api/tests/http.rs` using the
  real router with fakes wired in.
- sqlx integration tests against a real Postgres are **out of scope for v1**.
  Flag any such gaps as "later".

---

## Phase 0 — Foundational (one agent, serial)

> Single PR. Must land before any Wave starts. Pure type/trait
> scaffolding — no logic, no SQL, no handlers. Compiles + `cargo check`
> green at the end. Stubs return `unimplemented!()` or `todo!()` so the
> tree still type-checks downstream.

### T01 — Add `Food`, `Serving`, `Meal`, `FoodLogEntry`, `DaySummary` domain types

- **Phase:** Foundational
- **Depends on:** —
- **Owner agent profile:** core-domain dev
- **Files to create / modify:**
  - Create `crates/loseit-core/src/domain/food.rs`
    - `pub enum FoodSource { Off, User }` with `as_str` / `parse`.
    - `pub enum NutriscoreGrade { A, B, C, D, E }` with `as_str` / `parse`.
    - `pub struct NutritionPer100g { energy_kcal, protein_g, carbs_g, fat_g,
      fiber_g, sugar_g, sodium_g, saturated_fat_g }` — all
      `Option<Decimal>` except `energy_kcal: Decimal` (search filter
      requires it).
    - `pub struct Food { id, source, owner_user_id, barcode, name, brands,
      categories_tags, nutrition, nutriscore_grade, quality_score,
      last_import_batch_id, created_at, updated_at }`.
    - `pub struct FoodDraft { name, brands, barcode, categories_tags,
      nutrition, nutriscore_grade }` (for user customs only).
    - `pub struct FoodPatch { name, brands, barcode, categories_tags,
      nutrition fields (each Option<Option<Decimal>>-style or a nested
      patch struct — pick whichever the existing `GoalPatch` style uses),
      nutriscore_grade }`.
    - `pub struct FoodSearchHit { id, source, name, brand, barcode,
      default_serving: Option<ServingPreview>, calories_per_serving:
      Option<Decimal> }` and `pub struct ServingPreview { id, label,
      grams }`.
  - Create `crates/loseit-core/src/domain/serving.rs`
    - `pub enum ServingSource { Off, User, System }`.
    - `pub struct Serving { id, food_id, label, grams, is_default, source,
      sort_order, created_at, updated_at }`.
    - `pub struct ServingDraft { label, grams, is_default, source,
      sort_order }`.
    - `pub struct ServingPatch { label: Option<String>, grams:
      Option<Decimal>, sort_order: Option<i32> }` (no `is_default` —
      flipping default is its own repo method, not a generic patch).
  - Create `crates/loseit-core/src/domain/meal.rs`
    - `pub enum Meal { Breakfast, Lunch, Dinner, Snack }` with
      `as_str`, `FromStr`, `Display`.
  - Create `crates/loseit-core/src/domain/log_entry.rs`
    - `pub struct NutritionSnapshot { calories_kcal: Decimal, protein_g:
      Option<Decimal>, carbs_g, fat_g, fiber_g, sugar_g,
      sodium_mg: Option<Decimal>, saturated_fat_g }`.
    - `pub struct FoodLogEntry { id, user_id, food_id, serving_id:
      Option<Uuid>, consumed_on: NaiveDate, meal: Meal, quantity: Decimal,
      grams_total: Decimal, snapshot: NutritionSnapshot, note,
      created_at, updated_at }`.
    - `pub struct LogDraft { food_id, serving_id, consumed_on, meal,
      quantity, note }` — the *handler-facing* draft. No `grams_total` or
      snapshot; service fills those in.
    - `pub struct LogPatch { serving_id: Option<Uuid>, consumed_on:
      Option<NaiveDate>, meal: Option<Meal>, quantity: Option<Decimal>,
      note: Option<Option<String>> }`.
    - `pub struct PersistedLogEntry` and `pub struct PersistedLogPatch` —
      the *repo-facing* shapes that already contain `grams_total` +
      snapshot. Service computes these from `LogDraft`/`LogPatch` and
      passes them to the repo.
  - Create `crates/loseit-core/src/domain/day_summary.rs`
    - `pub struct MealSubtotal { meal: Meal, calories_kcal, protein_g,
      carbs_g, fat_g, entry_count }`.
    - `pub struct DaySummary { date: NaiveDate, total: NutritionSnapshot,
      by_meal: Vec<MealSubtotal>, active_goal: Option<Goal> }`.
  - Modify `crates/loseit-core/src/domain/mod.rs` — add `pub mod` lines and
    re-exports for every new type.
- **Acceptance:**
  - `cargo check -p loseit-core` is clean.
  - Unit tests:
    - `test_meal_from_str_round_trip` — `Meal::Breakfast.to_string() ==
      "breakfast"` and `"breakfast".parse::<Meal>().unwrap() ==
      Meal::Breakfast`; invalid string returns `Err`.
    - `test_food_source_parse_rejects_unknown` — `FoodSource::parse("foo")
      == None`.
    - `test_nutriscore_grade_round_trip`.
- **Out of scope:**
  - Any repo trait method bodies, services, SQL, or handlers.
  - JSON serialization derives (wire DTOs live in the API crate).

### T02 — Add `FoodRepository`, `ServingRepository`, `LogRepository`, `BatchRepository` traits (stubs)

- **Phase:** Foundational
- **Depends on:** T01
- **Owner agent profile:** core-domain dev
- **Files to create / modify:**
  - Create `crates/loseit-core/src/repo/food.rs`
    - `#[async_trait] pub trait FoodRepository: Send + Sync + 'static`
      with method signatures only (no bodies; trait has no default impls):
      - `find_by_id(&self, viewer: Uuid, id: Uuid) -> CoreResult<Option<Food>>`
      - `find_by_barcode(&self, viewer: Uuid, barcode: &str) -> CoreResult<Option<Food>>`
      - `search(&self, viewer: Uuid, q: &str, limit: i64, offset: i64) -> CoreResult<Vec<FoodSearchHit>>`
      - `search_count(&self, viewer: Uuid, q: &str) -> CoreResult<i64>`
      - `create_custom(&self, owner: Uuid, draft: &FoodDraft) -> CoreResult<Food>`
      - `update_custom(&self, owner: Uuid, id: Uuid, patch: &FoodPatch) -> CoreResult<Food>`
      - `delete_custom(&self, owner: Uuid, id: Uuid) -> CoreResult<()>`
      - `upsert_off_batch(&self, batch_id: Uuid, records: &[FoodDraft /* or OffFoodRecord */]) -> CoreResult<UpsertStats>` — see T03 for the record shape.
    - Add a `pub struct UpsertStats { inserted: u64, updated: u64,
      skipped: u64 }`.
  - Create `crates/loseit-core/src/repo/serving.rs`
    - `#[async_trait] pub trait ServingRepository`:
      - `list_for_food(&self, food_id: Uuid) -> CoreResult<Vec<Serving>>`
      - `create(&self, food_id: Uuid, draft: &ServingDraft) -> CoreResult<Serving>`
      - `update(&self, id: Uuid, patch: &ServingPatch) -> CoreResult<Serving>`
      - `set_default(&self, food_id: Uuid, serving_id: Uuid) -> CoreResult<()>` (atomic — unsets others)
      - `delete(&self, id: Uuid) -> CoreResult<()>` (must reject if `is_default`)
      - `find_by_id(&self, id: Uuid) -> CoreResult<Option<Serving>>`
  - Create `crates/loseit-core/src/repo/log.rs`
    - `#[async_trait] pub trait LogRepository`:
      - `create(&self, user_id: Uuid, entry: &PersistedLogEntry /* sans id */) -> CoreResult<FoodLogEntry>`
      - `update(&self, user_id: Uuid, id: Uuid, patch: &PersistedLogPatch) -> CoreResult<FoodLogEntry>`
      - `delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()>`
      - `list_in_range(&self, user_id: Uuid, from: NaiveDate, to: NaiveDate) -> CoreResult<Vec<FoodLogEntry>>`
      - `list_for_day(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Vec<FoodLogEntry>>`
      - `recent_food_ids(&self, user_id: Uuid, limit: i64) -> CoreResult<Vec<Uuid>>` — distinct `food_id` ordered by max `created_at` desc.
      - `frequent_food_ids(&self, user_id: Uuid, window_days: i64, limit: i64) -> CoreResult<Vec<(Uuid, i64)>>` — `food_id` + count, ordered by count desc.
  - Create `crates/loseit-core/src/repo/batch.rs`
    - `#[async_trait] pub trait BatchRepository`:
      - `start(&self, source_url: &str, source_etag: Option<&str>) -> CoreResult<FoodImportBatch>`
      - `finish(&self, id: Uuid, stats: UpsertStats) -> CoreResult<()>`
      - `fail(&self, id: Uuid, error: &str) -> CoreResult<()>`
      - `bump_counts(&self, id: Uuid, seen: u64, upserted: u64, skipped: u64) -> CoreResult<()>`
    - Add a `pub struct FoodImportBatch { id, started_at, completed_at,
      source_url, source_etag, records_seen, records_upserted,
      records_skipped, status, error }` in
      `loseit-core/src/domain/food_import_batch.rs` and a `BatchStatus`
      enum.
  - Modify `crates/loseit-core/src/repo/mod.rs` — add `pub mod` + re-exports.
- **Acceptance:**
  - `cargo check --workspace` is clean (downstream crates may have
    `unimplemented!()` stubs but must compile).
  - No tests yet — traits have no bodies.
- **Out of scope:**
  - Any concrete repo impl.
  - The `OffFoodRecord` *parsed* shape — that lives in `loseit-ingest`
    (Phase 1 ingest task). The trait takes `FoodDraft` for now; if the
    ingest task wants a richer record shape, it adds it to `loseit-core`
    in its own PR.

### T03 — Stub `FoodService`, `ServingService`, `LogService`, `IngestService`

- **Phase:** Foundational
- **Depends on:** T02
- **Owner agent profile:** core-domain dev
- **Files to create / modify:**
  - Create `crates/loseit-core/src/service/food.rs` —
    `pub struct FoodService { foods: Arc<dyn FoodRepository>, servings:
    Arc<dyn ServingRepository> }`. Public method *signatures* only,
    bodies `todo!()`.
  - Create `crates/loseit-core/src/service/serving.rs` —
    `pub struct ServingService { servings: Arc<dyn ServingRepository>,
    foods: Arc<dyn FoodRepository> }`. Method stubs.
  - Create `crates/loseit-core/src/service/log.rs` — `pub struct LogService
    { logs: Arc<dyn LogRepository>, foods: Arc<dyn FoodRepository>,
    servings: Arc<dyn ServingRepository>, goals: Arc<dyn GoalRepository>
    }`. Method stubs **plus** the `compute_snapshot` private helper
    signature documented:
    `fn compute_snapshot(food: &Food, grams_total: Decimal) ->
    NutritionSnapshot` — task T13 fills it in.
  - Create `crates/loseit-core/src/service/ingest.rs` — `pub struct
    IngestService { foods: Arc<dyn FoodRepository>, batches: Arc<dyn
    BatchRepository> }`. One stub method:
    `run<S: FoodRecordSource>(&self, source: S, source_url: &str,
    source_etag: Option<&str>) -> CoreResult<UpsertStats>`. Define
    `pub trait FoodRecordSource` here (or in a sibling module) with
    `async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<
    OffFoodRecord>>>` and define `pub struct OffFoodRecord` here — the
    rich parsed shape (`code`, `product_name`, `brands`,
    `categories_tags`, `nutriscore_grade_raw`, all per-100g nutrient
    fields, `serving_size`, `serving_quantity`, `completeness`).
  - Modify `crates/loseit-core/src/service/mod.rs` — add `pub mod` +
    re-exports.
- **Acceptance:**
  - `cargo check --workspace` clean.
  - No tests yet.
- **Out of scope:**
  - Concrete ingest source readers (`JsonlSource`, `ParquetSource`) live
    in the `loseit-ingest` binary, not here.
  - `compute_snapshot` body — T13.

---

## Phase 1 — Storage + service ports (parallel)

> All tasks here are independent of each other and depend only on Phase 0.
> They can run as a swarm. Each task lands the in-memory fake **in the
> same PR** as the trait method body it implements, so service-level tests
> have a seam from day one.

### T04 — Implement `InMemoryFoodRepository` + `InMemoryServingRepository` + `InMemoryLogRepository` + `InMemoryBatchRepository` fakes

- **Phase:** Wave 1 (parallel)
- **Depends on:** T01, T02
- **Owner agent profile:** core-domain dev (testing seam specialist)
- **Files to create / modify:**
  - Create `crates/loseit-testing/src/foods.rs`,
    `crates/loseit-testing/src/servings.rs`,
    `crates/loseit-testing/src/logs.rs`,
    `crates/loseit-testing/src/batches.rs`.
  - Each is `Mutex<HashMap<Uuid, _>>` style, mirroring
    `InMemoryWeightRepository`.
  - `InMemoryServingRepository::set_default` must be atomic *under the
    crate's `Mutex`*: collect candidates, flip them, commit in one
    critical section.
  - `InMemoryFoodRepository::search` does case-insensitive substring on
    `name`+`brands`, ranks by length-of-match descending then
    quality_score descending — enough to exercise pagination tests. It
    is NOT the production ranker.
  - `InMemoryFoodRepository::find_by_id` enforces the visibility rule:
    rows with `source=Off` are visible to everyone; rows with `source=User`
    are visible only to `owner_user_id == viewer`. Return `None` (so the
    handler maps it to 404) when the viewer cannot see a private custom.
  - `InMemoryLogRepository::frequent_food_ids` filters entries with
    `consumed_on >= today - window_days` (use the *most recent
    consumed_on in the store* as the "today" anchor in tests — keeps the
    fake deterministic without time injection).
  - Modify `crates/loseit-testing/src/lib.rs` — re-export the four new
    fakes.
- **Acceptance:**
  - `cargo test -p loseit-testing` is clean. Add direct unit tests on
    the fakes:
    - `test_in_memory_food_repo_hides_other_users_customs`.
    - `test_in_memory_serving_repo_set_default_is_atomic` — spawn 8
      concurrent `set_default` calls against different servings of the
      same food, assert exactly one ends up flagged.
    - `test_in_memory_log_repo_frequent_counts_recent_window`.
- **Out of scope:**
  - Postgres-backed repos (separate tasks).

### T05 — Implement `PgFoodRepository` (read paths + upsert batch)

- **Phase:** Wave 1 (parallel)
- **Depends on:** T01, T02
- **Owner agent profile:** sqlx dev
- **Files to create / modify:**
  - Create `crates/loseit-db/src/food_repo.rs`. Define a `FoodRow` with
    `#[derive(sqlx::FromRow)]` mirroring the `foods` table; `From<FoodRow>
    for Food` adapter.
  - Implement `find_by_id`, `find_by_barcode`, `create_custom`,
    `update_custom`, `delete_custom`, `upsert_off_batch`,
    `search`, `search_count`.
  - `upsert_off_batch`: single `INSERT … SELECT … FROM UNNEST($1::text[],
    $2::text[], …) ON CONFLICT (barcode) DO UPDATE …` per chunk. Bind
    all per-column arrays separately. Stamp `last_import_batch_id =
    $batch_id`.
  - `search` SQL: see T11 for the full statement — this task ships the
    *trivial* fallback (name ILIKE ranked by quality_score) so it
    compiles. T11 swaps the SQL in once the migration lands.
  - `delete_custom` returns `CoreError::Conflict("food is referenced by
    log entries")` when the FK-restrict on `food_log_entries.food_id`
    fires (map by `sqlx::Error::Database` with code `'23503'`).
  - `update_custom` and `delete_custom` enforce owner-only at the SQL
    layer (`WHERE id = $1 AND owner_user_id = $2`).
  - Modify `crates/loseit-db/src/lib.rs` — `mod food_repo; pub use
    food_repo::PgFoodRepository;`.
- **Acceptance:**
  - `cargo check -p loseit-db` clean.
  - No real-Postgres tests (out of scope for v1).
  - Code review must verify: every query uses `sqlx::query_as::<_,
    Row>("…")` or `sqlx::query("…")` — no `query!`, no `query_as!`,
    no `query_file!`.
- **Out of scope:**
  - The production search SQL — see T11.
  - Real Postgres tests.

### T06 — Implement `PgServingRepository`

- **Phase:** Wave 1 (parallel)
- **Depends on:** T01, T02
- **Owner agent profile:** sqlx dev
- **Files to create / modify:**
  - Create `crates/loseit-db/src/serving_repo.rs`. `ServingRow` +
    `From<ServingRow> for Serving`.
  - Implement `list_for_food`, `create`, `update`, `set_default`,
    `delete`, `find_by_id`.
  - `set_default`: single transaction —
    ```
    BEGIN;
      UPDATE servings SET is_default = false
        WHERE food_id = $1 AND is_default;
      UPDATE servings SET is_default = true
        WHERE id = $2 AND food_id = $1;
    COMMIT;
    ```
    Use `self.pool.begin().await?` and commit on success.
  - `delete`: refuse with `CoreError::Conflict("cannot delete the default
    serving")` if `is_default` is true on the target row. Do this with a
    single `DELETE … WHERE id = $1 AND is_default = false RETURNING id`
    and treat `rows_affected = 0` as the conflict (after a separate
    existence check, otherwise it's a 404).
  - Modify `crates/loseit-db/src/lib.rs` — register the module.
- **Acceptance:**
  - `cargo check -p loseit-db` clean.
- **Out of scope:**
  - Real Postgres tests.
  - "Reject when food is owned by another user" — that check lives in
    `ServingService`, not the repo (T16).

### T07 — Implement `PgLogRepository`

- **Phase:** Wave 1 (parallel)
- **Depends on:** T01, T02
- **Owner agent profile:** sqlx dev
- **Files to create / modify:**
  - Create `crates/loseit-db/src/log_repo.rs`. `LogEntryRow` +
    `From<LogEntryRow> for FoodLogEntry` (assembling the
    `NutritionSnapshot` substructure from the flat columns).
  - Implement `create`, `update`, `delete`, `list_in_range`,
    `list_for_day`, `recent_food_ids`, `frequent_food_ids`.
  - `recent_food_ids`:
    ```sql
    SELECT food_id, MAX(created_at) AS last_seen
      FROM food_log_entries
     WHERE user_id = $1
     GROUP BY food_id
     ORDER BY last_seen DESC
     LIMIT $2
    ```
    Return just the food_ids; the service hydrates via
    `FoodRepository::find_by_id` (in batch — see T17).
  - `frequent_food_ids`:
    ```sql
    SELECT food_id, COUNT(*) AS cnt
      FROM food_log_entries
     WHERE user_id = $1 AND consumed_on >= $2
     GROUP BY food_id
     ORDER BY cnt DESC
     LIMIT $3
    ```
    where `$2 = today - window_days` is computed by the service.
  - Modify `crates/loseit-db/src/lib.rs` — register the module.
- **Acceptance:**
  - `cargo check -p loseit-db` clean.
- **Out of scope:**
  - Real Postgres tests.

### T08 — Implement `PgBatchRepository` + migration `0002_search_support.sql`

- **Phase:** Wave 1 (parallel)
- **Depends on:** T01, T02
- **Owner agent profile:** sqlx dev
- **Files to create / modify:**
  - Create `crates/loseit-db/src/batch_repo.rs`. Implement `start`,
    `finish`, `fail`, `bump_counts`. `start` returns the row with
    `status = 'running'`. `bump_counts` does `UPDATE … SET records_seen =
    records_seen + $2, records_upserted = records_upserted + $3,
    records_skipped = records_skipped + $4`.
  - Create `migrations/0002_search_support.sql`:
    ```sql
    -- Trigram index on brands (the existing 0001 only indexed name).
    -- Search ranks brand+name together, so brand-only typo queries need
    -- a trigram index on brands too.
    CREATE INDEX IF NOT EXISTS foods_brands_trgm_idx
        ON foods USING gin (coalesce(brands, '') gin_trgm_ops);
    ```
  - Modify `crates/loseit-db/src/lib.rs` — register `batch_repo`.
- **Acceptance:**
  - `cargo check -p loseit-db` clean.
  - The new migration applies cleanly on a database that has already
    applied `0001_initial.sql` (manual sanity by the reviewer; no
    automated test in v1).
- **Out of scope:**
  - Anything that *uses* the brands trigram index — that's T11.

---

## Phase 2 — Routes + read paths (parallel)

> Depends on Phase 1's `FoodRepository::find_by_id/find_by_barcode/search`
> and `ServingRepository::list_for_food`. All Phase 2 tasks can run
> together.

### T09 — Wire `FoodService` + `ServingService` + composition root

- **Phase:** Wave 2 (parallel)
- **Depends on:** T03, T04, T05, T06
- **Owner agent profile:** core-domain dev
- **Files to create / modify:**
  - Fill in `crates/loseit-core/src/service/food.rs`:
    - `pub async fn detail(&self, viewer: Uuid, id: Uuid) ->
      CoreResult<(Food, Vec<Serving>)>` — calls `foods.find_by_id` then
      `servings.list_for_food`; returns `CoreError::NotFound` if food
      is None.
    - `pub async fn by_barcode(&self, viewer: Uuid, barcode: &str) ->
      CoreResult<(Food, Vec<Serving>)>` — same shape.
  - Fill in `crates/loseit-core/src/service/serving.rs` stubs that this
    phase needs (just `list_for_food` passthrough; create/update/delete
    are deferred to T16).
  - Modify `crates/loseit-api/src/server.rs`:
    - Add `pub foods: Arc<FoodService>, pub servings: Arc<ServingService>,
      pub logs: Arc<LogService>` to `AppState`. (Add `logs` now even
      though Phase 4 fills it in — keeps follow-up PRs from re-touching
      the composition root.)
    - Add corresponding repo trait objects to `AppState::from_ports`
      parameters: `foods: Arc<dyn FoodRepository>, servings: Arc<dyn
      ServingRepository>, logs: Arc<dyn LogRepository>, batches:
      Arc<dyn BatchRepository>`.
    - `build_state` builds `PgFoodRepository`, `PgServingRepository`,
      `PgLogRepository`, `PgBatchRepository` and passes them in.
  - Update the existing HTTP test setup `crates/loseit-api/tests/http.rs`
    (`build_test_app`) to wire the new fakes.
- **Acceptance:**
  - `cargo build --workspace` is clean.
  - Existing `http.rs` tests still pass.
  - Service unit tests in `crates/loseit-core/src/service/food.rs`:
    - `test_food_service_detail_hydrates_servings`.
    - `test_food_service_detail_returns_not_found_for_unknown_id`.
    - `test_food_service_detail_hides_other_users_custom`.
- **Out of scope:**
  - Search ranking SQL (T11).
  - Custom-food write paths (T15) and serving CRUD (T16).
  - Log/day-summary handlers.

### T10 — Add `GET /foods/{id}` and `GET /foods/barcode/{barcode}` handlers

- **Phase:** Wave 2 (parallel)
- **Depends on:** T09
- **Owner agent profile:** axum dev
- **Files to create / modify:**
  - Create `crates/loseit-api/src/routes/foods.rs`:
    - Wire `pub fn router() -> Router<AppState>` with
      `/foods/:id` and `/foods/barcode/:barcode` (both GET only in this
      task; search is added in T11, writes in T15, recent/frequent in T17).
    - Response DTOs: `FoodDetailResponse { id, source, owner_user_id?,
      barcode, name, brands, nutrition: NutritionResponse, nutriscore,
      quality_score, servings: Vec<ServingResponse> }` and
      `ServingResponse { id, label, grams, is_default, source,
      sort_order }`.
  - Modify `crates/loseit-api/src/routes/mod.rs` — `pub mod foods;`.
  - Modify `crates/loseit-api/src/server.rs` — merge `routes::foods::
    router()` into the `authed` router.
- **Acceptance:**
  - `cargo test -p loseit-api` clean.
  - HTTP tests in `crates/loseit-api/tests/http.rs`:
    - `test_get_food_by_id_returns_detail_with_servings`.
    - `test_get_food_by_id_404_for_unknown`.
    - `test_get_food_by_id_404_when_custom_owned_by_other_user`.
    - `test_get_food_by_barcode_returns_off_food`.
    - `test_get_food_by_barcode_404_for_missing`.
- **Out of scope:**
  - Search endpoint.
  - Writes.

### T11 — Implement production food search SQL + `GET /foods/search`

- **Phase:** Wave 2 (parallel)
- **Depends on:** T05, T08, T09
- **Owner agent profile:** sqlx dev (with axum dev assist for the handler)
- **Files to create / modify:**
  - Replace the stub `PgFoodRepository::search` with the real query
    (paraphrased; the implementer should consult the architect's plan):
    ```sql
    WITH scored AS (
      SELECT
        f.id, f.source, f.name, f.brands, f.barcode, f.quality_score,
        f.energy_kcal_100g,
        similarity(f.name, $1)
          + 0.4 * similarity(coalesce(f.brands,''), $1) AS sim,
        ts_rank(
          to_tsvector('simple',
            coalesce(f.name,'') || ' ' || coalesce(f.brands,'')),
          plainto_tsquery('simple', $1)
        ) AS ts,
        s.id AS default_serving_id,
        s.label AS default_serving_label,
        s.grams AS default_serving_grams
      FROM foods f
      LEFT JOIN servings s
        ON s.food_id = f.id AND s.is_default
      WHERE (f.source = 'off' OR f.owner_user_id = $2)
        AND (
          f.name % $1 OR
          coalesce(f.brands,'') % $1 OR
          to_tsvector('simple',
            coalesce(f.name,'') || ' ' || coalesce(f.brands,''))
            @@ plainto_tsquery('simple', $1)
        )
    )
    SELECT *,
      (0.5 * sim + 0.3 * ts + 0.2 * (quality_score::float / 100.0))
        AS score
    FROM scored
    ORDER BY score DESC, name ASC
    LIMIT $3 OFFSET $4;
    ```
  - `PgFoodRepository::search_count` is a separate query: `SELECT
    count(*) FROM foods f WHERE (f.source='off' OR f.owner_user_id=$2)
    AND (f.name % $1 OR coalesce(f.brands,'') % $1 OR
    to_tsvector(...) @@ plainto_tsquery('simple', $1));`
  - In `routes/foods.rs`, add `GET /foods/search` with query params
    `q: String, limit: Option<i64>, offset: Option<i64>`. Default
    `limit=20`, cap `limit <= 50`. Return `SearchResponse { results:
    Vec<FoodSearchHit>, total, limit, offset }` matching the lean
    shape in `initial_spec.md`.
  - Service plumbing: `FoodService::search(viewer, q, limit, offset)`
    calls both repo methods and assembles the response.
- **Acceptance:**
  - `cargo check -p loseit-db -p loseit-core -p loseit-api` clean.
  - HTTP tests using the in-memory fake (whose `search` is the simple
    substring ranker — that's fine, the production SQL is untestable
    without Postgres):
    - `test_search_returns_lean_hits`.
    - `test_search_respects_limit_and_offset`.
    - `test_search_total_count_is_independent_of_pagination`.
    - `test_search_excludes_other_users_customs`.
    - `test_search_rejects_blank_query` (handler returns 400 if `q`
      trimmed is empty).
- **Out of scope:**
  - Verifying the real PG ranker behaviour. Note in the PR description
    that ranking quality is a "needs real-PG integration tests" item.

---

## Phase 3 — Custom-food write paths

> Sequential after Phase 2 — handlers and service for custom-food CRUD,
> plus serving CRUD. These could in principle run in parallel, but they
> both touch `routes/foods.rs` and `server.rs`, so we serialize to avoid
> merge churn.

### T12 — Wire custom-food create/update/delete service + handler

- **Phase:** Phase 3 (serial)
- **Depends on:** T09, T10
- **Owner agent profile:** core-domain dev + axum dev (single task)
- **Files to create / modify:**
  - Fill in `FoodService::create_custom(owner, draft) -> Food`.
    - Validate `draft.name` non-empty (after trim); else
      `CoreError::Validation`.
    - Validate `nutrition.energy_kcal >= 0` if present.
    - Call `foods.create_custom`.
    - After creating the food, synthesize a default `100 g` system
      serving via `servings.create(food.id, ServingDraft { label:
      "100 g", grams: 100, is_default: true, source:
      ServingSource::System, sort_order: 0 })`. Both calls happen in
      the service layer; the repo doesn't know about this.
  - `FoodService::update_custom(owner, id, patch) -> Food`. Look up;
    `CoreError::NotFound` if missing; `CoreError::Forbidden` if
    `food.source == Off` or `food.owner_user_id != Some(owner)`. Then
    call `foods.update_custom`.
  - `FoodService::delete_custom(owner, id) -> ()`. Same ownership/source
    checks. Bubble up the conflict from `foods.delete_custom` (food
    referenced by log entries → 409).
  - Routes in `crates/loseit-api/src/routes/foods.rs`: `POST /foods`,
    `PATCH /foods/:id`, `DELETE /foods/:id`. DTOs: `CreateFoodBody`
    mirrors `FoodDraft`; `PatchFoodBody` mirrors `FoodPatch`.
- **Acceptance:**
  - Service unit tests:
    - `test_create_custom_food_creates_default_100g_serving`.
    - `test_create_custom_food_rejects_blank_name`.
    - `test_update_custom_food_forbidden_on_off_food`.
    - `test_update_custom_food_forbidden_on_other_users_custom`.
    - `test_delete_custom_food_conflict_when_referenced_by_log_entries`
      (the fake's `delete_custom` returns `Conflict` when any
      `InMemoryLogRepository` entry references the food — implementer
      will need to wire a shared `Arc<InMemoryLogRepository>` in the
      test setup, or inject a "referenced check" closure into the
      fake. Pick the simpler one.)
  - HTTP tests:
    - `test_post_food_returns_201_with_id_and_default_serving`.
    - `test_patch_food_404_for_unknown`.
    - `test_patch_food_403_when_owned_by_other_user`.
    - `test_delete_food_409_when_logs_reference_it`.
- **Out of scope:**
  - Serving CRUD (T13).

### T13 — Implement serving CRUD service + handler

- **Phase:** Phase 3 (serial)
- **Depends on:** T12
- **Owner agent profile:** core-domain dev + axum dev
- **Files to create / modify:**
  - Fill in `ServingService`:
    - `create(viewer, food_id, draft) -> Serving`. Look up the food.
      If `food.source == Off`, return `CoreError::Conflict("OFF foods
      are read-only; clone as a custom food to add servings")`. If
      `food.source == User && food.owner_user_id != Some(viewer)`,
      `CoreError::Forbidden`. If `draft.is_default == true`, call
      `servings.create` then `servings.set_default(food_id, new_id)`.
      (Two calls inside a single transaction is a v2 polish; the repo
      method is atomic on its own, and the brief window where two
      defaults exist is not user-visible because the new row hasn't
      been returned yet.)
    - `update(viewer, serving_id, patch) -> Serving`. Look up serving,
      then load its food, then apply the same source/ownership checks.
    - `set_default(viewer, food_id, serving_id)`. Same checks. Calls
      `servings.set_default` which is atomic.
    - `delete(viewer, serving_id)`. Same checks. Refuses if
      `serving.is_default == true` (the repo also enforces this; the
      service produces the friendlier message
      `CoreError::Conflict("cannot delete the default serving; set
      another as default first")`).
  - Routes (extend `routes/foods.rs` or create
    `routes/servings.rs` — implementer's call; the spec uses
    `POST /foods/{id}/servings`, `PATCH /servings/{id}`,
    `DELETE /servings/{id}` so a sibling file is cleaner). Also add
    `POST /servings/:id/default` (not in the original spec but the
    simplest way to expose `set_default`; flag this in the PR for PM
    sign-off).
- **Acceptance:**
  - Service unit tests:
    - `test_create_serving_rejected_on_off_food_with_clone_message`.
    - `test_create_serving_forbidden_on_other_users_custom`.
    - `test_set_default_serving_flips_atomically` — concurrent
      `set_default` calls against the in-memory fake; assert exactly
      one default at the end. (Re-uses the test seam established in
      T04.)
    - `test_delete_default_serving_returns_conflict`.
  - HTTP tests:
    - `test_post_serving_409_for_off_food`.
    - `test_patch_serving_403_for_other_users_custom`.
    - `test_delete_default_serving_409`.
- **Out of scope:**
  - Log entries (T14).

---

## Phase 4 — Log + day summary

### T14 — Implement `LogService::compute_snapshot` + `LogService` CRUD

- **Phase:** Phase 4 (serial)
- **Depends on:** T12, T13 (so a viewer can both create logs against
  their own customs and trip the default-serving lookup)
- **Owner agent profile:** core-domain dev
- **Files to create / modify:**
  - Fill in `crates/loseit-core/src/service/log.rs`:
    - `pub(crate) fn compute_snapshot(food: &Food, grams_total:
      Decimal) -> NutritionSnapshot`. Scale each per-100g field by
      `grams_total / 100`. For sodium specifically: stored value is
      grams; multiply by `grams_total / 100` to get grams, then by
      `1000` to get mg, store as `sodium_mg`. Round to the SQL column
      precision (`NUMERIC(8,2)`).
    - `create(user, draft: LogDraft) -> FoodLogEntry`. Validate
      `quantity > 0`. Look up food; `CoreError::NotFound` if missing
      or invisible to this user. Look up `draft.serving_id` via
      `servings.find_by_id`; `CoreError::Validation` if the serving's
      `food_id != draft.food_id`. Compute `grams_total = serving.grams
      * draft.quantity`. Build the snapshot. Persist via `logs.create`.
    - `update(user, id, patch: LogPatch) -> FoodLogEntry`. Load the
      existing entry; apply the patch in memory (resolving the new
      `serving_id` / `quantity` if either is set) and re-compute the
      snapshot; persist via `logs.update`.
    - `delete(user, id) -> ()`.
    - `list_in_range(user, from, to) -> Vec<FoodLogEntry>`.
  - Update `compute_snapshot` test coverage:
    - `test_compute_snapshot_scales_per_100g_to_grams_total`.
    - `test_compute_snapshot_converts_sodium_from_grams_to_milligrams`.
    - `test_compute_snapshot_passes_through_nullable_nutrients`.
- **Acceptance:**
  - All the snapshot tests above pass.
  - Service unit tests:
    - `test_log_create_uses_serving_grams_times_quantity`.
    - `test_log_create_rejects_serving_belonging_to_different_food`.
    - `test_log_create_404_for_unknown_food`.
    - `test_log_create_404_for_other_users_custom_food`.
    - `test_log_update_recomputes_snapshot`.
- **Out of scope:**
  - Day summary (T15).

### T15 — Add `POST/PATCH/DELETE /log`, `GET /log` handlers

- **Phase:** Phase 4 (serial)
- **Depends on:** T14
- **Owner agent profile:** axum dev
- **Files to create / modify:**
  - Create `crates/loseit-api/src/routes/log.rs` (or `logs.rs`; pick
    whichever the implementer prefers and update `routes/mod.rs`).
  - Routes: `POST /log`, `GET /log?from=…&to=…`, `PATCH /log/:id`,
    `DELETE /log/:id`.
  - Request DTOs:
    - `CreateLogBody { food_id, serving_id, consumed_on, meal,
      quantity, note }`. No `grams` field — per resolved product
      decision in `NEXT_STEPS.md`, every food has a synthetic 100 g
      serving so raw-grams is just `serving_id=<100g> quantity=2.0`.
    - `PatchLogBody { serving_id?, consumed_on?, meal?, quantity?,
      note? }`.
  - Response DTOs: `LogEntryResponse` mirrors `FoodLogEntry`, flattening
    `NutritionSnapshot` into top-level fields to match the spec.
  - Wire into the `authed` router.
- **Acceptance:**
  - HTTP tests:
    - `test_post_log_persists_snapshot_from_food_and_serving`.
    - `test_post_log_404_for_unknown_food`.
    - `test_post_log_400_for_quantity_zero`.
    - `test_post_log_400_for_meal_outside_enum`.
    - `test_get_log_filters_by_date_range_and_user`.
    - `test_patch_log_recomputes_snapshot_when_quantity_changes`.
    - `test_delete_log_204`.
- **Out of scope:**
  - Day summary (T16).

### T16 — Implement `GET /days/{date}/summary`

- **Phase:** Phase 4 (serial)
- **Depends on:** T15
- **Owner agent profile:** core-domain dev + axum dev
- **Files to create / modify:**
  - In `LogService`: `pub async fn day_summary(&self, user: Uuid, date:
    NaiveDate) -> CoreResult<DaySummary>`.
    - `let entries = logs.list_for_day(user, date).await?;`
    - `let active_goal = goals.find_active_on(user, date).await?;`
    - Group by `meal`; build `MealSubtotal` for each of the four meal
      values (always present, even with zero entries → consistent
      JSON shape). Sum macros across all entries to fill
      `total: NutritionSnapshot`.
  - Handler in `routes/log.rs` (or a sibling `routes/days.rs` — pick
    whichever, update `mod.rs`).
  - Response DTO: `DaySummaryResponse { date, total: NutritionResponse,
    by_meal: [MealSubtotalResponse; 4], active_goal: Option<GoalResponse>
    }`.
- **Acceptance:**
  - Service unit tests:
    - `test_day_summary_groups_entries_by_meal`.
    - `test_day_summary_includes_all_four_meals_even_when_empty`.
    - `test_day_summary_attaches_active_goal_or_none_when_no_goal`.
  - HTTP tests:
    - `test_get_day_summary_aggregates_three_meals`.
    - `test_get_day_summary_with_no_entries_returns_zero_totals`.
- **Out of scope:**
  - Recent/frequent (T17).

---

## Phase 5 — Recent / frequent

### T17 — Implement `GET /foods/recent` and `GET /foods/frequent`

- **Phase:** Phase 5 (serial)
- **Depends on:** T14 (needs `LogRepository` populated by tests creating
  log rows)
- **Owner agent profile:** core-domain dev + axum dev
- **Files to create / modify:**
  - In `LogService` (or `FoodService` — implementer's call; the
    architect's plan says these methods belong on `LogRepository` so
    `LogService` is the right home):
    - `pub async fn recent_foods(&self, user: Uuid, limit: i64) ->
      CoreResult<Vec<FoodSearchHit>>`.
    - `pub async fn frequent_foods(&self, user: Uuid, limit: i64) ->
      CoreResult<Vec<FoodSearchHit>>` — uses `FREQUENT_WINDOW_DAYS = 30`
      (top-level `const` in `service/log.rs`).
  - Both methods:
    1. Get the ranked list of food_ids from
       `logs.recent_food_ids` / `logs.frequent_food_ids`.
    2. Hydrate each via `foods.find_by_id` (in a loop is fine for v1;
       a `find_many` batch method is a v2 nice-to-have — flag in PR).
    3. For each, fetch the default serving via
       `servings.list_for_food` and filter `is_default`. Build
       `FoodSearchHit` (same shape as `/foods/search` results).
  - Routes in `routes/foods.rs`: `GET /foods/recent?limit=` (default 10,
    cap 50) and `GET /foods/frequent?limit=`.
- **Acceptance:**
  - Service unit tests:
    - `test_recent_foods_returns_distinct_foods_most_recent_first`.
    - `test_recent_foods_respects_limit`.
    - `test_frequent_foods_counts_within_30_day_window` — log entries
      35 days ago must NOT count; entries 25 days ago must.
    - `test_frequent_foods_orders_by_count_descending`.
  - HTTP tests:
    - `test_get_recent_foods_returns_lean_hits`.
    - `test_get_frequent_foods_returns_lean_hits_with_counts_descending`.
- **Out of scope:**
  - The ingest pipeline (T18).
  - Quick-add / copy-day (Priority 2, not v1).

---

## Phase 6 — Ingest pipeline + verification

### T18 — Implement `IngestService::run` + ingest binary (`loseit-ingest`)

- **Phase:** Phase 6
- **Depends on:** T05 (needs `FoodRepository::upsert_off_batch`), T06
  (needs `ServingRepository::create` + `set_default`), T08 (needs
  `BatchRepository`). Note this *can* run in parallel with any of
  Phases 2–5 once Phase 1 is done; we list it here because verification
  needs it to populate test data.
- **Owner agent profile:** ingest dev
- **Files to create / modify:**
  - Fill in `crates/loseit-core/src/service/ingest.rs::run`:
    - Call `batches.start(source_url, source_etag)`; capture
      `batch.id`.
    - Loop: `let Some(chunk) = source.next_chunk(BATCH_SIZE).await?`
      where `const BATCH_SIZE: usize = 500;`.
    - For each chunk, filter records: must have `code`,
      `product_name`, and `energy_kcal_100g`. Skip junk; track counts.
    - For each surviving record, sanity-check sodium: if
      `sodium_100g > Decimal::new(50, 0)` (i.e. >50 g per 100 g),
      `tracing::warn!(barcode = %r.code, sodium = %sodium, "implausible
      sodium value — likely uploaded as mg, skipping field")` and null
      the sodium field. (Don't reject the whole record.)
    - Compute `quality_score` (private helper
      `score(record) -> u8`):
      - 40 pts nutriscore_grade present
      - 15 pts brands non-empty
      - 15 pts at least one OFF-named serving derivable
      - 10 pts has ≥6 nutrients populated, 5 pts has ≥3
      - 10 pts `min(record.completeness, 1.0) * 10`
      - 10 pts categories_tags non-empty
      Sum, clamp to [0, 100].
    - Convert to `FoodDraft`-shaped (or a dedicated
      `OffUpsertRecord`) batch; call
      `foods.upsert_off_batch(batch.id, &chunk)`.
    - For each upserted food, synthesize servings via
      `servings.create`:
      - Always: `ServingDraft { label: "100 g", grams: 100,
        is_default: false, source: ServingSource::System, sort_order:
        100 }`.
      - If `record.serving_size` parseable to grams (use a small
        helper `parse_serving_size("30 g") -> Option<Decimal>` that
        handles `"30 g"`, `"30g"`, `"30.5 g"`; ml is skipped for v1):
        also a `ServingDraft { label: record.serving_size.clone(),
        grams: parsed, is_default: true, source: ServingSource::Off,
        sort_order: 0 }`.
      - If no OFF-derived serving, flip the 100 g serving to
        `is_default = true`.
      - Use `servings.set_default` for the flip after creation, so the
        partial-unique-index invariant holds.
    - After each chunk: `batches.bump_counts(batch.id, seen, upserted,
      skipped)`.
    - On any error: `batches.fail(batch.id, &err.to_string())` and
      re-raise.
    - On clean exit: `batches.finish(batch.id, total_stats)`.
  - In `crates/loseit-ingest/src/`:
    - Add `lib.rs` exposing `JsonlSource` and `ParquetSource`, both
      implementing `loseit_core::service::FoodRecordSource`.
      - `JsonlSource::open(path) -> Result<Self>` opens a file and
        wraps it in a `BufReader<File>`. `next_chunk(n)` reads up to
        `n` lines, parses each via `serde_json` into a raw `OffRaw`
        struct, then maps to `OffFoodRecord`.
      - `ParquetSource` uses `parquet::file::reader::SerializedFileReader`
        + `parquet::record::reader::RowIter` to iterate row groups.
        Implementation note: v1 may stub this with a `todo!()` if the
        ingest sample is JSONL only — flag in PR. The architect's plan
        requires both; ship JSONL fully, gate Parquet behind a
        `#[cfg(feature = "parquet")]` if needed.
    - Rewrite `main.rs` to:
      - Parse CLI args via `clap` (`--source jsonl|parquet`, `--input
        PATH`, `--database-url URL`).
      - Build a `PgPool` (re-use `loseit-db::build_pool`).
      - Construct `PgFoodRepository`, `PgServingRepository`,
        `PgBatchRepository`.
      - Build `IngestService` and call `run`.
      - Log stats; exit non-zero on failure.
  - Modify `crates/loseit-ingest/Cargo.toml` — add
    `loseit-core`, `loseit-db`, `clap`, `parquet`, `arrow`,
    `serde`, `serde_json`, `tokio` (workspace deps where present).
- **Acceptance:**
  - `cargo run -p loseit-ingest -- --source jsonl --input
    data/off-sample.jsonl --database-url $DATABASE_URL` against a
    freshly migrated dev DB:
    - Creates one `food_import_batches` row with `status='completed'`.
    - Inserts >0 foods and >=2× that many servings (each food gets at
      least a 100 g serving).
    - Re-running the same command produces no duplicate foods (idempotent
      upsert).
    - Reviewer manually confirms by inspecting the DB; no automated
      integration test in v1.
  - Service unit tests with an in-memory `FoodRecordSource`:
    - `test_ingest_filters_records_missing_required_fields`.
    - `test_ingest_synthesizes_100g_serving_for_every_food`.
    - `test_ingest_marks_off_derived_serving_as_default_when_present`.
    - `test_ingest_falls_back_to_100g_default_when_no_off_serving`.
    - `test_ingest_warns_and_nulls_implausible_sodium`.
    - `test_ingest_records_stats_on_batch`.
    - `test_ingest_is_idempotent_when_run_twice` — with a shared
      `InMemoryFoodRepository`, running the same source twice produces
      identical food count.
  - Quality-score unit tests:
    - `test_quality_score_minimum_zero_for_empty_record`.
    - `test_quality_score_capped_at_100`.
    - `test_quality_score_awards_full_points_for_complete_record`.
- **Out of scope:**
  - Real OFF Parquet download from
    `https://static.openfoodfacts.org/data/openfoodfacts-products.parquet`
    — that's a v2 polish. The binary reads from a local file path for
    v1.
  - ETag-based skipping of unchanged data — flag in PR as a v2 task.
  - Per-record sidecar progress file (chunk-boundary resumability is
    enough; idempotent upserts cover restarts).

### T19 — Verification sweep

- **Phase:** Phase 6
- **Depends on:** T01–T18
- **Owner agent profile:** any (verification specialist)
- **Files to create / modify:**
  - No code changes. Run:
    - `cargo build --workspace`
    - `cargo test --workspace`
    - `cargo clippy --workspace -- -D warnings`
    - `cargo fmt --check`
    - `cargo run -p loseit-ingest -- --source jsonl --input
      data/off-sample.jsonl --database-url $DATABASE_URL` against the
      docker-compose Postgres.
    - Hit each endpoint via `curl` (or a smoke test script) with
      `Authorization: Bearer <dev token>`:
      - `GET /api/v1/foods/search?q=yogurt`
      - `GET /api/v1/foods/{id}`
      - `GET /api/v1/foods/barcode/{barcode}`
      - `POST /api/v1/foods` (custom)
      - `PATCH /api/v1/foods/{id}`
      - `DELETE /api/v1/foods/{id}`
      - `POST /api/v1/foods/{id}/servings`
      - `PATCH /api/v1/servings/{id}`
      - `DELETE /api/v1/servings/{id}`
      - `POST /api/v1/log`, `GET /api/v1/log?from=…&to=…`,
        `PATCH /api/v1/log/{id}`, `DELETE /api/v1/log/{id}`
      - `GET /api/v1/days/{date}/summary`
      - `GET /api/v1/foods/recent`, `GET /api/v1/foods/frequent`
  - Produce a short verification report (in the PR description, not
    a separate doc) listing every endpoint hit and its observed status.
- **Acceptance:**
  - All `cargo` commands pass.
  - Every endpoint listed above returns the expected status (2xx for
    happy path, documented 4xx for the failure-case smoke tests).
- **Out of scope:**
  - Real-Postgres integration tests for the sqlx repos — explicitly
    deferred to "later" in `NEXT_STEPS.md`. Flag this as a known gap
    in the verification report.
  - JWKS authenticator end-to-end — dev bypass remains the v1 auth
    path.

---

## Sequencing notes

**Longest sequential chain:**
`T01 → T02 → T03 → T05 → T09 → T10 → T12 → T13 → T14 → T15 → T16 → T17 → T19`
(13 tasks). Ingest (T18) sits off the side of the main chain and can run
in parallel with anything from T09 onwards once Phase 1 has finished.

**Critical sequencing rules (per planning brief):**
1. Phase 0 (T01–T03) is one PR and blocks everything else.
2. No route lands before its repo+service. (E.g. T10 can't merge before
   T05 and T09.)
3. Ingest (T18) depends on `FoodRepository::upsert_off_batch` (T05),
   `ServingRepository::create`+`set_default` (T06), and
   `BatchRepository` (T08).
4. Log handlers (T15) depend on `FoodRepository::find_by_id` and
   `ServingRepository::list_for_food`/`find_by_id` from Phase 1 — already
   covered by T05+T06 being prerequisites of T09 / T14.
5. Recent / frequent (T17) sits after Phase 4 so that log entries exist
   in the test fixtures the agent writes.

**Parallel opportunities at a glance:**
- Phase 1: T04, T05, T06, T07, T08 — 5 agents in parallel.
- Phase 2: T10, T11 — 2 agents in parallel (both depend on T09; T11
  also depends on T08 for the migration).
- Phase 3 is serialized because T12, T13 share `routes/foods.rs`.
- Phase 4 is serialized for the same reason.
- T18 can run alongside Phase 2 / 3 / 4 / 5 if the swarm has capacity.

## Conventions reference (paste into PR descriptions)

- Repository traits in `loseit-core/src/repo/`, `#[async_trait]`.
- sqlx repos use function-style `query_as::<_, Row>("…")`. No macros, no
  compile-time DB.
- Services in `loseit-core/src/service/`, return `CoreResult<T>`.
- Routes return `Result<Json<T>, ApiError>`. `ApiError::from(CoreError)`
  already maps the domain errors; new variants of `CoreError` must be
  mapped there.
- Every new repo trait → in-memory fake in `loseit-testing/` in the same
  PR.
- HTTP tests use the real router with fakes (see `tests/http.rs`).
