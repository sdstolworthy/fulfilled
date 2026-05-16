# Tasks: Custom Foods List + Pagination

Source: `specs/audit_followup_arch.md` (architect doc, source of truth).
PM brief: `specs/audit_followup_pm.md`.

Each task is sized for a single developer agent in one ~30–90 min session
and lands its own tests. No task depends on another for `cargo build`
green: each merges independently.

## Task ordering / parallelization

```
T1  (core: Paginated<T> + resolve_page_params)
 │
 ▼
T2  (api: PaginatedResponse<T> + PageQuery)
 │
 ▼
T3  (migrate /foods/search to shared envelope; bump limits to 100/500)
 │
 ├──── log + weights chain ─────┐    ├──── foods/mine chain ────┐
 ▼                              ▼    ▼                          ▼
T4  LogRepository::list_paginated  T7 FoodRepository::list_mine
    + count_in_range (trait+pg+        + count_mine (trait+pg+
    in-memory fake)                    in-memory fake)
 │                                  │
 ▼                                  ▼
T5  LogService::list paginated     T8 FoodService::list_mine
    + /log handler envelope            + service unit tests
    + http_log.rs test updates      │
 │                                  ▼
 ▼                                  T9 GET /foods/mine handler
T6  WeightRepository::list_paginated   + http_foods.rs integration tests
    + count_for_user (trait+pg+
    in-memory fake)
 │
 ▼
T7w WeightService::list paginated
    + /weights handler envelope
    + http_weights.rs (new file)
```

`T1 → T2 → T3` serial (foundation: shared types, then the existing
`/foods/search` switch-over). Once `T3` lands, **two parallel chains**:

- Log chain: `T4 → T5`, then weights chain `T6 → T7w` (could pair the
  log + weights work as two sub-chains since they share no files — see
  parallel notes per task).
- Foods/mine chain: `T7 → T8 → T9`.

In a 3-agent swarm after `T3`: one agent on `T4-T5`, one on `T6-T7w`, one
on `T7-T8-T9`. Total critical-path length: `T1 → T2 → T3 → T7 → T8 → T9`
(6 tasks).

## Tasks

### T1 — Add `Paginated<T>`, `PageParams`, `resolve_page_params` in `loseit-core`

**Goal:** Land the shared pagination type + validator with full unit
coverage. No callers yet — pure addition.

**Files touched:**
- `crates/loseit-core/src/service/page.rs` (new)
- `crates/loseit-core/src/service/mod.rs` (re-exports)

**Steps:**
1. Create `service/page.rs` with `DEFAULT_PAGE_LIMIT = 100`,
   `MAX_PAGE_LIMIT = 500`, the `Paginated<T>` struct, the `PageParams`
   struct, and the `resolve_page_params(Option<i64>, Option<i64>) ->
   CoreResult<PageParams>` function exactly as specified in the arch
   doc's "Service-layer signatures > New shared type" section.
2. In `service/mod.rs`, add `pub mod page;` and
   `pub use page::{Paginated, PageParams, DEFAULT_PAGE_LIMIT,
   MAX_PAGE_LIMIT, resolve_page_params};`.
3. Add a `#[cfg(test)] mod tests` block at the bottom of `page.rs`.

**Tests to add (all in `service/page.rs`):**
- `resolve_page_params_applies_default_when_limit_none` — `None` → 100.
- `resolve_page_params_applies_default_when_limit_zero` — `Some(0)` → 100.
- `resolve_page_params_clamps_limit_above_max` — `Some(10_000)` → 500.
- `resolve_page_params_passes_limit_within_range` — `Some(250)` → 250.
- `resolve_page_params_rejects_negative_limit` — `Some(-1)` →
  `Err(CoreError::Validation("limit must be non-negative"))`.
- `resolve_page_params_rejects_negative_offset` — `Some(-1)` →
  `Err(CoreError::Validation("offset must be non-negative"))`.
- `resolve_page_params_defaults_offset_to_zero_when_none` — `None` → 0.

**Acceptance:**
- `cargo build -p loseit-core` succeeds.
- `cargo test -p loseit-core --lib service::page` passes (all 7 tests).
- No existing tests regress.

**Depends on:** none.

**Parallelizable with:** nothing (foundation).

---

### T2 — Add `PaginatedResponse<T>` + `PageQuery` in `loseit-api`

