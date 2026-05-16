# v1 Finish-up — Implementation Tasks

Six features that close out the v1 server surface:

1. Unified pagination for `/foods/mine` (new), `/log`, `/weights`.
2. `POST /log/quick_add` — log raw calories via a per-user sentinel food.
3. `POST /log/copy` — bulk-copy one day's log entries to another.
4. JWKS authenticator (replace the unimplemented `AuthConfig::Jwks` branch).
5. Account lifecycle — `DELETE /me` + async data export (`POST /me/export`, `GET /me/export/:job_id`).
6. OpenAPI lockstep + sodium-units docstring fix.

Pagination scaffolding already landed in commit `133eb84`:

- `loseit_core::service::page::{Paginated<T>, PageParams, resolve_page_params}` (`server/crates/loseit-core/src/service/page.rs`) with `DEFAULT_PAGE_LIMIT = 100` and `MAX_PAGE_LIMIT = 500`.
- `loseit_api::routes::pagination::{PaginatedResponse<T>, PageQuery}` (`server/crates/loseit-api/src/routes/pagination.rs`).
- `/foods/search` already migrated to the new envelope (see commit for handler shape).

Read this file end-to-end before claiming a task. Each task is self-contained — do not look for hints in the design doc. If something genuinely isn't here, surface it.