**Goal:** Land the generic wire DTO + query-deserialize struct. No
handler swaps yet — pure addition.

**Files touched:**
- `crates/loseit-api/src/routes/pagination.rs` (new)
- `crates/loseit-api/src/routes/mod.rs` (add `pub mod pagination;`)

**Steps:**
1. Create `routes/pagination.rs` with the `PaginatedResponse<T: Serialize>`
   struct (fields `results, total, limit, offset`), the
   `impl<T, R> From<Paginated<T>> for PaginatedResponse<R> where
   R: Serialize + From<T>` adapter, and the `PageQuery { limit:
   Option<i64>, offset: Option<i64> }` `Deserialize` struct.
2. Add `pub mod pagination;` to `routes/mod.rs`.

**Tests to add:**
- No standalone tests required — the adapter is exercised end-to-end by
  T3 and downstream. Compile-time correctness is the acceptance bar here.

**Acceptance:**
- `cargo build -p loseit-api` succeeds.
- `cargo test -p loseit-api` passes (no regressions; no new tests).

**Depends on:** T1.

**Parallelizable with:** nothing (still foundation).

---

### T3 — Migrate `/foods/search` to `Paginated<T>` + `PaginatedResponse<T>`; bump limits to 100/500

**Goal:** Replace `SearchPage`/`SearchResponse` with the shared types,
switch `FoodService::search` to call `resolve_page_params`, and bump
defaults across the contract.

**Files touched:**
- `crates/loseit-core/src/service/food.rs` (replace `SearchPage` and
  `SEARCH_*_LIMIT` constants; rework `search`)
- `crates/loseit-core/src/service/mod.rs` (drop `SearchPage` re-export)
- `crates/loseit-api/src/routes/foods.rs` (drop `SearchResponse`; use
  `PaginatedResponse<FoodSearchHitResponse>`)
- `crates/loseit-api/tests/http_foods.rs` (update `test_search_returns_lean_hits`
  to assert `limit == 100`; update any other test asserting the old 50
  cap — verify by searching for `limit\":\s*20|limit\":\s*50`)

**Steps:**
1. Delete `SearchPage` struct, `SEARCH_DEFAULT_LIMIT`, and
   `SEARCH_MAX_LIMIT` from `service/food.rs`.
2. Rewrite `FoodService::search` to call `resolve_page_params` and
   return `Paginated<FoodSearchHit>`. Body matches the arch doc's
   "Service-layer signatures > FoodService" section verbatim.
3. Drop the `pub use food::{FoodService, SearchPage};` `SearchPage` half
   in `service/mod.rs`; leave `FoodService`.
4. In `routes/foods.rs`: delete the `SearchResponse` struct and its
   `From<SearchPage>` impl. Change the `search` handler return type to
   `Result<Json<PaginatedResponse<FoodSearchHitResponse>>, ApiError>`
   and use `Ok(Json(page.into()))` — the new generic `From<Paginated<T>>
   for PaginatedResponse<R>` covers the conversion. Drop the
   `use loseit_core::service::SearchPage;` import; add an import for
   `crate::routes::pagination::PaginatedResponse`.
5. Update `crates/loseit-api/tests/http_foods.rs`:
   - `test_search_returns_lean_hits`: change `assert_eq!(body["limit"],
     20)` → `assert_eq!(body["limit"], 100)`.
   - Audit the file (`grep -n 'limit": *20\|limit": *50' tests/http_foods.rs`)
     for any other hard-coded old-default assertions; update to 100/500.

**Tests to add:**
- `test_foods_search_default_limit_is_now_100` in `http_foods.rs` —
  guards the contract bump (request with no `limit`, assert
  `body["limit"] == 100`).
- (Optional, recommended) `test_foods_search_clamps_limit_at_500` —
  request `limit=10000`, assert `body["limit"] == 500`.

**Acceptance:**
- `cargo build --workspace` succeeds.
- `cargo test -p loseit-core` passes (no `SearchPage` references remain).
- `cargo test -p loseit-api` passes; existing `http_foods.rs` tests stay
  green with their limit assertions updated.
- The wire body for `/foods/search` is byte-identical except `limit`
  now defaults to 100 and caps at 500.

**Depends on:** T1, T2.

**Parallelizable with:** nothing (still foundation; T4–T9 unblock once
this lands).

---

### T4 — Add `LogRepository::list_paginated` + `count_in_range` (trait + Pg + in-memory fake)

**Goal:** Add the two new repo methods on `LogRepository` with both
backends and direct fake-level tests. `list_in_range` (with required
dates) is kept untouched.

**Files touched:**
- `crates/loseit-core/src/repo/log.rs` (trait additions)
- `crates/loseit-db/src/log_repo.rs` (`PgLogRepository` impls)
- `crates/loseit-testing/src/logs.rs` (`InMemoryLogRepository` impls + tests)

**Steps:**
1. In `repo/log.rs`, add two async trait methods (signatures from arch
   doc "Repository / SQL changes > LogRepository"):
   - `list_paginated(user_id, from: Option<NaiveDate>, to:
     Option<NaiveDate>, limit, offset) -> CoreResult<Vec<FoodLogEntry>>`
   - `count_in_range(user_id, from: Option<NaiveDate>, to:
     Option<NaiveDate>) -> CoreResult<i64>`
2. In `loseit-db/src/log_repo.rs`, implement both methods on
   `PgLogRepository` using the exact SQL from the arch doc
   "SQL — `PgLogRepository::list_paginated`" and
   "SQL — `PgLogRepository::count_in_range`" sections. Reuse the
   existing `SELECT_COLS` constant for the page query.
3. In `loseit-testing/src/logs.rs`, implement the methods on
   `InMemoryLogRepository`: filter by `user_id` and optional date bounds,
   sort `consumed_on DESC, created_at DESC, id DESC`, then skip/take.
   `count_in_range` returns the filtered count.