Each task carries a `Status: pending` line. Flip to `in_progress` when you start, `done` when you finish (in your branch's commit message, not in this file).

---

## Conventions used in every task

- `server/...` paths are relative to the repository root; the worktree currently roots them under `/workplace/fulfilled/.claude/worktrees/pm-v1-finishup/`. Always use the `server/` prefix.
- "OpenAPI delta" sections give YAML you must merge into `server/specs/openapi.yaml`. Add new schemas under `components.schemas`; add new paths under `paths`. Do not re-order existing keys.
- Repo traits live in `loseit-core` (`server/crates/loseit-core/src/repo/`). Pg implementations live in `loseit-db` (`server/crates/loseit-db/src/`). In-memory fakes live in `loseit-testing` (`server/crates/loseit-testing/src/`). A new method on a trait requires all three.
- Service-layer validation calls `resolve_page_params(limit, offset)` from `loseit_core::service::page`. Handlers never clamp.
- Existing tests live in `server/crates/loseit-api/tests/` (`http_foods.rs`, `http_log.rs`, `http_servings.rs`, `http.rs`). New endpoint suites either extend an existing file or get a new sibling.
- Domain errors map: `CoreError::Validation` → 400, `CoreError::NotFound` → 404, `CoreError::Forbidden` → 403, `CoreError::Conflict` → 409. `AuthError::Upstream` → 503 (already wired in `server/crates/loseit-api/src/error.rs`).

---

## Task index

| ID | Title | Size | Suggested model |
|----|-------|------|----------------|
| T01 | Add `list_mine`/`count_mine` to `FoodRepository` | M | sonnet |
| T02 | Implement `FoodService::list_mine` + `GET /foods/mine` handler + OpenAPI | M | sonnet |
| T03 | Add `list_paginated`/`count_in_range` to `LogRepository` + `LogService::list` | M | sonnet |
| T04 | Migrate `GET /log` handler to pagination + OpenAPI | M | sonnet |
| T05 | Replace `WeightRepository::list_for_user` with paginated variant + service | M | sonnet |
| T06 | Migrate `GET /weights` handler to pagination + OpenAPI | M | sonnet |
| T07 | Migration `0005_quick_add_sentinel.sql` + `find_or_create_quick_add` + sentinel filters + reserved-name guard | L | opus |
| T08 | `LogService::quick_add` + `POST /log/quick_add` handler + OpenAPI | M | sonnet |
| T09 | Add `LogRepository::create_many` (trait + Pg via UNNEST + fake) | M | sonnet |
| T10 | `LogService::copy_day` + `POST /log/copy` handler + OpenAPI | M | opus |
| T11 | JWKS authenticator (`auth/jwks.rs`) + `AuthConfig::Jwks` extension + wiring | L | opus |
| T12 | `UserRepository::delete_user` + `UserService::delete_self` + `DELETE /me` handler + OpenAPI | M | sonnet |
| T13 | Migration `0006_export_jobs.sql` + domain `export.rs` + `ExportJobRepository` (trait + Pg + fake) | L | opus |
| T14 | `ExportStorage` trait + local-FS impl + signed-URL HMAC helpers + `GET /me/export/file/:token` public route | L | opus |
| T15 | `ExportService` + `POST /me/export` + `GET /me/export/:job_id` + in-process runner + startup recovery | L | opus |
| T16 | OpenAPI sweep — sodium docstring, `/foods/search` description, changelog note, tidy-up | S | sonnet |

---

### Task 1: Add `list_mine` and `count_mine` to `FoodRepository`

**Status:** pending
**Depends on:** none
**Parallelizable with:** T03, T05, T07, T09, T11, T13 (different crates / files)
**Estimated size:** M (3 files, ~250 LOC)
**Suggested model:** sonnet

**Scope.** Extend the `FoodRepository` trait with two methods — `list_mine` (paginated lookup of the caller's customs) and `count_mine` (full-match `total`). Implement on the Pg backend and on the in-memory fake. No service or HTTP wiring in this task.

**Context the dev needs.**
- `server/crates/loseit-core/src/repo/food.rs` — `FoodRepository` trait definition. New methods go here.
- `server/crates/loseit-db/src/food_repo.rs` — `PgFoodRepository` impl; existing `search` (line ~149) and `search_count` (line ~249) are the template for the new methods.
- `server/crates/loseit-testing/src/foods.rs` — `InMemoryFoodRepository` fake; the new methods must implement the same logic against the in-memory `Vec<Food>`.
- `server/crates/loseit-core/src/domain/food.rs` — `FoodSearchHit` struct (the row shape these methods return).
- Index `foods_owner_idx` already exists at `server/migrations/0001_initial.sql:126` — no new DDL.
- Commit `133eb84` — pagination scaffolding (`Paginated<T>`, `resolve_page_params`) you'll consume in T02.

**Spec.**

Trait additions to `FoodRepository`:

```rust
async fn list_mine(
    &self,
    owner: Uuid,
    q: Option<&str>,
    limit: i64,
    offset: i64,
) -> CoreResult<Vec<FoodSearchHit>>;

async fn count_mine(&self, owner: Uuid, q: Option<&str>) -> CoreResult<i64>;
```

Postgres SQL for `list_mine` (one round-trip, no N+1 — `LEFT JOIN` the default serving in the same query, mirroring the existing `search` SQL):

```sql
SELECT
    f.id, f.source, f.name, f.brands AS brand, f.barcode,
    s.id AS serving_id, s.label AS serving_label, s.grams AS serving_grams,
    CASE
        WHEN f.energy_kcal_100g IS NOT NULL AND s.grams IS NOT NULL
            THEN ROUND(f.energy_kcal_100g * s.grams / 100, 2)
        ELSE NULL
    END AS calories_per_serving
FROM foods f
LEFT JOIN servings s ON s.food_id = f.id AND s.is_default
WHERE f.owner_user_id = $1
  AND f.source = 'user'
  AND ($2::text IS NULL OR f.name ILIKE '%' || $2 || '%' OR coalesce(f.brands,'') ILIKE '%' || $2 || '%')
  AND f.name <> '__quick_add__'
ORDER BY f.created_at DESC, f.id DESC
LIMIT $3 OFFSET $4;
```

(Use whatever column names the existing `search` SQL projects for `FoodSearchHit` — match its row decode exactly; the comment above is illustrative.)

Postgres SQL for `count_mine`:

```sql
SELECT COUNT(*)::BIGINT
FROM foods f
WHERE f.owner_user_id = $1
  AND f.source = 'user'
  AND ($2::text IS NULL OR f.name ILIKE '%' || $2 || '%' OR coalesce(f.brands,'') ILIKE '%' || $2 || '%')
  AND f.name <> '__quick_add__';
```

Fake (in-memory) impl: filter `foods.iter()` by `owner_user_id == owner && source == User && name != "__quick_add__"`; if `q` is `Some(s)`, also require `name.to_lowercase().contains(&s.to_lowercase()) || brands.contains(...)`. Sort by `created_at DESC, id DESC`. Apply `offset`/`limit`. `count_mine` returns the unsliced count.

The `__quick_add__` filter is in the SQL/fake for both methods, even though the migration that creates the sentinel ships in T07 — the filter is a no-op on databases without sentinel rows yet, so safe to land first.

**Files to touch.**
- `server/crates/loseit-core/src/repo/food.rs` — add two trait methods.
- `server/crates/loseit-db/src/food_repo.rs` — Pg impl.
- `server/crates/loseit-testing/src/foods.rs` — fake impl.

**Acceptance criteria.**
- `cargo build -p loseit-core -p loseit-db -p loseit-testing` succeeds.
- Trait signatures exactly match the spec above.
- Pg SQL uses `foods_owner_idx` (verify with `EXPLAIN` in a comment if convenient, not required).
- Both methods exclude sentinel rows (`name <> '__quick_add__'`).
- The `q` parameter is passed as `Option<&str>`; `None` or `Some("")` (after trim, handled in service) is the unfiltered case.

**Test plan.**
Add to `server/crates/loseit-core/src/repo/` test modules where the existing search tests live, or to a new `tests/list_mine.rs` integration if more natural. Cases:
- `list_mine_returns_only_user_owned_foods` — seed a custom for Alice, an OFF row, and a custom for Bob; Alice's `list_mine` returns only her one row.
- `list_mine_filters_by_q_case_insensitive` — substring match on name and on brands; check both.
- `list_mine_paginates` — seed 5 customs, `limit=2 offset=2` returns 2 in expected sort order.
- `list_mine_excludes_quick_add_sentinel` — insert a food directly with `name='__quick_add__'`; assert not in result.
- `count_mine_matches_list_mine_total_independent_of_pagination` — seed 5, `count_mine` returns 5 even with `limit=2`.

**Risks / gotchas.**
- `$2::text IS NULL` is the canonical sqlx-friendly way to make a Postgres parameter optional. Don't refactor to use `match` and two different SQL strings.
- Sort key triple `(created_at DESC, id DESC)` is stable — preserve it. Two custom foods created in the same microsecond won't duplicate or skip rows under pagination.
- The fake repo's substring check must be case-insensitive — production uses `ILIKE`.
- `FoodSearchHit::source` should always be `FoodSource::User` for `list_mine` rows. Easy to forget in the fake.

---

### Task 2: Implement `FoodService::list_mine` + `GET /foods/mine` handler + OpenAPI

**Status:** pending
**Depends on:** T01
**Parallelizable with:** T04, T06, T08, T10 (touches handler files distinct from those tasks)
**Estimated size:** M (3 files, ~200 LOC)
**Suggested model:** sonnet

**Scope.** Add the new service method that validates inputs and composes `list_mine`+`count_mine` into a `Paginated<FoodSearchHit>`. Add the HTTP handler with a route-local `MineQuery` (separate from `PageQuery` because of `q`). Update `openapi.yaml`.

**Context the dev needs.**
- `server/crates/loseit-core/src/service/food.rs` — `FoodService`. New method goes alongside `search` (which is the template).
- `server/crates/loseit-api/src/routes/foods.rs` — handler module. `search` handler at ~line 338 is the closest analogue.
- `server/crates/loseit-api/src/routes/pagination.rs` — `PaginatedResponse<T>`; `From<Paginated<T>>` already adapts.
- `server/crates/loseit-core/src/service/page.rs` — `resolve_page_params` is the source of truth for limit/offset policy. Don't reimplement.
- The existing `FoodSearchHitResponse` (in `routes/foods.rs`) already implements `From<FoodSearchHit>`.

**Spec.**

Service method:

```rust
#[tracing::instrument(skip(self))]
pub async fn list_mine(
    &self,
    owner: Uuid,
    q: Option<&str>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> CoreResult<Paginated<FoodSearchHit>>;
```

Validation:
- Trim `q`; if empty after trim, pass `None` to the repo.
- If `q.is_some() && q.unwrap().trim().chars().count() > 200` → `CoreError::Validation("q must be <= 200 characters".into())`.
- Run `resolve_page_params(limit, offset)?` for the limit/offset policy.

Body: call `self.foods.list_mine(owner, q_opt, page.limit, page.offset).await?` and `self.foods.count_mine(owner, q_opt).await?`, return a `Paginated { results, total, limit: page.limit, offset: page.offset }`.

Route handler (in `routes/foods.rs`):

```rust
#[derive(Deserialize)]
struct MineQuery {
    q: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
}

async fn list_mine(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<MineQuery>,
) -> Result<Json<PaginatedResponse<FoodSearchHitResponse>>, ApiError> {
    let page = state.foods.list_mine(user.id, q.q.as_deref(), q.limit, q.offset).await?;
    Ok(Json(page.into()))
}
```

Wire into `router()` in `routes/foods.rs` (the file already declares static-before-`:id`). Add `.route("/foods/mine", get(list_mine))` immediately after `/foods/frequent` for grouping; static segments take precedence so order is functionally fine but conventionally we keep `/foods/:id` last.

**OpenAPI delta** (merge into `server/specs/openapi.yaml`).

Add new `Paginated` base + `PaginatedFoodSearchHits` schemas to `components.schemas` (these are also consumed by T04 and T06 — if a parallel task added them first, leave intact):

```yaml
    Paginated:
      type: object
      required: [results, total, limit, offset]
      properties:
        results:
          type: array
          description: Replaced by the concrete schema in allOf compositions.
          items: {}
        total:
          type: integer
          format: int64
          description: Total matching rows across all pages.
        limit:
          type: integer
          format: int64
        offset:
          type: integer
          format: int64

    PaginatedFoodSearchHits:
      allOf:
        - $ref: "#/components/schemas/Paginated"
        - type: object
          properties:
            results:
              type: array
              items: { $ref: "#/components/schemas/FoodSearchHit" }
```

Add new path immediately before `/foods/recent`:

```yaml
  /foods/mine:
    get:
      tags: [Foods]
      operationId: list_my_foods
      summary: List the caller's custom foods
      description: |
        Lists `user`-source foods owned by the caller, optionally filtered
        by a case-insensitive substring match against `name` and `brands`.
        The sentinel `__quick_add__` food (used by `POST /log/quick_add`)
        is never returned.

        Default `limit` is 100; server silently clamps requests above 500.
      parameters:
        - in: query
          name: q
          schema: { type: string, maxLength: 200 }
          description: Substring filter; empty/whitespace is treated as absent.
        - in: query
          name: limit
          schema: { type: integer, format: int64, minimum: 0 }
          description: Page size; 0 or omitted → 100.
        - in: query
          name: offset
          schema: { type: integer, format: int64, minimum: 0 }
          description: Page offset, starting at 0.
      responses:
        "200":
          description: Page of the caller's custom foods.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/PaginatedFoodSearchHits" }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
```

**Files to touch.**
- `server/crates/loseit-core/src/service/food.rs` — add `list_mine`.
- `server/crates/loseit-api/src/routes/foods.rs` — add `MineQuery`, `list_mine` handler, route registration.
- `server/specs/openapi.yaml` — add `Paginated`, `PaginatedFoodSearchHits`, `/foods/mine`.

**Acceptance criteria.**
- `GET /api/v1/foods/mine` returns 200 with the documented envelope when authenticated.
- Empty `q` (`?q=`) is treated as no filter (same response as omitting it).
- `q` > 200 chars returns 400 with `code: bad_request`.
- `limit=0` returns 100 rows max.
- `limit=10000` returns at most 500 rows and the response echoes `limit: 500`.
- Sentinel `__quick_add__` rows never appear (test via T07 integration; for now seed one manually).
- Another user's customs never appear.

**Test plan.**
Add to `server/crates/loseit-api/tests/http_foods.rs`:
- `list_mine_returns_paginated_envelope` — seed 3 customs, no params, assert `total: 3, limit: 100, offset: 0`, `results.len() == 3`.
- `list_mine_filters_by_q` — seed "Apple" and "Banana", `?q=apple` returns 1 row.
- `list_mine_rejects_q_over_200_chars` — assert 400.
- `list_mine_silently_clamps_oversized_limit` — `?limit=1000` returns `limit: 500`.
- `list_mine_negative_limit_400` — `?limit=-1` returns 400.
- `list_mine_excludes_other_users` — seed Bob's custom; Alice's request returns 0 rows.

**Risks / gotchas.**
- Define `MineQuery` locally — don't reuse `PageQuery`, which has no `q` field.
- The service must trim `q` before calling the repo; the repo expects either `None` or a non-empty string.
- The OpenAPI `Paginated` base schema is also referenced by T04 and T06. If you ship first, the schema is yours; if you ship after, do not re-define it.

---

### Task 3: Add `list_paginated`/`count_in_range` to `LogRepository` + `LogService::list`

**Status:** pending
**Depends on:** none
**Parallelizable with:** T01, T05, T07, T09, T11, T13
**Estimated size:** M (4 files, ~280 LOC)
**Suggested model:** sonnet

**Scope.** Extend `LogRepository` with paginated list + count methods. Add the service-layer `LogService::list` that delegates to them with `resolve_page_params` validation and the new `from > to` check. Keep the existing `list_in_range` method and `LogService::list_in_range` — `day_summary` and other callers may still want the unbounded variant.

**Context the dev needs.**
- `server/crates/loseit-core/src/repo/log.rs` — `LogRepository` trait.
- `server/crates/loseit-db/src/log_repo.rs` — `PgLogRepository` impl.
- `server/crates/loseit-testing/src/logs.rs` — in-memory fake.
- `server/crates/loseit-core/src/service/log.rs` — `LogService::list_in_range` (line ~223). The new `list` method sits next to it.
- Index `log_user_date_idx` at `server/migrations/0001_initial.sql:236`. No new DDL.

**Spec.**

Trait additions to `LogRepository`:

```rust
async fn list_paginated(
    &self,
    user_id: Uuid,
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: i64,
    offset: i64,
) -> CoreResult<Vec<FoodLogEntry>>;

async fn count_in_range(
    &self,
    user_id: Uuid,
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
) -> CoreResult<i64>;
```

Postgres SQL for `list_paginated`:

```sql
SELECT
    /* all FoodLogEntry columns — copy the existing list_in_range SELECT
       list so the row decode is identical */
    id, user_id, food_id, serving_id, consumed_on, meal,
    quantity, grams_total,
    calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g,
    sodium_mg, saturated_fat_g, note, created_at, updated_at
FROM food_log_entries
WHERE user_id = $1
  AND ($2::date IS NULL OR consumed_on >= $2)
  AND ($3::date IS NULL OR consumed_on <= $3)
ORDER BY consumed_on DESC, created_at DESC, id DESC
LIMIT $4 OFFSET $5;
```

Postgres SQL for `count_in_range`:

```sql
SELECT COUNT(*)::BIGINT
FROM food_log_entries
WHERE user_id = $1
  AND ($2::date IS NULL OR consumed_on >= $2)
  AND ($3::date IS NULL OR consumed_on <= $3);
```

Fake impl: filter `entries.iter().filter(|e| e.user_id == user_id && from.map_or(true, |d| e.consumed_on >= d) && to.map_or(true, |d| e.consumed_on <= d))`, sort by `(consumed_on DESC, created_at DESC, id DESC)`, apply offset/limit.

Service method (add to `LogService` next to `list_in_range`):

```rust
#[tracing::instrument(skip(self))]
pub async fn list(
    &self,
    user: Uuid,
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> CoreResult<Paginated<FoodLogEntry>> {
    if let (Some(f), Some(t)) = (from, to) {
        if f > t {
            return Err(CoreError::Validation("`from` must be <= `to`".into()));
        }
    }
    let page = resolve_page_params(limit, offset)?;
    let results = self.logs.list_paginated(user, from, to, page.limit, page.offset).await?;
    let total = self.logs.count_in_range(user, from, to).await?;
    Ok(Paginated { results, total, limit: page.limit, offset: page.offset })
}
```

Do **not** remove the existing `LogService::list_in_range` or `LogRepository::list_in_range` — `day_summary` uses `list_for_day` separately, but the unbounded `list_in_range` may have other internal callers and is cheap to leave around.

**Files to touch.**
- `server/crates/loseit-core/src/repo/log.rs` — trait additions.
- `server/crates/loseit-db/src/log_repo.rs` — Pg impl.
- `server/crates/loseit-testing/src/logs.rs` — fake impl.
- `server/crates/loseit-core/src/service/log.rs` — `LogService::list`.

**Acceptance criteria.**
- `cargo build` succeeds across `-p loseit-core -p loseit-db -p loseit-testing`.
- Repo trait method signatures match the spec exactly.
- Pg SQL uses `log_user_date_idx`. With `from`/`to` both `None`, the predicate degenerates to `WHERE user_id = $1`.
- Sort triple `(consumed_on DESC, created_at DESC, id DESC)` matches between Pg and fake.
- `LogService::list` returns 400 (`Validation`) on `from > to`.
- Existing `list_in_range` is untouched.

**Test plan.**
- `log_repo::list_paginated_orders_by_consumed_on_then_created_at_then_id` — seed 3 entries on 2 dates, assert the exact order.
- `log_repo::list_paginated_filters_by_from_only` / `_to_only` / `_both` / `_neither`.
- `log_repo::count_in_range_matches_list_paginated_total_without_limit`.
- `log_service::list_returns_400_on_from_after_to`.
- `log_service::list_applies_default_limit_when_omitted` (asserts `limit == 100`).

**Risks / gotchas.**
- Two entries with identical `(consumed_on, created_at)` are possible — the `id DESC` tiebreaker is what keeps pagination stable. Don't drop it.
- The new method is named `list`, not `list_paginated`, on the service — the repo keeps `_paginated` to disambiguate from the legacy method.
- `count_in_range` already exists as a *name* nowhere; you are free to use it.

---

### Task 4: Migrate `GET /log` handler to pagination + OpenAPI

**Status:** pending
**Depends on:** T03
**Parallelizable with:** T02, T06, T08, T10 (touches `routes/log.rs` only)
**Estimated size:** M (3 files including OpenAPI, ~150 LOC of handler churn)
**Suggested model:** sonnet

**Scope.** Replace `GET /log`'s `RangeQuery` (currently *requires* `from`/`to`) with `ListLogQuery` (both optional, plus `limit`/`offset`). Switch the handler to call `LogService::list` and return `PaginatedResponse<LogEntryResponse>`. Update OpenAPI. This is a wire-shape break, accepted because we're pre-v1.

**Context the dev needs.**
- `server/crates/loseit-api/src/routes/log.rs` — `RangeQuery` (line 93), `list` handler (line 249). `LogEntryResponse` already has `From<FoodLogEntry>`.
- `server/crates/loseit-api/src/routes/pagination.rs` — `PaginatedResponse<T>`, `From<Paginated<T>>` blanket impl.
- `server/crates/loseit-api/tests/http_log.rs` — existing tests need to be updated for the new response shape; old assertions on a bare-array response will fail.
- T03 ships `LogService::list`. Use it.

**Spec.**

Replace `RangeQuery` with:

```rust
#[derive(Debug, Deserialize)]
struct ListLogQuery {
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: Option<i64>,
    offset: Option<i64>,
}
```

Rewrite `async fn list`:

```rust
async fn list(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<ListLogQuery>,
) -> Result<Json<PaginatedResponse<LogEntryResponse>>, ApiError> {
    let page = state.logs.list(user.id, q.from, q.to, q.limit, q.offset).await?;
    Ok(Json(page.into()))
}
```

Drop the handler-local `from > to` 400 — `LogService::list` enforces it via `Validation`. Drop the handler-local `sort_by` — the repo's SQL sorts it.

**OpenAPI delta** (modify `/log` GET in `server/specs/openapi.yaml` at the `list_log_entries` operation, ~line 526). Replace the operation with:

```yaml
    get:
      tags: [Log]
      operationId: list_log_entries
      summary: List log entries
      description: |
        Lists the caller's log entries, newest consumed-day first.

        All four query parameters are optional. With no parameters, the
        response is the 100 most-recent entries across the full history.
        `from`/`to` are both inclusive bounds on `consumed_on`. Default
        `limit` is 100; server silently clamps requests above 500.
      parameters:
        - in: query
          name: from
          schema: { type: string, format: date }
          description: Inclusive lower bound on `consumed_on`.
        - in: query
          name: to
          schema: { type: string, format: date }
          description: Inclusive upper bound on `consumed_on`.
        - in: query
          name: limit
          schema: { type: integer, format: int64, minimum: 0 }
          description: Page size; 0 or omitted → 100.
        - in: query
          name: offset
          schema: { type: integer, format: int64, minimum: 0 }
          description: Page offset, starting at 0.
      responses:
        "200":
          description: Page of log entries.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/PaginatedLogEntries" }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
```

Add to `components.schemas` (the `Paginated` base schema may already exist from T02 — if so, leave it alone and only add `PaginatedLogEntries`):

```yaml
    Paginated:
      type: object
      required: [results, total, limit, offset]
      properties:
        results:
          type: array
          description: Replaced by the concrete schema in allOf compositions.
          items: {}
        total:
          type: integer
          format: int64
          description: Total matching rows across all pages.
        limit:
          type: integer
          format: int64
        offset:
          type: integer
          format: int64

    PaginatedLogEntries:
      allOf:
        - $ref: "#/components/schemas/Paginated"
        - type: object
          properties:
            results:
              type: array
              items: { $ref: "#/components/schemas/LogEntry" }
```

**Files to touch.**
- `server/crates/loseit-api/src/routes/log.rs` — replace `RangeQuery`, rewrite `list` handler.
- `server/crates/loseit-api/tests/http_log.rs` — update existing tests to read `body.results` instead of treating the body as a top-level array; add new tests below.
- `server/specs/openapi.yaml` — see above.

**Acceptance criteria.**
- `GET /api/v1/log` (no params) returns 200 with the envelope and at most 100 entries.
- `GET /api/v1/log?from=2024-01-01&to=2024-01-31` works.
- `GET /api/v1/log?to=2024-01-31` works (from-only or to-only valid).
- `GET /api/v1/log?from=2024-02-01&to=2024-01-01` returns 400.
- Existing `tests/http_log.rs` tests pass once they're updated for the new response shape.

**Test plan.**
Add (or update) in `server/crates/loseit-api/tests/http_log.rs`:
- `list_returns_paginated_envelope_with_no_params` — seed 3 entries, request without query, assert `total=3, limit=100, offset=0`.
- `list_paginates_within_full_total` — seed 5, `?limit=2&offset=2` returns 2 results, `total=5`.
- `list_400_when_from_after_to`.
- `list_accepts_from_only` and `list_accepts_to_only`.
- `list_orders_newest_consumed_first_then_newest_created_at`.

**Risks / gotchas.**
- The wire-shape break (bare array → envelope) is intentional. Update every assertion that used `.as_array()`.
- The handler no longer sorts — verify the SQL order matches the previous handler's `sort_by` (newest consumed first, then newest created within a day, then id desc).
- Don't accidentally remove the `Newest consumed first` description text from the OpenAPI summary — keep clients informed of the sort.

---

### Task 5: Replace `WeightRepository::list_for_user` with paginated variant + service

**Status:** pending
**Depends on:** none
**Parallelizable with:** T01, T03, T07, T09, T11, T13
**Estimated size:** M (4 files, ~250 LOC)
**Suggested model:** sonnet

**Scope.** Replace `WeightRepository::list_for_user` (only called from `WeightService::list`) with `list_paginated` + `count_for_user`. Rewrite `WeightService::list` to return `Paginated<Weight>` and enforce `from > to` → 400.

**Context the dev needs.**
- `server/crates/loseit-core/src/repo/weight.rs` — `WeightRepository` trait. `list_for_user` is its sole list method.
- `server/crates/loseit-db/src/weight_repo.rs` — Pg impl.
- `server/crates/loseit-testing/src/weights.rs` — fake.
- `server/crates/loseit-core/src/service/weight.rs` — `WeightService::list` (line 25).
- Index `weights_user_date_idx` at `server/migrations/0001_initial.sql:170`. No new DDL.
- The Weights domain row sort key column is `recorded_on`.

**Spec.**

Trait change to `WeightRepository`: **remove** `list_for_user`, add:

```rust
async fn list_paginated(
    &self,
    user_id: Uuid,
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: i64,
    offset: i64,
) -> CoreResult<Vec<Weight>>;

async fn count_for_user(
    &self,
    user_id: Uuid,
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
) -> CoreResult<i64>;
```

Postgres SQL for `list_paginated`:

```sql
SELECT id, user_id, recorded_on, recorded_at_local, weight_kg, note, created_at
FROM weights
WHERE user_id = $1
  AND ($2::date IS NULL OR recorded_on >= $2)
  AND ($3::date IS NULL OR recorded_on <= $3)
ORDER BY recorded_on DESC, created_at DESC, id DESC
LIMIT $4 OFFSET $5;
```

`count_for_user` SQL mirrors with `SELECT COUNT(*)::BIGINT`. Fake impl: filter + sort + offset/limit. Match the sort triple.

Service rewrite (`WeightService::list`):

```rust
#[tracing::instrument(skip(self))]
pub async fn list(
    &self,
    user_id: Uuid,
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> CoreResult<Paginated<Weight>> {
    if let (Some(f), Some(t)) = (from, to) {
        if f > t {
            return Err(CoreError::Validation("`from` must be <= `to`".into()));
        }
    }
    let page = resolve_page_params(limit, offset)?;
    let results = self.weights.list_paginated(user_id, from, to, page.limit, page.offset).await?;
    let total = self.weights.count_for_user(user_id, from, to).await?;
    Ok(Paginated { results, total, limit: page.limit, offset: page.offset })
}
```

**Files to touch.**
- `server/crates/loseit-core/src/repo/weight.rs` — trait changes.
- `server/crates/loseit-db/src/weight_repo.rs` — Pg impl, deleting the old `list_for_user` impl.
- `server/crates/loseit-testing/src/weights.rs` — fake.
- `server/crates/loseit-core/src/service/weight.rs` — `WeightService::list` rewrite.

**Acceptance criteria.**
- `cargo build` succeeds (T06 will catch the handler call-site mismatch — leave that for T06).
- No callers of `list_for_user` remain in `loseit-core`, `loseit-db`, or `loseit-testing` (the route handler in `loseit-api` will be updated in T06).
- Sort triple matches between Pg and fake.

**Test plan.**
- `weight_repo::list_paginated_orders_newest_first_with_id_tiebreaker`.
- `weight_repo::count_for_user_matches_list_total`.
- `weight_service::list_400_when_from_after_to`.
- `weight_service::list_applies_default_limit`.

**Risks / gotchas.**
- This breaks `routes/weights.rs::list` compilation — T06 is the follow-up. If T05 lands first and T06 isn't ready, the workspace won't build. Sequence them.
- The new `from > to` check is a behaviour change (the old endpoint silently accepted reversed ranges). Document in T06's OpenAPI delta.

---

### Task 6: Migrate `GET /weights` handler to pagination + OpenAPI

**Status:** pending
**Depends on:** T05
**Parallelizable with:** T02, T04, T08, T10 (touches `routes/weights.rs` only)
**Estimated size:** M (3 files, ~150 LOC)
**Suggested model:** sonnet

**Scope.** Update `routes/weights.rs::list` for the new service signature. Add a new HTTP test file (none exists today).

**Context the dev needs.**
- `server/crates/loseit-api/src/routes/weights.rs` — `ListQuery` (line 29) and `list` handler (line 73).
- `WeightService::list` now returns `Paginated<Weight>` after T05.
- `server/crates/loseit-api/src/routes/pagination.rs` — `PaginatedResponse<T>`.

**Spec.**

Replace `ListQuery` with:

```rust
#[derive(Deserialize)]
struct ListQuery {
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: Option<i64>,
    offset: Option<i64>,
}
```

Rewrite `list`:

```rust
async fn list(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<ListQuery>,
) -> Result<Json<PaginatedResponse<WeightResponse>>, ApiError> {
    let page = state.weights.list(user.id, q.from, q.to, q.limit, q.offset).await?;
    Ok(Json(page.into()))
}
```

**OpenAPI delta**. Replace `/weights` GET operation (`list_weights`, ~line 128):

```yaml
    get:
      tags: [Weights]
      operationId: list_weights
      summary: List weight entries
      description: |
        Lists the caller's weight entries, newest recorded-day first.

        All four query parameters are optional. With no parameters, the
        response is the 100 most-recent entries across the full history.
        Default `limit` is 100; server silently clamps requests above 500.
      parameters:
        - in: query
          name: from
          schema: { type: string, format: date }
          description: Inclusive lower bound on `recorded_on`.
        - in: query
          name: to
          schema: { type: string, format: date }
          description: Inclusive upper bound on `recorded_on`.
        - in: query
          name: limit
          schema: { type: integer, format: int64, minimum: 0 }
          description: Page size; 0 or omitted → 100.
        - in: query
          name: offset
          schema: { type: integer, format: int64, minimum: 0 }
          description: Page offset, starting at 0.
      responses:
        "200":
          description: Page of weight entries.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/PaginatedWeights" }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
```

Add to `components.schemas` (the `Paginated` base schema may already exist from T02 or T04 — leave it alone if so):

```yaml
    PaginatedWeights:
      allOf:
        - $ref: "#/components/schemas/Paginated"
        - type: object
          properties:
            results:
              type: array
              items: { $ref: "#/components/schemas/Weight" }
```

**Files to touch.**
- `server/crates/loseit-api/src/routes/weights.rs` — handler + query changes.
- `server/crates/loseit-api/tests/http_weights.rs` — new file (see test plan).
- `server/specs/openapi.yaml` — see above.

**Acceptance criteria.**
- `GET /api/v1/weights` returns 200 with `PaginatedResponse<WeightResponse>` envelope.
- `?from=2024-02-01&to=2024-01-01` returns 400 (this is new — the old endpoint silently returned an empty array).
- Default limit is 100; clamp at 500.

**Test plan.**
Create `server/crates/loseit-api/tests/http_weights.rs` (use `tests/http_log.rs` as the template for the auth-wired setup):
- `list_weights_returns_paginated_envelope`.
- `list_weights_filters_by_from_and_to_inclusive`.
- `list_weights_400_when_from_after_to`.
- `list_weights_paginates`.

**Risks / gotchas.**
- `recorded_at_local` field stays in the response — it has nothing to do with pagination.
- New test file means adding a `build_test_app` helper. Look at the helper in `tests/http_foods.rs` — copying it is preferable to reusing across files since the fake-repo wiring is shared.

---

### Task 7: Migration 0005, `find_or_create_quick_add`, sentinel filters, reserved-name guard

**Status:** pending
**Depends on:** none (filters in T01's `list_mine` SQL already include `name <> '__quick_add__'`; this task adds the same filter to `search`, `recent`, `frequent`)
**Parallelizable with:** T03, T05, T09, T11, T13 (different modules)
**Estimated size:** L (5 files, ~350 LOC)
**Suggested model:** opus (touches concurrency, partial unique index, and several existing SQL statements)

**Scope.** Everything needed to make the per-user quick-add sentinel food real *except* the `POST /log/quick_add` endpoint itself: migration, repo provisioning method, filter additions to existing food-list SQL, and a "reserved name" guard in `FoodService::create_custom`. T08 builds the endpoint on top.

**Context the dev needs.**
- `server/migrations/` — existing files numbered 0001–0004. Next is 0005.
- `server/crates/loseit-core/src/repo/food.rs` — `FoodRepository` trait.
- `server/crates/loseit-db/src/food_repo.rs` — Pg impl. The `search` SQL is around line 149; `search_count` around line 249.
- `server/crates/loseit-testing/src/foods.rs` — fake. Mirror the SQL filter logic.
- `server/crates/loseit-core/src/repo/log.rs` — `recent_food_ids` and `frequent_food_ids` traits.
- `server/crates/loseit-db/src/log_repo.rs` — Pg impls of the same.
- `server/crates/loseit-core/src/service/food.rs` — `create_custom` (line 105), `update_custom`, `delete_custom`. Add the reserved-name + sentinel-protect guards.

**Spec.**

**1. Migration `server/migrations/0005_quick_add_sentinel.sql`** (verbatim):

```sql
-- Per-user singleton for the /log/quick_add sentinel food. Allows
-- INSERT … ON CONFLICT to be the idempotent provisioning path.
CREATE UNIQUE INDEX foods_quick_add_singleton
  ON foods(owner_user_id)
  WHERE source = 'user' AND name = '__quick_add__';
```

**2. New repo trait method on `FoodRepository`:**

```rust
/// Idempotently provision the per-user quick-add sentinel food. Returns
/// the food plus its synthetic 100 g default serving (label `"kcal"`,
/// source `system`). Safe under concurrent first-uses thanks to the
/// `foods_quick_add_singleton` partial unique index.
async fn find_or_create_quick_add(
    &self,
    owner: Uuid,
) -> CoreResult<(Food, Serving)>;
```

Pg impl: one transaction.

```sql
-- Step 1: upsert the sentinel food.
INSERT INTO foods (
    source, owner_user_id, name, energy_kcal_100g,
    -- All other nutrition columns null. categories_tags = ARRAY[]::text[].
    -- quality_score = 0. nutriscore_grade null.
    quality_score, categories_tags
)
VALUES ('user', $1, '__quick_add__', 1, 0, ARRAY[]::text[])
ON CONFLICT ON CONSTRAINT foods_quick_add_singleton
  DO UPDATE SET updated_at = now()
RETURNING /* all Food columns */;

-- Step 2: ensure the default serving exists. Use a similar idempotent insert
-- against `servings_one_default_per_food` (existing partial unique index).
INSERT INTO servings (food_id, label, grams, is_default, source, sort_order)
VALUES ($food_id, 'kcal', 100, true, 'system', 0)
ON CONFLICT ON CONSTRAINT servings_one_default_per_food
  DO UPDATE SET updated_at = now()
RETURNING /* all Serving columns */;
```

(The two-step upsert is required because `servings` doesn't have a unique constraint on `(food_id, label)` — only the `is_default` partial. If the food was just created, the serving doesn't exist yet, so the insert succeeds. If the food existed already (returning user), the existing default serving is the one whose insert hits the partial unique constraint and gets updated. Sentinel encoding: `energy_kcal_100g = 1`, default serving `grams = 100`, `label = "kcal"`. Quick-add of `N` kcal then logs `quantity = N`, `grams_total = N * 100`, and `compute_snapshot` yields exactly `N` kcal with all macros null.)

Fake impl: check `foods.iter().find(|f| f.owner_user_id == Some(owner) && f.name == "__quick_add__")`; if missing, push one with the sentinel encoding above and push a matching default serving; return both.

**3. Sentinel filters in existing SQL (and the fake equivalents):**

- `PgFoodRepository::search` SQL: add `AND f.name <> '__quick_add__'` to the existing `WHERE`.
- `PgFoodRepository::search_count` SQL: same addition.
- `PgLogRepository::recent_food_ids` SQL: in the JOIN to `foods`, add `AND foods.name <> '__quick_add__'` so sentinel ids never come back.
- `PgLogRepository::frequent_food_ids` SQL: same.
- Mirror each in `loseit-testing`.

(`list_mine`/`count_mine` from T01 already include this filter. `/foods/:id` is intentionally *not* filtered — undocumented and unreachable by a normal client.)

**4. Reserved-name + sentinel-protect guards in `FoodService`:**

In `create_custom`, after the `name.trim().is_empty()` check, add:

```rust
if draft.name.trim() == "__quick_add__" {
    return Err(CoreError::Validation("name is reserved".into()));
}
```

In `update_custom`, after the `find_by_id` + OFF check, add:

```rust
if food.name == "__quick_add__" {
    return Err(CoreError::Forbidden);
}
```

In `delete_custom`, same Forbidden check on the sentinel name.

**Files to touch.**
- `server/migrations/0005_quick_add_sentinel.sql` — new.
- `server/crates/loseit-core/src/repo/food.rs` — trait addition.
- `server/crates/loseit-db/src/food_repo.rs` — Pg impl + filters in `search`/`search_count`.
- `server/crates/loseit-db/src/log_repo.rs` — filters in `recent_food_ids`/`frequent_food_ids`.
- `server/crates/loseit-testing/src/foods.rs` — fake `find_or_create_quick_add` + search filters.
- `server/crates/loseit-testing/src/logs.rs` — fake filters in recent/frequent.
- `server/crates/loseit-core/src/service/food.rs` — three service guards.

(Seven files. The migration and the repo trait file are atomic counts — count this as "two new modules + filter changes" rather than separate seven-file tasks.)

**Acceptance criteria.**
- Migration runs cleanly against a fresh DB (sqlx-migrate idempotency).
- Calling `find_or_create_quick_add(owner)` twice in a row returns the same `food.id` and `serving.id`.
- Concurrent first-uses (verify with a test that spawns two tasks) both succeed and return the same row.
- `GET /foods/search?q=quick` does not return the sentinel even when one exists.
- `GET /foods/recent` and `GET /foods/frequent` do not surface the sentinel even when the user has logged via quick-add.
- `POST /foods { "name": "__quick_add__" }` returns 400 with message `"name is reserved"`.
- `PATCH /foods/:id` on the sentinel returns 403; `DELETE /foods/:id` on it returns 403.

**Test plan.**
- `food_repo::find_or_create_quick_add_is_idempotent` (Pg integration test if you have a test DB, otherwise just on the fake).
- `food_repo::find_or_create_quick_add_concurrent_first_uses_dont_duplicate` (spawn two `tokio::spawn` calls).
- `food_repo::search_excludes_quick_add_sentinel`.
- `food_service::create_custom_rejects_reserved_name_400`.
- `food_service::update_custom_on_sentinel_returns_forbidden_403`.
- `food_service::delete_custom_on_sentinel_returns_forbidden_403`.

**Risks / gotchas.**
- The partial unique index name `foods_quick_add_singleton` is referenced by the `ON CONFLICT ON CONSTRAINT` clause — keep them in sync.
- The sentinel food's `categories_tags` must be `ARRAY[]::text[]`, not `NULL` — schema requires a value.
- A user who *already* created a custom called `__quick_add__` before this migration ships would be the only way the migration could fail. Document the migration order; existing users on dev DBs may need a manual cleanup if anyone exploited the gap. Production data is empty so this is theoretical.
- The "Forbidden" returned for sentinel patch/delete is the same status as for read-only OFF — clients can't distinguish, which is fine.

---

### Task 8: `LogService::quick_add` + `POST /log/quick_add` handler + OpenAPI

**Status:** pending
**Depends on:** T07
**Parallelizable with:** T02, T04, T06, T10
**Estimated size:** M (3 files, ~250 LOC)
**Suggested model:** sonnet

**Scope.** Add `LogService::quick_add` (provisions the sentinel via T07's repo method, then composes the standard `create` path so the snapshot is just-calories). Add the handler and route. Update OpenAPI.

**Context the dev needs.**
- `server/crates/loseit-core/src/service/log.rs` — `LogService`, the existing `create` method (line 100), and `compute_snapshot` (line 70).
- `server/crates/loseit-api/src/routes/log.rs` — `router()` (line 39), `CreateLogBody`, `LogEntryResponse`.
- T07 ships `FoodRepository::find_or_create_quick_add`. Use it.
- `server/crates/loseit-core/src/domain/log_entry.rs` — `PersistedLogEntry`.
- `service/log.rs:124` has the `grams_total >= 10^8` overflow guard. Quick-add must enforce the same.

**Spec.**

Service method:

```rust
#[tracing::instrument(skip(self))]
pub async fn quick_add(
    &self,
    user: Uuid,
    calories_kcal: Decimal,
    meal: Meal,
    consumed_on: NaiveDate,
    note: Option<String>,
) -> CoreResult<FoodLogEntry> {
    // Validation: must be strictly positive, < 100_000.
    if calories_kcal <= Decimal::ZERO {
        return Err(CoreError::Validation("calories_kcal must be positive".into()));
    }
    if calories_kcal >= Decimal::from(100_000) {
        return Err(CoreError::Validation("calories_kcal exceeds maximum allowed value".into()));
    }

    // Provision sentinel (idempotent) → reuse standard create path.
    let (food, serving) = self.foods.find_or_create_quick_add(user).await?;

    // grams_total = calories_kcal * 100  (sentinel has 1 kcal / 100 g,
    // serving.grams = 100, so quantity = calories_kcal). Pad to NUMERIC(10,2).
    let quantity = calories_kcal;
    let grams_total = to_numeric_8_2(serving.grams * quantity);
    if grams_total >= Decimal::new(100_000_000, 2) {
        return Err(CoreError::Validation("grams_total exceeds maximum allowed value".into()));
    }
    let snapshot = Self::compute_snapshot(&food, grams_total);

    let persisted = PersistedLogEntry {
        food_id: food.id,
        serving_id: Some(serving.id),
        consumed_on,
        meal,
        quantity,
        grams_total,
        snapshot,
        note,
    };
    self.logs.create(user, &persisted).await
}
```

(`to_numeric_8_2` is the existing private helper in `service/log.rs` — keep it private and reuse, or expose to a `pub(crate)` if needed.)

Handler in `routes/log.rs`:

```rust
#[derive(Debug, Deserialize)]
struct QuickAddBody {
    calories_kcal: Decimal,
    meal: String,
    consumed_on: NaiveDate,
    #[serde(default)]
    note: Option<String>,
}

async fn quick_add(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<QuickAddBody>,
) -> Result<(StatusCode, Json<LogEntryResponse>), ApiError> {
    let meal = parse_meal(&body.meal)?;
    let entry = state
        .logs
        .quick_add(user.id, body.calories_kcal, meal, body.consumed_on, body.note)
        .await?;
    Ok((StatusCode::CREATED, Json(entry.into())))
}
```

Register: in `router()` add `.route("/log/quick_add", post(quick_add))` before the catch-all `/log/:id`.

**OpenAPI delta**. New path:

```yaml
  /log/quick_add:
    post:
      tags: [Log]
      operationId: quick_add_log_entry
      summary: Log raw calories without choosing a food
      description: |
        Creates a log entry against a per-user sentinel "Quick Add" food
        owned by the caller. Only `calories_kcal` carries a value; all
        macronutrient fields on the returned snapshot are null. The
        sentinel food is hidden from `/foods/search`, `/foods/mine`,
        `/foods/recent`, and `/foods/frequent`. It is auto-provisioned on
        first use.
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/QuickAddBody" }
      responses:
        "201":
          description: Created. The response includes a frozen snapshot with macros null.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/LogEntry" }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
```

New schema:

```yaml
    QuickAddBody:
      type: object
      required: [calories_kcal, meal, consumed_on]
      properties:
        calories_kcal:
          allOf:
            - $ref: "#/components/schemas/Decimal"
          description: Must be > 0 and < 100000.
        meal: { $ref: "#/components/schemas/Meal" }
        consumed_on: { type: string, format: date }
        note: { type: string }
```

Also amend the `FoodCreate` schema description (around line 929 in `openapi.yaml`) to note that `name: "__quick_add__"` is reserved and returns 400.

**Files to touch.**
- `server/crates/loseit-core/src/service/log.rs` — add `quick_add`.
- `server/crates/loseit-api/src/routes/log.rs` — add `QuickAddBody`, `quick_add` handler, route registration.
- `server/specs/openapi.yaml` — new path, new schema, `FoodCreate` description amendment.

**Acceptance criteria.**
- `POST /log/quick_add { "calories_kcal": 250, "meal": "snack", "consumed_on": "2024-01-15" }` returns 201 with a `LogEntry` whose `calories_kcal` is `"250.00"`, `quantity` is `"250"`, `grams_total` is `"25000.00"`, and all macro fields are null.
- Second call returns 201 with a *different* `id` but the same `food_id` (proves sentinel reuse).
- `calories_kcal <= 0` returns 400.
- `calories_kcal >= 100000` returns 400.
- `meal` not in {breakfast, lunch, dinner, snack} returns 400.

**Test plan.**
Add to `tests/http_log.rs`:
- `quick_add_creates_entry_with_only_calories`.
- `quick_add_is_repeatable_for_same_user`.
- `quick_add_400_on_zero_calories`.
- `quick_add_400_on_negative_calories`.
- `quick_add_400_on_max_calories_overflow` (try 200_000).
- `quick_add_does_not_appear_in_food_search` (do a quick_add, then `GET /foods/search?q=quick` returns empty).

**Risks / gotchas.**
- The snapshot must have all macros null — `compute_snapshot` does this naturally because the sentinel food's nutrition is `None` for everything except `energy_kcal`. Don't add a special-case constructor.
- Don't reuse `LogService::create` directly — quick-add wants to bypass the user-visibility check on the sentinel food (which would succeed but is unnecessary work) and avoid leaking the sentinel's `food_id` as a usable `LogDraft.food_id`. The duplicated 6-line "compute snapshot + insert" block is intentional.
- `quantity` is stored as `NUMERIC(8,3)` — for `calories_kcal = 250`, this becomes `250.000` and `grams_total = 25000.00`. Confirm in tests via string equality.

---

### Task 9: Add `LogRepository::create_many` (trait, Pg via UNNEST, fake)

**Status:** pending
**Depends on:** none
**Parallelizable with:** T01, T03, T05, T07, T11, T13
**Estimated size:** M (3 files, ~250 LOC)
**Suggested model:** sonnet

**Scope.** Add a bulk-insert method to `LogRepository` so `POST /log/copy` can persist N entries in one transaction. Use the `UNNEST` array pattern from `PgFoodRepository::upsert_off_batch` as the template. No service or handler wiring in this task.

**Context the dev needs.**
- `server/crates/loseit-core/src/repo/log.rs` — trait.
- `server/crates/loseit-db/src/log_repo.rs` — existing `create` impl (the single-row INSERT) is the row-decode template.
- `server/crates/loseit-db/src/food_repo.rs` — `upsert_off_batch` (search for `UNNEST` in that file) is the bulk-insert template.
- `server/crates/loseit-testing/src/logs.rs` — fake.
- `server/crates/loseit-core/src/domain/log_entry.rs` — `PersistedLogEntry`.

**Spec.**

Trait addition:

```rust
/// Bulk-insert log entries in a single transaction. Returns the inserted
/// rows in the same order as the input slice. All-or-nothing: any DB
/// failure rolls back every insert.
async fn create_many(
    &self,
    user_id: Uuid,
    entries: &[PersistedLogEntry],
) -> CoreResult<Vec<FoodLogEntry>>;
```

Pg impl: single `INSERT … RETURNING …` using `UNNEST` over per-column arrays. Mirror the array-packing pattern in `food_repo.rs`'s `upsert_off_batch`.

```sql
INSERT INTO food_log_entries (
    user_id, food_id, serving_id, consumed_on, meal,
    quantity, grams_total,
    calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g,
    note
)
SELECT
    $1, /* user_id (scalar, fanned out per row) */
    food_id, serving_id, consumed_on, meal,
    quantity, grams_total,
    calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g,
    note
FROM UNNEST(
    $2::uuid[],           -- food_id
    $3::uuid[],           -- serving_id (NULLable)
    $4::date[],           -- consumed_on
    $5::text[],           -- meal
    $6::numeric[],        -- quantity
    $7::numeric[],        -- grams_total
    $8::numeric[],        -- calories_kcal
    $9::numeric[],        -- protein_g (NULLable)
    $10::numeric[],
    $11::numeric[],
    $12::numeric[],
    $13::numeric[],
    $14::numeric[],
    $15::numeric[],
    $16::text[]
) AS x(food_id, serving_id, consumed_on, meal,
       quantity, grams_total,
       calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g,
       note)
RETURNING
    id, user_id, food_id, serving_id, consumed_on, meal,
    quantity, grams_total,
    calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g,
    note, created_at, updated_at;
```

Wrap in a `sqlx::Transaction` (`pool.begin()` → execute → commit). The `RETURNING` order should match the input order — Postgres preserves array order under `UNNEST`. The function returns `Vec<FoodLogEntry>`.

Empty input: short-circuit with `Ok(vec![])` *before* the SQL — `UNNEST(ARRAY[]::uuid[], ...)` is fine but the early return is cleaner.

Fake impl: take the lock, push each in order, return cloned copies. Use the existing single-row insert helper if one exists.

**Files to touch.**
- `server/crates/loseit-core/src/repo/log.rs` — trait method.
- `server/crates/loseit-db/src/log_repo.rs` — Pg impl.
- `server/crates/loseit-testing/src/logs.rs` — fake impl.

**Acceptance criteria.**
- Inserting 3 entries returns 3 `FoodLogEntry` rows whose `food_id`/`serving_id`/etc. match the input.
- Inserting 0 entries returns an empty Vec without hitting the DB.
- A simulated DB failure on row 2 rolls back rows 1 and 3.
- Pg `RETURNING` order matches input order (test by giving distinct `consumed_on` values).

**Test plan.**
- `log_repo::create_many_inserts_in_input_order`.
- `log_repo::create_many_with_empty_input_returns_empty_vec_without_sql`.
- `log_repo::create_many_is_atomic` (use a `WeightDraft` with invalid quantity that violates the CHECK constraint mid-batch — verify nothing committed).

**Risks / gotchas.**
- sqlx requires explicit `::numeric[]` and `::uuid[]` casts when the array is empty or all-null.
- `serving_id` is nullable — use `Vec<Option<Uuid>>` and let sqlx encode it.
- Don't forget `Vec<Option<...>>` for every nullable macro column.
- `RETURNING` returns rows in insertion order for `UNNEST`-driven inserts, but verify with a deliberate test — if Postgres ever changes this we'd want to know.

---

### Task 10: `LogService::copy_day` + `POST /log/copy` handler + OpenAPI

**Status:** pending
**Depends on:** T09
**Parallelizable with:** T02, T04, T06, T08
**Estimated size:** M (3 files, ~300 LOC)
**Suggested model:** opus (re-snapshotting logic + skip semantics need judgement)

**Scope.** Service method + handler that copies one day's entries to another, re-snapshotting each from the *current* food (so a custom-food edit between dates does not bleed through). Update OpenAPI.

**Context the dev needs.**
- `server/crates/loseit-core/src/service/log.rs` — `LogService`, `compute_snapshot` (line 70), `to_numeric_8_2` helper.
- `server/crates/loseit-core/src/repo/log.rs` — `list_for_day` returns the source-day entries. `create_many` from T09 is the persist step.
- `server/crates/loseit-core/src/repo/food.rs` — `find_by_id(viewer, id)` for re-resolving food.
- `server/crates/loseit-core/src/repo/serving.rs` — `find_by_id(id)` for re-resolving serving.
- `server/crates/loseit-api/src/routes/log.rs` — `parse_meal` helper.

**Spec.**

Service method:

```rust
#[tracing::instrument(skip(self))]
pub async fn copy_day(
    &self,
    user: Uuid,
    from_date: NaiveDate,
    to_date: NaiveDate,
    meal: Option<Meal>,
) -> CoreResult<Vec<FoodLogEntry>> {
    let source = self.logs.list_for_day(user, from_date).await?;
    // Optional meal filter.
    let candidates: Vec<&FoodLogEntry> = source
        .iter()
        .filter(|e| meal.map_or(true, |m| e.meal == m))
        .collect();

    let mut persisted = Vec::with_capacity(candidates.len());
    for e in candidates {
        // Re-resolve food (skip if no longer visible / deleted).
        let Some(food) = self.foods.find_by_id(user, e.food_id).await? else {
            tracing::info!(entry_id = %e.id, "copy_day: skipping entry — food not visible");
            continue;
        };
        // Re-resolve serving (skip if deleted).
        let serving_id = match e.serving_id {
            Some(id) => id,
            None => {
                tracing::info!(entry_id = %e.id, "copy_day: skipping entry — no serving");
                continue;
            }
        };
        let Some(serving) = self.servings.find_by_id(serving_id).await? else {
            tracing::info!(entry_id = %e.id, "copy_day: skipping entry — serving deleted");
            continue;
        };
        if serving.food_id != food.id {
            // Defensive: serving moved foods? Skip rather than mis-snapshot.
            continue;
        }
        let grams_total = to_numeric_8_2(serving.grams * e.quantity);
        if grams_total >= Decimal::new(100_000_000, 2) {
            // Skip — same overflow rule as create.
            continue;
        }
        let snapshot = Self::compute_snapshot(&food, grams_total);
        persisted.push(PersistedLogEntry {
            food_id: food.id,
            serving_id: Some(serving.id),
            consumed_on: to_date,
            meal: e.meal,
            quantity: e.quantity,
            grams_total,
            snapshot,
            note: e.note.clone(),
        });
    }

    self.logs.create_many(user, &persisted).await
}
```

Note: `from_date == to_date` is allowed; `from_date > to_date` is allowed (backward copy is legitimate). Do not add a `from > to` check.

Handler in `routes/log.rs`:

```rust
#[derive(Debug, Deserialize)]
struct CopyDayBody {
    from_date: NaiveDate,
    to_date: NaiveDate,
    #[serde(default)]
    meal: Option<String>,
}

#[derive(Serialize)]
struct CopyDayResponse {
    copied: Vec<LogEntryResponse>,
}

async fn copy_day(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<CopyDayBody>,
) -> Result<(StatusCode, Json<CopyDayResponse>), ApiError> {
    let meal = body.meal.as_deref().map(parse_meal).transpose()?;
    let copied = state
        .logs
        .copy_day(user.id, body.from_date, body.to_date, meal)
        .await?;
    Ok((
        StatusCode::CREATED,
        Json(CopyDayResponse {
            copied: copied.into_iter().map(Into::into).collect(),
        }),
    ))
}
```

Register: `.route("/log/copy", post(copy_day))` in `router()` before `/log/:id`.

**OpenAPI delta**. New path:

```yaml
  /log/copy:
    post:
      tags: [Log]
      operationId: copy_log_day
      summary: Copy a day's log entries to another day
      description: |
        Re-snapshots every entry in `from_date` (optionally filtered by
        `meal`) onto `to_date`. Snapshots are recomputed from the *current*
        food, so edits to a custom food between the two dates are
        reflected in the copied entries.

        Entries whose food is no longer visible to the caller, or whose
        serving has been deleted, are silently skipped. `from_date ==
        to_date` and `from_date > to_date` (backward copy) are both
        permitted. If `to_date` already has entries, they coexist with the
        new ones — nothing is replaced.

        The response is wrapped (`{ copied: [...] }`) rather than a bare
        array so future fields (e.g. `skipped`) can be added without
        breaking the wire shape.
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/CopyDayBody" }
      responses:
        "201":
          description: Created. Body contains the inserted entries, in input order.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/CopyDayResponse" }
        "400": { $ref: "#/components/responses/BadRequest" }
        "401": { $ref: "#/components/responses/Unauthorized" }
```

New schemas:

```yaml
    CopyDayBody:
      type: object
      required: [from_date, to_date]
      properties:
        from_date: { type: string, format: date }
        to_date: { type: string, format: date }
        meal:
          oneOf:
            - $ref: "#/components/schemas/Meal"
            - type: "null"
          description: If present, only entries with this meal are copied.

    CopyDayResponse:
      type: object
      required: [copied]
      properties:
        copied:
          type: array
          items: { $ref: "#/components/schemas/LogEntry" }
```

**Files to touch.**
- `server/crates/loseit-core/src/service/log.rs` — add `copy_day`.
- `server/crates/loseit-api/src/routes/log.rs` — add `CopyDayBody`, `CopyDayResponse`, `copy_day` handler, route registration.
- `server/specs/openapi.yaml` — new path, two new schemas.

**Acceptance criteria.**
- Copying a day with 3 entries returns 201 with `copied` of length 3.
- `from_date == to_date` succeeds (entries get duplicated onto the same day).
- `from_date > to_date` succeeds.
- An empty source day returns 201 with `copied: []`.
- A custom-food edit between dates is reflected — the *new* nutrition is in the copied snapshot, not the source entry's frozen snapshot.
- Deleted-serving entries are skipped silently and don't appear in the response.
- Quick-add sentinel entries copy successfully and yield the same calories.
- Atomic-ity: if `create_many` rolls back, no entries are committed (test by injecting a failure on the second batch row — requires a Mockable wrapper or a Pg-side CHECK violation).

**Test plan.**
Add to `tests/http_log.rs`:
- `copy_day_recomputes_snapshot_from_current_food_not_source_snapshot` — seed Alice's custom with 50 kcal/100g, log it on day 1 (snapshot frozen at 50), edit the custom to 100 kcal/100g, copy day 1 → day 2, assert day-2 snapshot uses 100.
- `copy_day_filters_by_meal`.
- `copy_day_allows_same_day_copy_duplicating_entries`.
- `copy_day_allows_backward_copy`.
- `copy_day_skips_entries_with_deleted_serving`.
- `copy_day_response_includes_only_inserted_entries`.

**Risks / gotchas.**
- The re-snapshot decision is the entire reason copy_day is a server endpoint and not a client loop. Do **not** copy `e.snapshot` straight through; always recompute.
- Skips should be logged at `tracing::info` so production has a paper trail; the response doesn't expose them in v1 (future-proofed by the wrapped envelope).
- `serving.food_id != food.id` is a paranoid check — shouldn't happen normally but means a serving has been reparented somehow. Skip rather than 500.
- The `meal` filter parses *after* unwrap; if the client sends an unknown meal we want a clean 400, not a silent no-op.

---

### Task 11: JWKS authenticator + `AuthConfig::Jwks` extension + wiring

**Status:** pending
**Depends on:** none
**Parallelizable with:** T01, T03, T05, T07, T09, T13
**Estimated size:** L (5 files, ~600 LOC)
**Suggested model:** opus (concurrency cache + token validation specifics)

**Scope.** Replace the placeholder `AuthConfig::Jwks` branch in `build_authenticator` with a real JWKS-backed `Authenticator` implementation. Provider-agnostic — configured by `(issuer, audience, jwks_url, cache_ttl)`. Adds `jsonwebtoken` and `reqwest` to the workspace deps. Adds `wiremock` to dev-deps.

**Context the dev needs.**
- `server/crates/loseit-api/src/auth/dev.rs` — sibling implementation pattern.
- `server/crates/loseit-api/src/auth/mod.rs` — `require_auth` middleware; the seam is `state.authenticator.authenticate(token)`.
- `server/crates/loseit-api/src/server.rs` — `build_authenticator` (line 136), `build_state` (line 88). The placeholder `AuthConfig::Jwks { .. }` branch is at line 158.
- `server/crates/loseit-api/src/config.rs` — `AuthConfig::Jwks { issuer, jwks_url }` (line 29) and `load_auth` (line 56).
- `server/crates/loseit-core/src/auth.rs` — `Authenticator` trait, `AuthError`.
- `server/crates/loseit-core/src/domain/user.rs` — `UserIdentity` struct.
- `server/crates/loseit-api/src/error.rs` — `AuthError::Upstream → 503` mapping is already wired (line 86).
- `server/Cargo.toml` — workspace deps. Add new entries under `[workspace.dependencies]`.

**Spec.**

**Dependencies.** Add to `server/Cargo.toml`:

```toml
jsonwebtoken = "9"
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "json"] }
```

Add to `server/crates/loseit-api/Cargo.toml` under `[dependencies]`:

```toml
jsonwebtoken = { workspace = true }
reqwest = { workspace = true }
```

Add to `server/crates/loseit-api/Cargo.toml` under `[dev-dependencies]`:

```toml
wiremock = "0.6"
rsa = { version = "0.9", features = ["pem"] }
rand = "0.8"
```

**Config extension** in `server/crates/loseit-api/src/config.rs`:

```rust
AuthConfig::Jwks {
    issuer: String,
    audience: String,          // new
    jwks_url: String,
    cache_ttl_secs: u64,       // new; default 600
}
```

In `load_auth`, also load:
- `OIDC_AUDIENCE` (required, returns Err if missing).
- `OIDC_JWKS_CACHE_TTL_SECS` (optional, default `"600"`, parsed as `u64`).

**New module** `server/crates/loseit-api/src/auth/jwks.rs`. Public surface:

```rust
pub struct JwksAuthenticator {
    issuer: String,
    audience: String,
    jwks_url: String,
    cache_ttl: Duration,
    cache: Arc<RwLock<JwksCacheState>>,
    refresh_lock: Arc<Mutex<()>>,
    http: reqwest::Client,
}

struct JwksCacheState {
    keys: HashMap<String, DecodingKey>,    // keyed by `kid`
    fetched_at: Option<Instant>,
}

impl JwksAuthenticator {
    pub async fn new(
        issuer: String,
        audience: String,
        jwks_url: String,
        cache_ttl: Duration,
    ) -> anyhow::Result<Self> { /* warm the cache via an initial fetch */ }
}

#[async_trait]
impl Authenticator for JwksAuthenticator {
    async fn authenticate(&self, token: &str) -> Result<UserIdentity, AuthError> { /* see below */ }
}
```

**Per-request algorithm:**

1. `jsonwebtoken::decode_header(token)` to read `kid` and `alg`.
   - No `kid` → `AuthError::Invalid`.
   - `alg` not in whitelist (`RS256, RS384, RS512, ES256, ES384`) → `AuthError::Invalid`.
2. Look up `kid` in `cache.read().keys`. If hit → use the `DecodingKey`.
3. On miss or `fetched_at.elapsed() > cache_ttl`:
   - Acquire `refresh_lock` (so only one concurrent refresh occurs).
   - Re-check the cache *after* the lock — a peer may have already refreshed.
   - If still missing/stale, `http.get(jwks_url).send().await?.json::<JwksDocument>().await?`. On any error → `AuthError::Upstream("jwks fetch: {e}".into())`.
   - Parse: only keys with `"use": "sig"` (or `use` omitted), `alg` matching the whitelist, and a `kid`. Build `DecodingKey::from_rsa_components` / `from_ec_components` as appropriate. (`jsonwebtoken::jwk::Jwk` + `DecodingKey::from_jwk` does the dispatch for you.)
   - Replace the map atomically: `*cache.write() = JwksCacheState { keys: new_keys, fetched_at: Some(Instant::now()) }`.
   - Re-look up `kid`. Still missing → `AuthError::Invalid`.
4. Build a `jsonwebtoken::Validation`:
   - `algorithms`: explicit whitelist (above).
   - `set_issuer(&[issuer])`.
   - `set_audience(&[audience])` — `jsonwebtoken` accepts both string and array `aud` claims out of the box.
   - `validate_exp = true`, `validate_nbf = true`. `leeway = 60` (seconds).
   - `required_spec_claims = HashSet::from(["exp", "iat", "iss", "aud"])`.
5. `jsonwebtoken::decode::<Claims>(token, &key, &validation)` → on success take claims, on error → `AuthError::Invalid`.
6. Map claims:
   ```rust
   #[derive(Deserialize)]
   struct Claims {
       iss: String,
       sub: String,
       #[serde(default)]
       email: Option<String>,
       #[serde(default)]
       name: Option<String>,
   }
   ```
   into:
   ```rust
   UserIdentity {
       issuer: claims.iss,
       external_id: claims.sub,
       email: claims.email,
       display_name: claims.name,
   }
   ```

**Composition root.** Update `build_authenticator` in `server/crates/loseit-api/src/server.rs`:

```rust
async fn build_authenticator(cfg: &AuthConfig, env_name: &str) -> Result<DynAuthenticator> {
    match cfg {
        AuthConfig::DevBypass { /* unchanged */ } => { /* unchanged */ }
        AuthConfig::Jwks { issuer, audience, jwks_url, cache_ttl_secs } => {
            let auth = JwksAuthenticator::new(
                issuer.clone(),
                audience.clone(),
                jwks_url.clone(),
                Duration::from_secs(*cache_ttl_secs),
            ).await?;
            Ok(Arc::new(auth))
        }
    }
}
```

`build_authenticator` becomes `async`. Update `build_state` to be `async` (the `.await` ripples). `main.rs` is already async; the call site needs `.await`.

**Module wiring.** Add `pub mod jwks;` to `server/crates/loseit-api/src/auth/mod.rs`.

**README note.** Add a short paragraph documenting env vars: `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_JWKS_CACHE_TTL_SECS` (optional, default 600). Mention the algorithm whitelist and 60s leeway.

**Files to touch.**
- `server/Cargo.toml` — workspace deps.
- `server/crates/loseit-api/Cargo.toml` — deps + dev-deps.
- `server/crates/loseit-api/src/auth/mod.rs` — `pub mod jwks;`.
- `server/crates/loseit-api/src/auth/jwks.rs` — new module.
- `server/crates/loseit-api/src/config.rs` — extended `AuthConfig::Jwks` + `load_auth` env reads.
- `server/crates/loseit-api/src/server.rs` — async `build_authenticator`, async `build_state`.
- `server/crates/loseit-api/src/main.rs` — `.await` propagation.
- `server/README.md` — config doc.

**Acceptance criteria.**
- With `DEV_AUTH_BYPASS=true`, behaviour unchanged.
- With `OIDC_*` env vars set and a real JWKS endpoint, the server starts and validates tokens.
- A token signed with a private key whose public counterpart is in the JWKS document is accepted; identity fields populated from `sub`/`email`/`name`.
- A token with `alg: HS256` (symmetric) is rejected with 401 regardless of cache state.
- A token with no `kid` is rejected with 401.
- A token whose `aud` is a single string equal to `OIDC_AUDIENCE` is accepted.
- A token whose `aud` is an array including `OIDC_AUDIENCE` is accepted.
- A token expired by more than 60s is rejected with 401; expired by 30s is accepted (leeway).
- JWKS endpoint returning 500 → next request is 503 (`AuthError::Upstream`).
- Concurrent first-uses (10 in parallel) on a fresh cache fire exactly one upstream fetch (refresh lock works).

**Test plan.**
- Unit tests in `auth/jwks.rs` (using `rsa` to generate a keypair, `jsonwebtoken::EncodingKey::from_rsa_pem` to sign, build a JWKS doc inline):
  - `accepts_token_signed_by_known_kid`.
  - `rejects_token_with_hs256`.
  - `rejects_token_with_unknown_kid_after_refresh`.
  - `rejects_expired_token`.
  - `accepts_token_within_leeway`.
  - `accepts_audience_as_array`.
- Integration test in `tests/http.rs` (or a new `tests/http_jwks.rs`) using `wiremock`:
  - Boot a wiremock server serving a static JWKS document at `/jwks`.
  - Build `AppState` with a `JwksAuthenticator` pointing at it.
  - Hit `/api/v1/me` with a valid token → 200.
  - Hit with an invalid signature → 401.
  - Stop the wiremock server, wait for cache TTL to expire, hit again → 503.

**Risks / gotchas.**
- Never accept `alg: none` or any `HS*`. Whitelist explicit, not "deny `none`" — defensive against future jsonwebtoken default changes.
- `jsonwebtoken::DecodingKey::from_jwk(&jwk)` is the right entrypoint — it handles RSA vs EC. Don't manually pluck `n`/`e`.
- `audience` validation: `jsonwebtoken::Validation::set_audience(&[&str])` checks against both string and array claims natively. Confirm with a test.
- Cache eviction strategy: TTL only, no LRU. For provider rotations, this is fine — keys rotate slowly.
- A failed JWKS fetch must not poison the cache. If the refresh fails, leave the existing keys intact so previously-valid tokens still validate until they expire (production safety).
- The TLS stack is `rustls` (matches sqlx). Don't pull in `reqwest`'s default `native-tls`.
- `build_state` becoming async cascades into `main.rs` and into any test that previously called `AppState::from_ports` (those don't go through `build_state` so they're fine).

---

### Task 12: `UserRepository::delete_user` + `UserService::delete_self` + `DELETE /me` handler + OpenAPI

**Status:** pending
**Depends on:** none (the export_jobs cascade preamble is conditional — if T13 hasn't landed, the `UPDATE export_jobs` line is a no-op against a missing table; **but** we should sequence: have T12 either land *after* T13, or guard the export_jobs update via `IF EXISTS`. Simpler: sequence T12 after T13.)
**Parallelizable with:** T08, T10 (different files), but **must come after T13** if you want the export_jobs preamble to work on a fresh DB.
**Estimated size:** M (4 files, ~200 LOC)
**Suggested model:** sonnet

**Scope.** Add the cascading-delete repo method, the trivial service wrapper, the `DELETE /me` handler, and the OpenAPI delta. The cascade is one transaction in SQL — order matters because `food_log_entries.food_id` is `ON DELETE RESTRICT`.

**Context the dev needs.**
- `server/crates/loseit-core/src/repo/user.rs` — `UserRepository` trait (single new method).
- `server/crates/loseit-db/src/user_repo.rs` — Pg impl.
- `server/crates/loseit-testing/src/users.rs` — fake. Must also delete the user's rows in the other in-memory repos (or the fake needs no-op'd; see "Risks").
- `server/crates/loseit-core/src/service/user.rs` — `UserService`. Add `delete_self`.
- `server/crates/loseit-api/src/routes/profile.rs` — `router()`. Add a `delete` route on `/me`.
- `server/migrations/0001_initial.sql:209` — `food_log_entries.food_id` is `ON DELETE RESTRICT`. This is why log entries must be deleted before user-owned foods.

**Spec.**

Trait addition:

```rust
async fn delete_user(&self, user_id: Uuid) -> CoreResult<()>;
```

Pg impl runs one transaction:

```sql
BEGIN;
-- Mark any in-flight export job as failed; the runner re-checks status
-- before each write and bails on non-pending. If 0006_export_jobs.sql
-- hasn't landed yet, remove this statement.
UPDATE export_jobs
   SET status = 'failed',
       error = 'user deleted',
       updated_at = now()
 WHERE user_id = $1 AND status = 'pending';

-- Order matters: log entries hold an ON DELETE RESTRICT FK to foods, so
-- they must clear before user-owned foods can drop.
DELETE FROM food_log_entries WHERE user_id = $1;
DELETE FROM weights          WHERE user_id = $1;
DELETE FROM goals            WHERE user_id = $1;
DELETE FROM foods            WHERE owner_user_id = $1 AND source = 'user';
DELETE FROM export_jobs      WHERE user_id = $1;
DELETE FROM users            WHERE id = $1;
COMMIT;
```

Service method:

```rust
#[tracing::instrument(skip(self))]
pub async fn delete_self(&self, user_id: Uuid) -> CoreResult<()> {
    self.users.delete_user(user_id).await
}
```

Handler in `routes/profile.rs`:

```rust
async fn delete_me(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
) -> Result<StatusCode, ApiError> {
    state.users.delete_self(user.id).await?;
    Ok(StatusCode::NO_CONTENT)
}
```

Register: change `.route("/me", patch(patch_me))` to `.route("/me", patch(patch_me).delete(delete_me))`.

Fake impl: needs access to the other in-memory repos so a delete actually clears the user's data. Pragmatic approach: in `InMemoryUserRepository::delete_user`, just remove the user row — tests that need cross-table cleanup wire it up explicitly. Document this limitation in a doc comment on the fake.

**OpenAPI delta**. Extend the `/me` block (line 75-107 of `openapi.yaml`) with a `delete` operation:

```yaml
    delete:
      tags: [Profile]
      operationId: delete_me
      summary: Permanently delete the authenticated user and all their data
      description: |
        Cascades deletion across food log entries, weights, goals, the
        caller's custom foods, and any export jobs (pending jobs are
        marked failed). Returns 204 on success. Subsequent requests with
        the same token return 401.
      responses:
        "204": { description: Deleted. }
        "401": { $ref: "#/components/responses/Unauthorized" }
```

**Files to touch.**
- `server/crates/loseit-core/src/repo/user.rs` — trait.
- `server/crates/loseit-db/src/user_repo.rs` — Pg impl.
- `server/crates/loseit-testing/src/users.rs` — fake.
- `server/crates/loseit-core/src/service/user.rs` — `delete_self`.
- `server/crates/loseit-api/src/routes/profile.rs` — handler + route.
- `server/specs/openapi.yaml` — `/me` block addition.

**Acceptance criteria.**
- `DELETE /api/v1/me` returns 204 for an authenticated user.
- The user's log entries, weights, goals, custom foods, and export jobs are removed in one transaction (verify with a Pg integration test or read-after-delete query).
- The user row itself is removed.
- A subsequent request with the same token (which still validates locally) hits `require_auth`, calls `ensure_user`, *re-provisions* the user — that's acceptable v1 behaviour (PM noted). Document this in the OpenAPI description if it surprises.

**Test plan.**
- `user_repo::delete_user_cascades_through_food_log_entries_before_user_foods` — Pg integration if possible.
- `delete_me_returns_204`.
- `delete_me_leaves_other_users_intact` — seed Alice + Bob; delete Alice; Bob's data unchanged.
- `delete_me_then_get_me_re-provisions_a_fresh_user` (current behaviour; document if this changes).

**Risks / gotchas.**
- If T13 hasn't shipped, the `UPDATE export_jobs` line must be removed. Sequence T13 first.
- The OFF/USDA `foods` rows must NOT be touched — they're shared. The `AND source = 'user'` filter is what prevents that.
- Don't add a `created_by` check on the user row — `id = $1` is sufficient.
- The fake's lack of cross-repo cleanup means an HTTP-level test asserting "after delete, GET /log returns empty" won't work against in-memory fakes. Test the cascade at the Pg layer; test the 204 behaviour at the HTTP layer.

---

### Task 13: Migration 0006, `domain::export`, `ExportJobRepository`

**Status:** pending
**Depends on:** none
**Parallelizable with:** T01, T03, T05, T07, T09, T11
**Estimated size:** L (5 files, ~450 LOC)
**Suggested model:** opus (the SQL schema + the partial unique index + the in-memory fake all need to be coherent)

**Scope.** New `export_jobs` table, new domain types for the job, new repository trait + Pg/fake impls. No service or HTTP wiring in this task (T15 builds on top).

**Context the dev needs.**
- `server/migrations/0001_initial.sql` — the `set_updated_at` function and the `users` CASCADE pattern.
- `server/crates/loseit-core/src/domain/mod.rs` — registry of re-exports.
- `server/crates/loseit-core/src/repo/mod.rs` — registry of repo trait re-exports.

**Spec.**

**Migration `server/migrations/0006_export_jobs.sql`** (verbatim):

```sql
-- Async data-export jobs for `POST /me/export` / `GET /me/export/:job_id`.
-- One row per export attempt. Status flows pending → ready | failed.
-- The fourth status, `expired`, is computed at GET time from
-- `expires_at < now()` — not stored — so we never need a sweeper to flip it.

CREATE TABLE export_jobs (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    status       TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'failed')),
    storage_key  TEXT,
    error        TEXT,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ
);

-- Idempotency: at most one pending job per user. Lets POST /me/export
-- be a `find-or-create-pending` upsert via ON CONFLICT.
CREATE UNIQUE INDEX export_jobs_one_pending_per_user
    ON export_jobs(user_id)
    WHERE status = 'pending';

CREATE INDEX export_jobs_user_id_idx ON export_jobs(user_id);
CREATE INDEX export_jobs_status_idx ON export_jobs(status);

CREATE TRIGGER export_jobs_set_updated_at
    BEFORE UPDATE ON export_jobs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

**Domain** `server/crates/loseit-core/src/domain/export.rs` (new file):

```rust
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportStatus {
    Pending,
    Ready,
    Failed,
}

impl ExportStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            ExportStatus::Pending => "pending",
            ExportStatus::Ready => "ready",
            ExportStatus::Failed => "failed",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(ExportStatus::Pending),
            "ready" => Some(ExportStatus::Ready),
            "failed" => Some(ExportStatus::Failed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ExportJob {
    pub id: Uuid,
    pub user_id: Uuid,
    pub status: ExportStatus,
    pub storage_key: Option<String>,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
}
```

Add `pub mod export;` and `pub use export::{ExportJob, ExportStatus};` to `server/crates/loseit-core/src/domain/mod.rs`.

**Repo trait** `server/crates/loseit-core/src/repo/export.rs` (new file):

```rust
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::ExportJob;
use crate::CoreResult;

#[async_trait]
pub trait ExportJobRepository: Send + Sync + 'static {
    /// Idempotently obtain the user's pending job. If one exists, return
    /// it; otherwise create a new pending row. Implementations use
    /// `INSERT … ON CONFLICT (user_id) WHERE status='pending' DO UPDATE`
    /// against the `export_jobs_one_pending_per_user` partial unique index.
    async fn insert_or_get_pending(&self, user_id: Uuid) -> CoreResult<ExportJob>;

    /// Create a fresh pending job unconditionally. Used when the caller
    /// has a non-pending (ready/failed/expired) prior job and asks for a
    /// re-export.
    async fn create_pending(&self, user_id: Uuid) -> CoreResult<ExportJob>;

    /// Look up a job scoped to a user. Returns `None` if the job doesn't
    /// exist OR if it belongs to a different user — handlers map both to
    /// 404 to avoid info leaks.
    async fn find(&self, user_id: Uuid, job_id: Uuid) -> CoreResult<Option<ExportJob>>;

    /// Mark a job ready. Sets `storage_key`, `expires_at`, status='ready'.
    async fn mark_ready(
        &self,
        job_id: Uuid,
        storage_key: String,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<ExportJob>;

    /// Mark a job failed. Sets `error`, status='failed'.
    async fn mark_failed(&self, job_id: Uuid, error: String) -> CoreResult<ExportJob>;

    /// Used at startup to re-enqueue any jobs that were in flight when the
    /// server stopped.
    async fn list_pending(&self) -> CoreResult<Vec<ExportJob>>;
}
```

Add `pub mod export;` + `pub use export::ExportJobRepository;` to `server/crates/loseit-core/src/repo/mod.rs`.

**Pg impl** `server/crates/loseit-db/src/export_repo.rs` (new file). Standard pattern:
- `insert_or_get_pending`: `INSERT INTO export_jobs (user_id, status) VALUES ($1, 'pending') ON CONFLICT ON CONSTRAINT export_jobs_one_pending_per_user DO UPDATE SET updated_at = now() RETURNING *;`
- `create_pending`: plain `INSERT … RETURNING *;` — no `ON CONFLICT`. This is what differs from the idempotent path: a fresh pending row even if a ready/failed job exists.
- `find`: `SELECT … WHERE id = $1 AND user_id = $2`.
- `mark_ready`: `UPDATE … SET status='ready', storage_key=$2, expires_at=$3 WHERE id=$1 RETURNING *;`
- `mark_failed`: same shape.
- `list_pending`: `SELECT … WHERE status='pending'`.

Add `pub use export_repo::PgExportJobRepository;` to `server/crates/loseit-db/src/lib.rs`.

**Fake** `server/crates/loseit-testing/src/exports.rs` (new file): `Mutex<Vec<ExportJob>>`. Match the trait semantics. Add `pub use exports::InMemoryExportJobRepository;` to `server/crates/loseit-testing/src/lib.rs`.

**Files to touch.**
- `server/migrations/0006_export_jobs.sql` — new.
- `server/crates/loseit-core/src/domain/export.rs` — new.
- `server/crates/loseit-core/src/domain/mod.rs` — register.
- `server/crates/loseit-core/src/repo/export.rs` — new.
- `server/crates/loseit-core/src/repo/mod.rs` — register.
- `server/crates/loseit-db/src/export_repo.rs` — new.
- `server/crates/loseit-db/src/lib.rs` — register.
- `server/crates/loseit-testing/src/exports.rs` — new.
- `server/crates/loseit-testing/src/lib.rs` — register.

(Nine files; counts as one task because most are tiny "register" lines.)

**Acceptance criteria.**
- `sqlx migrate run` applies 0006 cleanly to a fresh DB.
- `insert_or_get_pending` twice in a row returns the same `id`.
- A pending job + a fresh `insert_or_get_pending` for the same user returns the existing pending row.
- A `mark_ready` row followed by a `insert_or_get_pending` creates a **new** pending row (the partial unique index doesn't conflict with ready rows).
- `find(other_user_id, job_id)` returns `None` for a job belonging to a different user.
- `list_pending` returns every pending row across all users.

**Test plan.**
- `export_repo::insert_or_get_pending_is_idempotent`.
- `export_repo::create_pending_allowed_when_prior_job_is_ready`.
- `export_repo::find_scoped_by_user_returns_none_cross_tenant`.
- `export_repo::mark_ready_then_get_returns_ready_with_storage_key`.
- `export_repo::list_pending_returns_all_pending_jobs`.

**Risks / gotchas.**
- The `expired` state is **computed at GET time** — never stored. Don't add it to the SQL CHECK.
- The partial unique index name `export_jobs_one_pending_per_user` is referenced by `ON CONFLICT ON CONSTRAINT` — keep them in sync.
- T12 should land *after* T13 so its preamble (`UPDATE export_jobs WHERE status='pending'`) targets a real table.

---

### Task 14: `ExportStorage` trait + local-FS impl + signed-URL HMAC helpers + public token route

**Status:** pending
**Depends on:** none (can run in parallel with T13)
**Parallelizable with:** T01, T03, T05, T07, T09, T11, T13
**Estimated size:** L (5 files, ~500 LOC)
**Suggested model:** opus (HMAC + public unauthenticated route requires care)

**Scope.** The storage abstraction the export runner writes to, a local-filesystem implementation for v1, the HMAC scheme that signs URL tokens, and the public unauthenticated `GET /api/v1/me/export/file/:token` route that streams the file back.

**Context the dev needs.**
- `server/crates/loseit-core/src/repo/mod.rs` — register the new trait.
- `server/crates/loseit-db/src/lib.rs` — register the new impl.
- `server/crates/loseit-api/src/routes/` — new module for the file-serve route.
- `server/crates/loseit-api/src/server.rs` — `router()` (line 110). The file route must be on the *public* router, **not** behind `require_auth`.

**Spec.**

**Trait** `server/crates/loseit-core/src/repo/export_storage.rs` (new file):

```rust
use async_trait::async_trait;
use bytes::Bytes;
use std::time::Duration;

use crate::CoreResult;

#[async_trait]
pub trait ExportStorage: Send + Sync + 'static {
    /// Store `body` under a backend-chosen key derived from `key_hint`.
    /// Returns the canonical key the backend stored it under (which may
    /// differ from `key_hint`; the service stores the returned key).
    async fn put(
        &self,
        key_hint: &str,
        body: Bytes,
        content_type: &str,
    ) -> CoreResult<String>;

    /// Issue a time-limited URL that serves the object. For the local-FS
    /// impl this is a `/api/v1/me/export/file/:token` URL with an HMAC
    /// token; for future bucket backends it's a presigned URL.
    async fn signed_url(&self, key: &str, ttl: Duration) -> CoreResult<String>;

    /// Best-effort delete. Errors are logged but don't fail the caller —
    /// the service moves on; an out-of-band sweep handles orphans.
    async fn delete(&self, key: &str) -> CoreResult<()>;
}
```

Add `pub mod export_storage;` and `pub use export_storage::ExportStorage;` to `server/crates/loseit-core/src/repo/mod.rs`.

**Local-FS impl** `server/crates/loseit-db/src/local_export_storage.rs` (new file). The crate name is wrong-ish ("db" but no DB), but this is intentional — the design avoids premature factoring. Doc-comment the deviation.

```rust
pub struct LocalExportStorage {
    base_dir: PathBuf,
    public_base_url: String,    // e.g. "https://api.loseit.invalid/api/v1"
    hmac_secret: [u8; 32],
}

impl LocalExportStorage {
    pub fn new(base_dir: PathBuf, public_base_url: String, hmac_secret: [u8; 32]) -> Result<Self> {
        std::fs::create_dir_all(&base_dir)?;
        Ok(Self { base_dir, public_base_url, hmac_secret })
    }
}

#[async_trait]
impl ExportStorage for LocalExportStorage {
    async fn put(&self, key_hint: &str, body: Bytes, _content_type: &str) -> CoreResult<String> {
        // key = key_hint (sanitized — basename only, alnum + dash + dot + underscore).
        let key = sanitize_key(key_hint)?;
        let path = self.base_dir.join(&key);
        tokio::fs::write(&path, &body).await?;
        Ok(key)
    }

    async fn signed_url(&self, key: &str, ttl: Duration) -> CoreResult<String> {
        let expires_at = (Utc::now() + chrono::Duration::from_std(ttl)?).timestamp();
        let token = mint_token(&self.hmac_secret, key, expires_at);
        Ok(format!("{}/me/export/file/{}", self.public_base_url, token))
    }

    async fn delete(&self, key: &str) -> CoreResult<()> {
        let path = self.base_dir.join(key);
        let _ = tokio::fs::remove_file(path).await; // log + swallow on error
        Ok(())
    }
}
```

**HMAC token format.** Public module `server/crates/loseit-api/src/routes/export_file.rs` (new file) provides both the mint helper and the verify-and-serve handler:

```rust
/// Token = base64url( HMAC-SHA256(secret, expires_at_ts || key) || expires_at_ts || key )
/// where expires_at_ts is an 8-byte big-endian unix seconds.
pub fn mint_token(secret: &[u8; 32], key: &str, expires_at_ts: i64) -> String { /* ... */ }

/// Returns (key, expires_at_ts) if the signature checks out and the
/// expiry is in the future. None otherwise.
fn verify_token(secret: &[u8; 32], token: &str) -> Option<(String, i64)> { /* ... */ }
```

Implementation: use `hmac = "0.12"` + `sha2 = "0.10"`. Compute MAC over `expires_at_ts.to_be_bytes() || key.as_bytes()`. Serialize as `base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mac_bytes || expires_at_ts.to_be_bytes() || key.as_bytes())`.

Add to `server/Cargo.toml`:

```toml
hmac = "0.12"
sha2 = "0.10"
base64 = "0.22"
bytes = "1"
```

And expose in `server/crates/loseit-api/Cargo.toml` + `server/crates/loseit-db/Cargo.toml` as needed.

**Public route** in `server/crates/loseit-api/src/routes/export_file.rs`:

```rust
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/me/export/file/:token", get(serve_export))
}

async fn serve_export(
    State(state): State<AppState>,
    Path(token): Path<String>,
) -> Result<Response, ApiError> {
    let Some((key, expires_at)) = verify_token(&state.export_hmac_secret, &token) else {
        return Err(ApiError::not_found());
    };
    if Utc::now().timestamp() > expires_at {
        return Err(ApiError::new(StatusCode::GONE, "expired", "download link expired"));
    }
    let path = state.export_dir.join(&key);
    let file = tokio::fs::File::open(&path).await.map_err(|_| ApiError::not_found())?;
    let stream = tokio_util::io::ReaderStream::new(file);
    let body = axum::body::Body::from_stream(stream);
    Ok(Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/gzip")
        .header(header::CONTENT_DISPOSITION, format!("attachment; filename=\"{key}\""))
        .body(body)?)
}
```

Add `tokio-util = { version = "0.7", features = ["io"] }` to `server/Cargo.toml`.

Wire into the **public** router half of `server::router`:

```rust
let public = routes::health::router()
    .merge(routes::export_file::router());
```

Register `pub mod export_file;` in `server/crates/loseit-api/src/routes/mod.rs`.

**AppState fields.** Extend `AppState`:

```rust
pub export_storage: Arc<dyn ExportStorage>,
pub export_dir: PathBuf,
pub export_hmac_secret: [u8; 32],
```

The HMAC secret is loaded from env `LOSEIT_EXPORT_HMAC_SECRET` (32-byte hex string, required when JWKS auth is on; in dev with `DEV_AUTH_BYPASS=true` a deterministic stub `[0u8; 32]` is acceptable — make this explicit in `config.rs`). Export dir from `LOSEIT_EXPORT_DIR` (default `./exports`). Both consumed in `build_state`.

**Files to touch.**
- `server/crates/loseit-core/src/repo/export_storage.rs` — new trait.
- `server/crates/loseit-core/src/repo/mod.rs` — register.
- `server/crates/loseit-db/src/local_export_storage.rs` — new impl.
- `server/crates/loseit-db/src/lib.rs` — register.
- `server/crates/loseit-api/src/routes/export_file.rs` — new module (route + token helpers).
- `server/crates/loseit-api/src/routes/mod.rs` — register.
- `server/crates/loseit-api/src/server.rs` — extend `AppState`, wire route, wire storage in `build_state`.
- `server/crates/loseit-api/src/config.rs` — `LOSEIT_EXPORT_DIR`, `LOSEIT_EXPORT_HMAC_SECRET`.
- `server/Cargo.toml` — `hmac`, `sha2`, `base64`, `bytes`, `tokio-util`.

(Nine files. One genuinely new feature.)

**Acceptance criteria.**
- `put + signed_url` issued via `LocalExportStorage` produces a URL that, when GET'd, returns the original bytes with `Content-Type: application/gzip`.
- A tampered token (any single byte flipped) returns 404.
- A token whose `expires_at` is in the past returns 410 Gone.
- A valid token for a key whose file was deleted returns 404.
- The `/me/export/file/:token` route is reachable without an Authorization header.
- Path traversal in `key` is prevented (`../etc/passwd` returns 404 via `sanitize_key`).

**Test plan.**
- `export_storage::put_and_get_round_trip`.
- `export_storage::signed_url_rejects_tampered_token`.
- `export_storage::signed_url_rejects_expired_token`.
- `export_file::path_traversal_rejected`.
- `export_file::missing_file_returns_404`.

**Risks / gotchas.**
- The route is *intentionally* unauthenticated. The HMAC is the auth. Mistakenly putting it behind `require_auth` defeats the whole point.
- `sanitize_key` should restrict to `[a-zA-Z0-9._-]` and reject leading dots / slashes / `..`. Use a charset check, not a regex with `^[allow]+$` (Rust's `regex` crate isn't in deps; do it as a simple `chars().all(...)` check).
- Constant-time comparison for HMAC verification — use `subtle::ConstantTimeEq` or `hmac::Mac::verify_slice`. **Never** plain `==` on the MAC bytes.
- `LOSEIT_EXPORT_HMAC_SECRET` must be a fixed-length value (32 bytes from hex). Reject startup with a clear error if it's shorter.
- The `public_base_url` lives in config so links survive being viewed via an HTTPS proxy. Default it to `http://127.0.0.1:8080/api/v1` in dev.

---

### Task 15: `ExportService` + endpoints + in-process runner + startup recovery

**Status:** pending
**Depends on:** T13, T14
**Parallelizable with:** —  (single-file conflict prone with T12 on `routes/profile.rs`; if you sequence T12 first, T15's mod additions in `server.rs` will conflict only if both edit the same lines — keep T15's `AppState` edits in a separate block from T12's)
**Estimated size:** L (6 files, ~700 LOC)
**Suggested model:** opus

**Scope.** Wire it all together: the service that enqueues + assembles + runs export jobs, the two HTTP endpoints, the in-process tokio runner, and startup recovery for jobs left pending across restarts.

**Context the dev needs.**
- T13's `ExportJobRepository` + `ExportJob` + `ExportStatus` domain.
- T14's `ExportStorage` trait.
- All other per-user repositories: foods (`list_mine`/`count_mine` once T01 lands; otherwise loop on `find_by_id` over an id-listing method that already exists), servings (per food), logs (`list_paginated`), weights (`list_paginated` from T05), goals (`list_for_user`). Walk each via the paginated methods.
- `server/crates/loseit-api/src/server.rs` — `build_state` is where the runner is spawned.

**Spec.**

**Service** `server/crates/loseit-core/src/service/export.rs` (new file):

```rust
pub struct ExportService {
    jobs: Arc<dyn ExportJobRepository>,
    storage: Arc<dyn ExportStorage>,
    // Per-user repos for assembly.
    users: Arc<dyn UserRepository>,
    foods: Arc<dyn FoodRepository>,
    servings: Arc<dyn ServingRepository>,
    logs: Arc<dyn LogRepository>,
    weights: Arc<dyn WeightRepository>,
    goals: Arc<dyn GoalRepository>,
    // Push-side of the runner channel.
    enqueue_tx: tokio::sync::mpsc::UnboundedSender<Uuid>,
    // How long ready URLs stay live before status flips to "expired".
    download_ttl: chrono::Duration,
}

impl ExportService {
    /// POST /me/export. If a pending job exists, return it; otherwise
    /// create one and push its id to the runner.
    pub async fn enqueue(&self, user_id: Uuid) -> CoreResult<ExportJob> {
        let job = self.jobs.insert_or_get_pending(user_id).await?;
        // Only push if newly pending (idempotent guarantee: pushing twice is
        // safe because the runner double-checks status before each write).
        let _ = self.enqueue_tx.send(job.id);
        Ok(job)
    }

    /// GET /me/export/:job_id. None → handler emits 404.
    pub async fn get(&self, user_id: Uuid, job_id: Uuid) -> CoreResult<Option<ExportJobView>> {
        let Some(job) = self.jobs.find(user_id, job_id).await? else {
            return Ok(None);
        };
        let view = self.to_view(job).await?;
        Ok(Some(view))
    }

    /// Background runner entry point. The spawned worker calls this for
    /// every id received on its channel. Double-checks status before
    /// writing storage so a concurrent DELETE /me cancellation is honoured.
    pub async fn run(&self, job_id: Uuid) -> CoreResult<()> { /* see below */ }

    pub async fn list_pending_for_recovery(&self) -> CoreResult<Vec<Uuid>> {
        Ok(self.jobs.list_pending().await?.into_iter().map(|j| j.id).collect())
    }

    async fn to_view(&self, job: ExportJob) -> CoreResult<ExportJobView> {
        let now = Utc::now();
        let status_str = match job.status {
            ExportStatus::Pending => "pending",
            ExportStatus::Failed => "failed",
            ExportStatus::Ready => {
                if job.expires_at.map_or(false, |e| e < now) { "expired" } else { "ready" }
            }
        };
        let signed_url = if status_str == "ready" {
            Some(self.storage.signed_url(job.storage_key.as_deref().unwrap(),
                Duration::from_secs(self.download_ttl.num_seconds() as u64)).await?)
        } else { None };
        Ok(ExportJobView {
            job_id: job.id,
            status: status_str.into(),
            created_at: job.created_at,
            updated_at: job.updated_at,
            expires_at: job.expires_at,
            signed_url,
            error: job.error,
        })
    }
}

pub struct ExportJobView {
    pub job_id: Uuid,
    pub status: String,    // one of "pending"|"ready"|"failed"|"expired"
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    pub signed_url: Option<String>,
    pub error: Option<String>,
}
```

**`run(job_id)` algorithm:**

```rust
pub async fn run(&self, job_id: Uuid) -> CoreResult<()> {
    // 1. Look up the job. If gone (user deleted), bail.
    let Some(job) = self.find_by_id(job_id).await? else { return Ok(()); };
    // 2. Concurrency check: if not pending anymore, someone else handled it.
    if job.status != ExportStatus::Pending { return Ok(()); }

    let user_id = job.user_id;
    // 3. Assemble. On error, mark failed.
    let bundle = match self.assemble_bundle(user_id).await {
        Ok(b) => b,
        Err(e) => { self.jobs.mark_failed(job_id, e.to_string()).await?; return Ok(()); }
    };

    // 4. Re-check before storage write — user may have just been deleted.
    let Some(still_pending) = self.jobs.find(user_id, job_id).await? else { return Ok(()); };
    if still_pending.status != ExportStatus::Pending { return Ok(()); }

    // 5. Upload + mark ready.
    let key = format!("export-{}-{}.json.gz", user_id, job_id);
    let storage_key = match self.storage.put(&key, bundle, "application/gzip").await {
        Ok(k) => k,
        Err(e) => { self.jobs.mark_failed(job_id, e.to_string()).await?; return Ok(()); }
    };
    let expires_at = Utc::now() + self.download_ttl;
    self.jobs.mark_ready(job_id, storage_key, expires_at).await?;
    Ok(())
}
```

**`assemble_bundle(user_id) -> Bytes`:**

Collect:
- `user`: `self.users.find_by_id(user_id).await?.unwrap()` — serialised as the `User` JSON shape.
- `foods`: walk `self.foods.list_mine(user_id, None, 500, offset).await` (or whatever the paginated method returns) until empty. Concatenate.
- `servings`: for each food id collected above, `self.servings.list_for_food(food_id).await?`.
- `log_entries`: walk `self.logs.list_paginated(user_id, None, None, 500, offset).await` until empty.
- `weights`: walk `self.weights.list_paginated(user_id, None, None, 500, offset).await`.
- `goals`: `self.goals.list_for_user(user_id).await?` (already returns all).

Bundle shape:

```json
{
  "schema_version": 1,
  "exported_at": "2026-05-16T00:00:00Z",
  "user": { ... },
  "foods": [ ... ],
  "servings": [ ... ],
  "log_entries": [ ... ],
  "weights": [ ... ],
  "goals": [ ... ]
}
```

Serialize via `serde_json::to_vec_pretty` (or compact — pretty is friendlier for users who unzip). Gzip via `flate2::write::GzEncoder` at default compression. Return `Bytes`.

Add `flate2 = "1"` to `server/Cargo.toml`.

**Runner spawn** in `server/crates/loseit-api/src/server.rs::build_state`:

```rust
let (enqueue_tx, mut enqueue_rx) = tokio::sync::mpsc::unbounded_channel::<Uuid>();
let export_service = Arc::new(ExportService::new(/* … */, enqueue_tx.clone(), /* TTL */));
// Spawn the runner.
let runner_service = export_service.clone();
tokio::spawn(async move {
    while let Some(job_id) = enqueue_rx.recv().await {
        if let Err(e) = runner_service.run(job_id).await {
            tracing::error!(job_id = %job_id, error = ?e, "export runner failed");
        }
    }
});
// Startup recovery: re-enqueue every pending job.
for job_id in export_service.list_pending_for_recovery().await? {
    let _ = enqueue_tx.send(job_id);
}
```

**Endpoints** as a new module `server/crates/loseit-api/src/routes/export.rs`:

```rust
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/me/export", post(enqueue))
        .route("/me/export/:job_id", get(get_job))
}

#[derive(Serialize)]
struct ExportJobResponse {
    job_id: Uuid,
    status: String,      // "pending"|"ready"|"failed"|"expired"
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    signed_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expires_at: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

async fn enqueue(/* state, user */) -> Result<(StatusCode, Json<ExportJobResponse>), ApiError> {
    let job = state.exports.enqueue(user.id).await?;
    let view = state.exports.to_view_public(job).await?;
    // Per spec: 202 always (idempotent on pending returns 202 with the same row).
    Ok((StatusCode::ACCEPTED, Json(view.into())))
}

async fn get_job(/* state, user, path job_id */) -> Result<Json<ExportJobResponse>, ApiError> {
    let view = state.exports.get(user.id, job_id).await?.ok_or_else(ApiError::not_found)?;
    Ok(Json(view.into()))
}
```

Register `pub mod export;` in `routes/mod.rs`. Merge into the authed router half of `server::router`.

**OpenAPI delta**. Two new paths + one new schema:

```yaml
  /me/export:
    post:
      tags: [Profile]
      operationId: enqueue_export
      summary: Request a data export
      description: |
        Creates a pending export job, or returns the caller's existing
        pending job if one exists. The runner asynchronously assembles a
        gzipped JSON bundle of the caller's user record, custom foods,
        servings, log entries, weights, and goals; once ready, `GET
        /me/export/:job_id` will return a time-limited signed download
        URL. The response is always 202 — clients should poll the GET
        endpoint to discover completion.
      responses:
        "202":
          description: Job created or already pending.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/ExportJobResponse" }
        "401": { $ref: "#/components/responses/Unauthorized" }

  /me/export/{job_id}:
    get:
      tags: [Profile]
      operationId: get_export_job
      summary: Poll an export job
      parameters:
        - in: path
          name: job_id
          required: true
          schema: { type: string, format: uuid }
      responses:
        "200":
          description: Current job status.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/ExportJobResponse" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "404": { $ref: "#/components/responses/NotFound" }
```

```yaml
    ExportJobResponse:
      type: object
      required: [job_id, status, created_at, updated_at]
      properties:
        job_id: { type: string, format: uuid }
        status:
          type: string
          enum: [pending, ready, failed, expired]
        created_at: { type: string, format: date-time }
        updated_at: { type: string, format: date-time }
        signed_url:
          type: string
          description: Present only when `status: ready`. Time-limited.
        expires_at:
          type: string
          format: date-time
          description: Present when `status: ready`. After this time, status becomes `expired`.
        error:
          type: string
          description: Present only when `status: failed`.
```

**AppState extension.**

```rust
pub exports: Arc<ExportService>,
```

Threaded through `AppState::from_ports` (the test constructor) — tests get a no-op `ExportService` built atop `InMemoryExportJobRepository` + an in-memory `ExportStorage` (you'll need a `InMemoryExportStorage` fake — add it as part of this task).

**Files to touch.**
- `server/crates/loseit-core/src/service/export.rs` — new service.
- `server/crates/loseit-core/src/service/mod.rs` — register.
- `server/crates/loseit-api/src/routes/export.rs` — new endpoints.
- `server/crates/loseit-api/src/routes/mod.rs` — register.
- `server/crates/loseit-api/src/server.rs` — `AppState.exports`, runner spawn, recovery, `from_ports` signature.
- `server/crates/loseit-testing/src/exports.rs` — extend with `InMemoryExportStorage` if not already there from T14.
- `server/specs/openapi.yaml` — two new paths, one new schema.
- `server/Cargo.toml` — `flate2`.

**Acceptance criteria.**
- `POST /me/export` returns 202 with the pending job; second call within the lifetime returns 202 with the same `job_id`.
- After a moment (or after `block_on(service.run(job_id))` in tests), `GET /me/export/:job_id` returns `status: "ready"` with a `signed_url`.
- The signed URL, when fetched, returns a gzipped JSON bundle whose `schema_version: 1` and contains the caller's foods/logs/weights/goals.
- `GET /me/export/:other_users_job_id` returns 404, not 403 or 200.
- A job whose `expires_at < now()` returns `status: "expired"` with no `signed_url`.
- A server restart re-enqueues any pending jobs (test via a synthetic pending row + a manual `list_pending_for_recovery` call).
- The bundle excludes OFF/USDA foods — only the user's customs appear in `foods`.

**Test plan.**
- `export_service::enqueue_returns_existing_pending_job_on_repeat_call`.
- `export_service::run_assembles_bundle_with_user_customs_only` — seed an OFF row and a custom; assert bundle has only the custom.
- `export_service::run_marks_failed_when_storage_put_errors` — inject a failing storage fake.
- `export_service::run_bails_when_status_no_longer_pending` (simulate concurrent cancel).
- `http_export::post_then_get_round_trip_returns_ready_url`.
- `http_export::get_job_for_other_user_returns_404`.
- `http_export::status_expired_when_expires_at_in_past`.

**Risks / gotchas.**
- The runner is in-process. If the binary exits, in-flight jobs lose their tokio task. Startup recovery handles this by re-enqueueing — that's why `list_pending` exists.
- The runner's double-check (`find` returning `Pending` before storage write) is the cancellation hook. Don't optimize it away.
- 5y of heavy logging is ~50k log rows; gzipped JSON is a few MB. Don't stream the bundle in v1 — in-memory assembly is fine. Flag streaming as future work in commit message.
- `serde_json` can panic on integer overflow; values from the DB are `Decimal` (no panics) so this is fine. Don't substitute `f64`.
- `signed_url` is computed at GET time, not at `mark_ready` time, so the URL TTL clock starts at "when the user looks", not "when the job finished". This is intentional and worth a code comment.
- The `expired` state is computed; the DB never sees it. Don't add a sweeper job.

---

### Task 16: OpenAPI sweep — sodium docstring, `/foods/search` description, changelog note, tidy-up

**Status:** pending
**Depends on:** T02, T04, T06, T08, T10, T12, T15 (whatever has touched `openapi.yaml` first must have landed; otherwise the merges in this task may collide)
**Parallelizable with:** none (single file, late-stage)
**Estimated size:** S (1 file, ~80 LOC changes)
**Suggested model:** sonnet

**Scope.** Final OpenAPI pass — content the per-route tasks couldn't co-locate. Specifically: the sodium-units note PM asked for, the `/foods/search` default/cap clarification, the top-of-file changelog entry documenting the v1-pre-release wire breaks on `/log` and `/weights`, and a `redocly lint` pass to catch any schema fallout from earlier merges.

**Context the dev needs.**
- `server/specs/openapi.yaml` — entire file.
- `server/specs/redocly.yaml` — lint config (already in CI per `4e2b99f`).

**Spec.**

**1. Sodium docstring** (line 841-844 area, the `NutritionPer100g.sodium_g` schema). Replace the description with:

```yaml
        sodium_g:
          allOf:
            - $ref: "#/components/schemas/Decimal"
          description: |
            Sodium in grams per 100 g (OFF convention). Clients should
            multiply by 1000 to display as milligrams, which is the
            customer-expected unit.
```

**2. `/foods/search` description amendment** (around line 257-260). Add a line to the existing description:

```yaml
      description: |
        Full-text search across the foods catalogue (OFF, USDA, and the
        caller's custom foods). A blank `q` returns `400 bad_request`.

        Default `limit` is 100; the server silently clamps requests above
        500. Sentinel foods used by `POST /log/quick_add` are excluded
        from results.
```

**3. Top-of-file changelog note.** Extend the `info.description` (lines 8-19). Append:

```yaml
    ## v1 pre-release wire-shape changes

    The following endpoints returned bare JSON arrays in early drafts and
    now return paginated envelopes (`{ results, total, limit, offset }`):

    * `GET /log`
    * `GET /weights`

    Both endpoints' `from` and `to` query parameters were previously
    required and are now optional. With no parameters, the response is
    the 100 most-recent entries across the full history.

    The `GET /foods/search` response schema migrated from the bespoke
    `FoodSearchPage` shape to the unified `PaginatedFoodSearchHits`
    envelope; field names are unchanged.
```

**4. Delete the deprecated `FoodSearchPage` schema** if all paginated routes now reference `PaginatedFoodSearchHits` (verify with `grep '$ref.*FoodSearchPage' openapi.yaml` after merges).

**5. Run `redocly lint`** (via `npx @redocly/cli lint server/specs/openapi.yaml` or whatever the CI invocation uses — see `.github/workflows/`). Address any warnings introduced by earlier merges. Common issues:
- Unreferenced schemas → either reference them or delete.
- Missing `description` on a new schema.
- Operation `summary` length exceeding lint thresholds.

**Files to touch.**
- `server/specs/openapi.yaml` — sweep.

**Acceptance criteria.**
- `redocly lint server/specs/openapi.yaml --config server/specs/redocly.yaml` exits 0.
- Sodium description matches the spec text above.
- Changelog block is present in `info.description`.
- `FoodSearchPage` schema removed (if and only if no remaining `$ref` points to it).

**Test plan.**
Manual: open the rendered spec (e.g., `redocly preview-docs`) and confirm the changelog renders and the sodium description shows up under `NutritionPer100g`.

**Risks / gotchas.**
- Merge conflicts: every route task touched this file. Land this last; reconcile.
- Don't drop schemas that other endpoints still use. Always grep before deleting.

---

## Dependency graph

```text
T01 ─── T02 ──────────────────────────────────────┐
T03 ─── T04 ──────────────────────────────────────┤
T05 ─── T06 ──────────────────────────────────────┤
T07 ─── T08 ──────────────────────────────────────┤
T09 ─── T10 ──────────────────────────────────────┤
T11 ──────────────────────────────────────────────┤
T13 ─┬─ T12 ──────────────────────────────────────┤
     │                                            │
     └─ T15 ── (depends on T14 too) ──────────────┤
T14 ─┘                                            │
                                                  ├── T16 (final OpenAPI sweep)
                                                  │
   All route+OpenAPI tasks above feed into T16. ──┘
```

Parallelism notes:
- T01, T03, T05, T07, T09, T11, T13, T14 can all run **fully in parallel** (no shared files).
- T02, T04, T06, T08, T10 each block on one parent (T01/T03/T05/T07/T09 respectively) but can run in parallel with each other once their parent ships.
- T12 should **wait for T13** (so the export_jobs preamble in the cascade SQL targets a real table). Otherwise remove the `UPDATE export_jobs` line and re-add it post-T13.
- T15 waits for both T13 and T14.
- T16 is strictly last — everything that edits `openapi.yaml` must have landed.

Suggested fan-out order:

1. **Wave 1 (parallel, no deps):** T01, T03, T05, T07, T09, T11, T13, T14.
2. **Wave 2 (parallel, one parent each):** T02, T04, T06, T08, T10, T12, T15.
3. **Wave 3 (sequential):** T16.