**Tests to add (in-memory fake; in `crates/loseit-testing/src/logs.rs`'s
`#[cfg(test)] mod tests` block — add one if it doesn't exist):**
- `test_in_memory_log_list_paginated_orders_newest_first_with_id_tiebreak`.
- `test_in_memory_log_list_paginated_respects_from_to`.
- `test_in_memory_log_list_paginated_no_filters_returns_all_user_entries`.
- `test_in_memory_log_count_in_range_independent_of_pagination`.
- `test_in_memory_log_list_paginated_excludes_other_users_entries`.

**Acceptance:**
- `cargo build --workspace` succeeds (both backends implement the new
  methods).
- `cargo test -p loseit-testing` passes.
- `cargo check -p loseit-db` clean.

**Depends on:** T3 (so the order of merges leaves a single mergeable
chain; technically `T4` only needs T1's types since the repo doesn't
use `Paginated`, but ordering after T3 keeps the spec's wave clean).

**Parallelizable with:** T7 (different traits, different files).

---

### T5 — Wire `LogService::list` to paginated repo; flip `/log` handler to envelope

**Goal:** Service returns `Paginated<FoodLogEntry>`; handler returns
`PaginatedResponse<LogEntryResponse>`; SQL does the sort and pagination.

**Files touched:**
- `crates/loseit-core/src/service/log.rs` (new `list` method; keep
  `list_in_range` as-is — see Inconsistency note in report)
- `crates/loseit-api/src/routes/log.rs` (rewrite `list` handler; flip
  `RangeQuery` to optional `from`/`to` + `limit`/`offset`)
- `crates/loseit-api/tests/http_log.rs` (update existing test, add new
  pagination tests)

**Steps:**
1. In `service/log.rs`, add `pub async fn list(&self, user: Uuid, from:
   Option<NaiveDate>, to: Option<NaiveDate>, limit: Option<i64>, offset:
   Option<i64>) -> CoreResult<Paginated<FoodLogEntry>>` exactly per the
   arch doc "Service-layer signatures > LogService" section. Validate
   `from <= to` first; call `resolve_page_params`; call
   `logs.list_paginated` + `logs.count_in_range`.
2. In `routes/log.rs`:
   - Replace `RangeQuery { from: NaiveDate, to: NaiveDate }` with
     `ListLogQuery { from: Option<NaiveDate>, to: Option<NaiveDate>,
     limit: Option<i64>, offset: Option<i64> }` (a single struct rather
     than reusing `PageQuery` because it adds `from`/`to`).
   - Rewrite the `list` handler to:
     - call `state.logs.list(user.id, q.from, q.to, q.limit, q.offset)`
     - return
       `Result<Json<PaginatedResponse<LogEntryResponse>>, ApiError>` via
       `Ok(Json(page.into()))`.
   - Delete the in-handler sort (the SQL handles it now).
   - Delete the in-handler `from > to` check (service does it now).
3. In `tests/http_log.rs`:
   - Update `test_get_log_filters_by_date_range_and_user` to read
     `body["results"]` instead of `body.as_array()`, and assert
     `body["total"] == 2`.

**Tests to add (`tests/http_log.rs`):**
- `test_log_list_response_envelope_has_results_total_limit_offset` —
  request `/log` with no params, assert all four top-level keys present.
- `test_log_list_returns_total_independent_of_limit` — seed 5 entries,
  request `limit=2`, assert `total == 5` and `results.len() == 2`.
- `test_log_list_with_no_from_to_returns_most_recent_default_page` —
  seed 3 entries, no params, assert newest-first order and `limit == 100`.
- `test_log_list_clamps_limit_at_500` — request `limit=10000`, assert
  `body["limit"] == 500`.
- `test_log_list_rejects_from_after_to_with_400` — `from=2026-05-15&
  to=2026-05-10`, assert 400.
- `test_log_list_pagination_does_not_overlap` — seed 5 entries, fetch
  page 1 (`limit=2&offset=0`) and page 2 (`limit=2&offset=2`); assert no
  id appears on both.

**Acceptance:**
- `cargo build --workspace` succeeds.
- `cargo test -p loseit-core --lib service::log` passes (existing
  snapshot tests stay green; the existing `list_in_range` method still
  works).
- `cargo test -p loseit-api --test http_log` passes (updated +
  new tests green).

**Depends on:** T4.

**Parallelizable with:** T6, T7 (different files).

---

### T6 — Add `WeightRepository::list_paginated` + `count_for_user`; remove `list_for_user`

**Goal:** Replace `list_for_user` (single method, returns `Vec<Weight>`)
with `list_paginated` + `count_for_user` across the trait, Pg impl, and
in-memory fake. No callers yet — the service rewires in T7w.

**Files touched:**
- `crates/loseit-core/src/repo/weight.rs` (trait change)
- `crates/loseit-db/src/weight_repo.rs` (Pg impl rewrite)
- `crates/loseit-testing/src/weights.rs` (fake rewrite + tests)
- `crates/loseit-core/src/service/weight.rs` (update the one caller
  in the same PR so the workspace builds — the service call site
  changes here in T6; the new method body & handler wire-up are T7w)

**Steps:**
1. In `repo/weight.rs`, replace `list_for_user` with:
   - `list_paginated(user_id, from: Option<NaiveDate>, to:
     Option<NaiveDate>, limit, offset) -> CoreResult<Vec<Weight>>`
   - `count_for_user(user_id, from: Option<NaiveDate>, to:
     Option<NaiveDate>) -> CoreResult<i64>`
   (Architect says `list_for_user` has no other in-tree callers; we'll
   confirm by grepping — see resolution in report.)
2. In `loseit-db/src/weight_repo.rs`, swap the `list_for_user` impl for
   the two new methods using the SQL from arch doc
   "SQL — `PgWeightRepository::list_paginated`" and
   "SQL — `PgWeightRepository::count_for_user`" (add `, id DESC` to the
   `ORDER BY` for tiebreak stability — Weight has no `id` column in the
   current `SELECT_COLS` list; verify it does and add to the SELECT if
   missing).
3. In `loseit-testing/src/weights.rs`, rewrite the fake impl to match:
   add `id` to the sort tiebreak, support `limit`/`offset`, and add
   `count_for_user`.
4. In `service/weight.rs`, **temporarily** make `WeightService::list`
   continue to compile by calling `list_paginated` with `limit=None,
   offset=None` and discarding the count — or, simpler, since this is
   one trivial swap, just update `WeightService::list` to its final
   signature returning `Paginated<Weight>` here (folding T7w's service
   change into T6 keeps T7w small). **Recommended:** fold the service
   change into this task per the architect's "old `list(...)` is
   removed" note — see arch doc "WeightService" section.

**Tests to add (`crates/loseit-testing/src/weights.rs` `#[cfg(test)]`):**
- `test_in_memory_weight_list_paginated_orders_newest_first`.
- `test_in_memory_weight_list_paginated_respects_from_to`.
- `test_in_memory_weight_count_for_user_independent_of_pagination`.
- `test_in_memory_weight_list_paginated_excludes_other_users`.

**Acceptance:**
- `cargo build --workspace` succeeds (the handler still calls
  `state.weights.list(user.id, q.from, q.to)` but with two arguments
  vs the new four — so this task **must** update the handler too, or
  the handler will fail to compile).
- Note: because the handler in `routes/weights.rs` still passes only
  `(user.id, q.from, q.to)`, change the call site to
  `state.weights.list(user.id, q.from, q.to, None, None).await?` and
  unwrap `.results` for now to keep the wire shape intact. T7w then
  flips the wire shape and adds the params.
- `cargo test -p loseit-testing` passes.

**Depends on:** T3 (uses `Paginated<T>` from T1, but ordering after T3
keeps wave clean).

**Parallelizable with:** T4–T5 (log chain) and T7–T9 (foods/mine chain).

---

### T7w — Flip `/weights` handler to envelope; add pagination tests

**Goal:** Move `/weights` from a bare-array body to
`PaginatedResponse<WeightResponse>` with full pagination params.

**Files touched:**
- `crates/loseit-api/src/routes/weights.rs` (rewrite `list` handler;
  expand `ListQuery`)
- `crates/loseit-api/tests/http_weights.rs` (new file)
- `crates/loseit-api/tests/http.rs` (update
  `weight_post_then_list_round_trip` to read `body["results"]`)

**Steps:**
1. In `routes/weights.rs`:
   - Expand `ListQuery` to `{ from: Option<NaiveDate>, to:
     Option<NaiveDate>, limit: Option<i64>, offset: Option<i64> }`.
   - Rewrite `list` to call
     `state.weights.list(user.id, q.from, q.to, q.limit, q.offset)` and
     return
     `Result<Json<PaginatedResponse<WeightResponse>>, ApiError>` via
     `Ok(Json(page.into()))`.
2. In `tests/http.rs`, update `weight_post_then_list_round_trip` to read
   from `body["results"]` instead of `body.as_array()`.
3. Create `tests/http_weights.rs`. Copy the `build_test_app` /
   `read_json` / `read_text` patterns from `tests/http.rs` (or factor a
   `build_test_app_with` seeder if cleaner — implementer's call).

**Tests to add (`tests/http_weights.rs`):**
- `test_weights_list_response_envelope_has_results_total_limit_offset`.
- `test_weights_list_returns_total_independent_of_limit`.
- `test_weights_list_orders_newest_first` (weights on three distinct
  dates; assert `recorded_on` desc).
- `test_weights_list_rejects_from_after_to_with_400`.
- `test_weights_list_clamps_limit_at_500`.
- `test_weights_list_with_no_from_to_returns_most_recent_default_page`.
- `test_weights_list_pagination_does_not_overlap`.

**Acceptance:**
- `cargo build --workspace` succeeds.
- `cargo test -p loseit-api` passes — existing
  `weight_post_then_list_round_trip` reads `body["results"]`; new tests
  green.

**Depends on:** T6.

**Parallelizable with:** T4–T5 (log chain), T7–T9 (foods/mine chain).

---

### T7 — Add `FoodRepository::list_mine` + `count_mine` (trait + Pg + in-memory fake)

**Goal:** Repo-layer scaffolding for `/foods/mine`. No service or
handler yet.

**Files touched:**
- `crates/loseit-core/src/repo/food.rs` (trait additions)
- `crates/loseit-db/src/food_repo.rs` (`PgFoodRepository` impls)
- `crates/loseit-testing/src/foods.rs` (`InMemoryFoodRepository` impls
  + tests)

**Steps:**
1. In `repo/food.rs`, add to the `FoodRepository` trait:
   - `async fn list_mine(&self, owner: Uuid, q: Option<&str>, limit:
     i64, offset: i64) -> CoreResult<Vec<FoodSearchHit>>`
   - `async fn count_mine(&self, owner: Uuid, q: Option<&str>) ->
     CoreResult<i64>`
2. In `loseit-db/src/food_repo.rs`, implement both on
   `PgFoodRepository`. Use the SQL from arch doc
   "SQL — `PgFoodRepository::list_mine`" and "`PgFoodRepository::
   count_mine`" verbatim. For row decoding, reuse the same pattern as
   `search` (`row.try_get` for each column → assemble `FoodSearchHit`
   with `calories_per_serving` computed as `(energy * grams /
   100).round()`).
3. In `loseit-testing/src/foods.rs`, implement both on
   `InMemoryFoodRepository`:
   - Filter by `owner_user_id == Some(owner)` AND `source ==
     FoodSource::User`.
   - When `q` is `Some(non-empty)`: case-insensitive substring on
     `name`, with `brands` appended to the haystack (mirror the existing
     `search` haystack pattern).
   - Sort `created_at DESC, id DESC`.
   - Skip `offset`, take `limit`.
   - Hydrate default serving via the wired serving repo (same pattern
     as the existing `search` impl).

**Tests to add (in
`crates/loseit-testing/src/foods.rs`'s `#[cfg(test)] mod tests`):**
- `test_in_memory_list_mine_returns_only_callers_user_customs` (seed
  one OFF, one alice-custom, one bob-custom; expect 1 result for alice).
- `test_in_memory_list_mine_excludes_off_foods`.
- `test_in_memory_list_mine_orders_newest_first`.
- `test_in_memory_list_mine_filters_by_q_case_insensitive`.
- `test_in_memory_list_mine_q_matches_brand`.
- `test_in_memory_list_mine_blank_q_returns_all` — `None` and `Some("")`
  both behave like no filter (note: the fake should treat `Some("")`
  same as `None` to match the service-layer trimming).
- `test_in_memory_count_mine_independent_of_pagination`.

**Acceptance:**
- `cargo build --workspace` succeeds.
- `cargo test -p loseit-testing` passes.
- `cargo check -p loseit-db` clean.

**Depends on:** T3 (ordering).

**Parallelizable with:** T4–T5 (log chain) and T6–T7w (weights chain).

---

### T8 — Add `FoodService::list_mine`

**Goal:** Service-layer composition + validation for `/foods/mine`,
fully tested against the in-memory fake.

**Files touched:**
- `crates/loseit-core/src/service/food.rs` (add `list_mine`)

**Steps:**
1. Add `pub async fn list_mine(&self, owner: Uuid, q: Option<&str>,
   limit: Option<i64>, offset: Option<i64>) ->
   CoreResult<Paginated<FoodSearchHit>>` per the arch doc
   "Service-layer signatures > FoodService" section:
   - Resolve page params via `resolve_page_params(limit, offset)?`.
   - Trim `q`; treat empty/whitespace as `None`.
   - If trimmed `q.chars().count() > 200` → `Validation("q must be 200
     characters or fewer")`.
   - Call `foods.list_mine(owner, q_filter.as_deref(), page.limit,
     page.offset)` + `foods.count_mine(owner, q_filter.as_deref())`.
   - Return `Paginated { results, total, limit, offset }`.
2. Add a `#[cfg(test)] mod tests` block at the bottom of
   `service/food.rs` if one doesn't exist (the file currently has no
   test module).

**Tests to add (in `service/food.rs`):**
- `list_mine_returns_only_callers_user_customs` (uses
  `InMemoryFoodRepository` + `InMemoryServingRepository`; seed an OFF
  food, alice's custom, bob's custom; expect 1 result for alice).
- `list_mine_excludes_off_foods`.
- `list_mine_orders_newest_first` (three customs with distinct
  `created_at`; assert order).
- `list_mine_filters_by_q_case_insensitive` ("Mom's Lasagna" + "Dad's
  Chili"; `q="mom"` → just the lasagna).
- `list_mine_q_matches_brand`.
- `list_mine_blank_q_returns_all` (both `Some("")` and `Some("   ")`).
- `list_mine_clamps_limit_above_max` (`limit=Some(10_000)` →
  `Paginated.limit == 500`).
- `list_mine_default_limit_is_100`.
- `list_mine_rejects_q_over_200_chars` (e.g. `"a".repeat(201)` → 400).
- `list_mine_total_independent_of_pagination` (5 customs; `limit=2`;
  `total == 5`).
- `list_mine_rejects_negative_limit` and
  `list_mine_rejects_negative_offset` (delegate to
  `resolve_page_params` but worth a smoke).

**Acceptance:**
- `cargo build -p loseit-core` succeeds.
- `cargo test -p loseit-core --lib service::food` passes.

**Depends on:** T7.

**Parallelizable with:** T4–T5 (log) and T6–T7w (weights).

---

### T9 — Add `GET /foods/mine` handler + integration tests

**Goal:** Ship the endpoint end-to-end.

**Files touched:**
- `crates/loseit-api/src/routes/foods.rs` (add `list_mine` handler;
  register route)
- `crates/loseit-api/tests/http_foods.rs` (new tests + seed helpers
  for user-customs)

**Steps:**
1. In `routes/foods.rs`:
   - Add a `MineQuery { q: Option<String>, limit: Option<i64>, offset:
     Option<i64> }` `Deserialize` struct (can't reuse `PageQuery` —
     adds `q`).
   - Add the handler:
     ```rust
     async fn list_mine(
         State(state): State<AppState>,
         AuthenticatedUser(user): AuthenticatedUser,
         Query(q): Query<MineQuery>,
     ) -> Result<Json<PaginatedResponse<FoodSearchHitResponse>>, ApiError> {
         let page = state.foods.list_mine(user.id, q.q.as_deref(),
             q.limit, q.offset).await?;
         Ok(Json(page.into()))
     }
     ```
   - Register the route. **Critical:** add the `.route("/foods/mine",
     get(list_mine))` line **before** `.route("/foods/:id", ...)` to
     avoid matchit's static-vs-dynamic collision — same pattern as the
     existing `/foods/search`, `/foods/recent`, `/foods/frequent`,
     `/foods/barcode/:barcode` declarations. The existing "Order note"
     comment in the file documents the convention.
2. In `tests/http_foods.rs`:
   - Add a seed helper `seed_user_custom(foods, servings, owner, name,
     brands, calories_per_100g) -> Uuid` mirroring the existing
     `seed_off_food` shape but with `source = FoodSource::User` and a
     specific `owner_user_id`. (Use
     `InMemoryFoodRepository::create_custom` since the fake already
     implements it.)

**Tests to add (`tests/http_foods.rs`):**
- `test_foods_mine_returns_only_callers_customs` (alice + bob; alice
  hits `/foods/mine`; sees only her own).
- `test_foods_mine_excludes_off_foods` (seed OFF + alice-custom; only
  the custom appears).
- `test_foods_mine_orders_by_created_at_desc` (three customs at
  different times).
- `test_foods_mine_filters_by_q_substring_case_insensitive`.
- `test_foods_mine_empty_when_no_customs` (200, `results: []`, `total:
  0`; **not** 404).
- `test_foods_mine_default_limit_is_100`.
- `test_foods_mine_clamps_limit_at_500`.
- `test_foods_mine_negative_limit_returns_400`.
- `test_foods_mine_pagination_does_not_overlap` (5 customs; pages 1 and
  2 share no ids).

**Acceptance:**
- `cargo build --workspace` succeeds.
- `cargo test -p loseit-api --test http_foods` passes — all new tests
  green.
- `cargo test -p loseit-api` passes — full suite stays green.

**Depends on:** T8.

**Parallelizable with:** T4–T5 (log) and T6–T7w (weights).

---

## Sequencing summary

- **Critical path:** `T1 → T2 → T3 → T7 → T8 → T9` (6 tasks).
- **Two independent post-T3 chains:**
  - Log: `T4 → T5`
  - Weights: `T6 → T7w`
  - Foods/mine: `T7 → T8 → T9`
- After T3, a 3-agent swarm can clear the rest in three parallel chains.

## Conventions (paste into PR descriptions)

- Repository traits in `loseit-core/src/repo/`, `#[async_trait]`. Add
  the in-memory fake in the same PR as the trait method body.
- sqlx repos use function-style `query_as::<_, Row>("…")` or
  `query("…")` with explicit `try_get` decoding. No `query!` macros, no
  compile-time DB.
- Services in `loseit-core/src/service/`, return `CoreResult<T>`. New
  service methods carry `#[tracing::instrument(skip(self))]`.
- Handlers in `loseit-api/src/routes/`, return `Result<Json<T>, ApiError>`.
  `ApiError::from(CoreError)` already maps `Validation` → 400, `Forbidden`
  → 403, `NotFound` → 404, `Conflict` → 409, `Internal` → 500.
- Every paged endpoint uses the same default (100) and max (500). The
  service is the source of truth via `resolve_page_params`; handlers
  just forward.
- Wire shape is `{ results, total, limit, offset }` on every paged
  endpoint, in that field-declaration order.
