# Architect: Custom Foods List + Pagination — Technical Design

## Summary
- New endpoint `GET /foods/mine` returns the caller's `source='user'` foods using the same lean `FoodSearchHit` projection as `/foods/search`, sorted by `created_at DESC` with `id` tiebreak, optionally filtered by `q` (ILIKE substring on `name` + `brands`).
- `GET /log` and `GET /weights` flip from bare-array responses to a `{results, total, limit, offset}` envelope. This is a deliberate pre-v1 wire break (no production client).
- Pagination contract is unified across `/foods/mine`, `/foods/search`, `/log`, `/weights`: same `limit`/`offset` param names, default `limit=100`, max `500`, silent clamp on overrun, `total` always returned via a separate count query.
- A new generic `service::page::Paginated<T>` type replaces `service::SearchPage`; `FoodService::search` migrates to it as part of this work so the wire types and service signatures rhyme.
- No schema migration required. Existing indexes (`foods_owner_idx`, `weights_user_date_idx`, `log_user_date_idx`) already cover the new query paths.

## Decisions

### 1. Offset-based pagination, not cursor

**Decision:** Offset/limit on all three endpoints.
**Alternative:** Opaque cursor (e.g. base64 of `(date, id)` keyset).
**Why:** `/foods/search` already ships offsets. Three endpoints with the same contract is the PM's hard requirement; matching what's already in production wins over the theoretical benefit of keyset pagination at v1 scale (a power user is ≤1800 log rows; cursor's deep-offset advantage doesn't kick in until tens of thousands). Cursor would also force surfacing `total` via a separate count query anyway, so its only real win disappears. Stable secondary sort (`id`) makes offsets safe enough across concurrent writes for v1.

### 2. Introduce a shared `Paginated<T>` core type; retire `SearchPage`

**Decision:** Add `loseit_core::service::page::Paginated<T> { results: Vec<T>, total: i64, limit: i64, offset: i64 }`. `FoodService::search` returns `Paginated<FoodSearchHit>`. Drop the food-specific `SearchPage` alias (or `pub type SearchPage = Paginated<FoodSearchHit>` if a type alias keeps the diff minimal — recommend deletion and a one-line update to `routes/foods.rs`).
**Alternative:** Copy `SearchPage`'s shape per endpoint, or keep `SearchPage` and add `LogPage`/`WeightPage`.
**Why:** Three duplicates of an identical four-field struct is exactly what generics exist for. The wire shape is identical on all three endpoints, so the DTO conversion can be a single `impl<T, R: From<T>> From<Paginated<T>> for PaginatedResponse<R>` on the API side. One source of truth for pagination invariants.

### 3. Wire-side: one generic `PaginatedResponse<T>` in `loseit_api`, not three handwritten copies

**Decision:** Add `loseit_api::routes::pagination::PaginatedResponse<T> { results: Vec<T>, total: i64, limit: i64, offset: i64 }` (serializable), with a `From<Paginated<U>>` impl when `T: From<U>`. Replace `SearchResponse` in `routes/foods.rs` with `PaginatedResponse<FoodSearchHitResponse>`.
**Alternative:** Inline the envelope into each route's response DTO.
**Why:** Same reasoning as #2 but at the wire layer. Keeps the four field names locked together. The serde key ordering is alphabetical-by-declaration, which matches `/foods/search`'s existing wire shape (`results, total, limit, offset`).

### 4. Validation + clamping lives in the service, not the handler

**Decision:** A new `loseit_core::service::page::PageParams::resolve(limit: Option<i64>, offset: Option<i64>) -> Paginated::<()>::Resolved` helper that applies defaults and clamps. Each service method calls it. Handlers do nothing but pass `q.limit`, `q.offset` through.
**Alternative:** Validate in the handler.
**Why:** Matches the established convention (see `FoodService::search` which already clamps inside the service). Keeps the wire layer dumb and reusable when (not if) we add a CLI or RPC surface later.

### 5. Silent clamp on `limit > 500`; reject only `limit < 0`

**Decision:** `limit > MAX` is clamped to MAX, response carries the clamped value as `limit` so clients see what they got. `limit < 0` is a 400 with `validation: "limit must be non-negative"`. `limit = 0` resolves to the **default** (100), not zero rows — documented and applied consistently. `offset < 0` is a 400 with `validation: "offset must be non-negative"`.
**Alternative:** 400 on `limit > 500`; or treat `limit=0` as "zero rows."
**Why:** PM spec mandates silent clamp for max (matches `/foods/search`'s existing behavior — it clamps to `SEARCH_MAX_LIMIT=50` today). Negative values are a programming error worth telling the client about. `limit=0` as "default" prevents the foot-gun of a client accidentally fetching nothing when they meant the default.

### 6. `q` filter uses `ILIKE` on `name` and `brands`, not pg_trgm

**Decision:** `WHERE owner_user_id = $1 AND source = 'user' AND ($2::text IS NULL OR name ILIKE '%' || $2 || '%' OR coalesce(brands, '') ILIKE '%' || $2 || '%')`. No trigram operators, no FTS.
**Alternative:** Reuse the existing trigram (`%`) operator from `/foods/search`.
**Why:** Two reasons. (a) Semantics differ — PM specifies "filter my list as I type," not "rank by relevance." A user typing "Mom" expects "Mom's Lasagna" and "Mom's Brownies" in `created_at` order, not trigram-ranked. (b) Trigram needs ≥3 chars to be useful; ILIKE works at 1 char. The trade-off is that ILIKE on a personal library (~200 rows max for a power user) is a trivial filter scan after `foods_owner_idx` narrows the candidate set — `foods_owner_idx` is the load-bearing index, ILIKE just walks the small result. The existing `foods_name_trgm_idx` GIN does support ILIKE through the trigram operator class when the pattern has ≥3 chars, so even multi-thousand-row libraries don't go off-rails. We include `brands` because PM said "if you can cheaply include brands, do" — and it's free under the same scan.

### 7. `FoodSearchHit` projection stays as-is; no `created_at`

**Decision:** Reuse the existing `FoodSearchHit` wire shape verbatim. Do not add `created_at`.
**Alternative:** Extend the hit with `created_at` so clients can render "added 3 days ago."
**Why:** PM's stated reason for matching `/foods/search`'s shape was so mobile can share the row-rendering component. Diverging the projection for one endpoint defeats that. Clients that want detail (including `created_at`, which is on the full `Food`) can hit `GET /foods/:id`. If the "added X days ago" badge proves load-bearing, add it to the projection across all endpoints later — that's a v1.1 decision.

### 8. Total-count strategy: separate `COUNT(*)` query per list call

**Decision:** Each paginated endpoint issues two SQL statements: the page query and a count query, both behind the visibility/filter predicate. Mirror the existing `FoodRepository::search` + `search_count` pattern.
**Alternative:** `COUNT(*) OVER ()` window function in the same query.
**Why:** (a) The split lets `count_in_range`/`count_for_user`/`count_mine` reuse the simpler scan plan without the page's `ORDER BY ... LIMIT ... OFFSET` — Postgres can short-circuit the count over an index-only scan in many cases. (b) It matches the only existing precedent in the codebase. (c) Window-function counts force the planner to fully materialize the filtered set even when `LIMIT` could stop early; for paged endpoints with no `OFFSET` deep enough to matter that's a wash, but for `?offset=400&limit=100` over a heavy logger it adds work. (d) Two round-trips is two round-trips — at ≤1ms apiece it's not measurable.

### 9. No new migration

**Decision:** None of this work requires DDL. Confirmed: `foods_owner_idx` (partial on `owner_user_id WHERE NOT NULL`), `log_user_date_idx`, `weights_user_date_idx` all already exist. The ILIKE substring scan on `foods` after the owner index narrows scope is fine for v1 personal-library sizes.
**Alternative:** Add a `foods_owner_created_idx` on `(owner_user_id, created_at DESC)` to support the sort.
**Why:** The expected per-user library size is ≤200 customs. After `foods_owner_idx` selects those rows, an in-memory sort is sub-microsecond. The new index would only matter if a user had thousands of customs, which v1 doesn't support and which would itself be a separate product conversation.

### 10. `GET /foods/mine` lives in `routes/foods.rs`

**Decision:** Same file as the other `/foods/*` reads.
**Alternative:** New file `routes/foods_mine.rs`.
**Why:** Reads + custom CRUD are already colocated; the file is 527 lines, well under the threshold where splitting would help. The handler is ~10 lines.

### 11. `from > to` returns 400 on both `/log` and `/weights`

**Decision:** `/weights` adopts `/log`'s existing rule. Same message style: `from must be <= to`.
**Alternative:** Treat as "empty range" and return 200 with empty results.
**Why:** PM-required. 400 surfaces client bugs early; silent emptiness obscures them.

## Route shapes

### `GET /foods/mine` (new)

**Query params:**
| Name   | Type       | Default | Range                        | Notes |
|--------|------------|---------|------------------------------|-------|
| `q`    | string     | absent  | trimmed; length 1..=200 if present | Optional. Blank or absent = no filter. |
| `limit`| int64      | 100     | clamped to [1, 500]; `0` → default; negative → 400 | |
| `offset`| int64     | 0       | ≥ 0; negative → 400          | |

**Response (200):**
```json
{
  "results": [
    {
      "id": "uuid",
      "source": "user",
      "name": "string",
      "brand": "string | null",
      "barcode": "string | null",
      "default_serving": { "id": "uuid", "label": "string", "grams": "decimal" } | null,
      "calories_per_serving": "decimal | null"
    }
  ],
  "total": 42,
  "limit": 100,
  "offset": 0
}
```

`source` is always `"user"` here but is left in the projection for shape parity with `/foods/search`.

### `GET /log` (changed)

**Query params:**
| Name    | Type       | Default | Range                 | Notes |
|---------|------------|---------|-----------------------|-------|
| `from`  | date       | absent  | ISO `YYYY-MM-DD`      | Optional. |
| `to`    | date       | absent  | ISO `YYYY-MM-DD`      | Optional. If `from > to`, 400. |
| `limit` | int64      | 100     | clamped to [1, 500]; `0` → default; negative → 400 | |
| `offset`| int64      | 0       | ≥ 0                   | |

Backward compatibility: existing `from`/`to` callers still work, just get at most 100 rows. Existing callers with no params get the most recent 100.

**Response (200):**
```json
{
  "results": [ <existing LogEntryResponse shape, unchanged> ],
  "total": 42,
  "limit": 100,
  "offset": 0
}
```

Sort: `consumed_on DESC, created_at DESC, id DESC` (stable).

### `GET /weights` (changed)

**Query params:** identical to `/log` (with `from`/`to` mapping to `recorded_on`).

**Response (200):**
```json
{
  "results": [ <existing WeightResponse shape, unchanged> ],
  "total": 42,
  "limit": 100,
  "offset": 0
}
```

Sort: `recorded_on DESC, created_at DESC, id DESC`.

### `GET /foods/search` (migrated to shared envelope; wire shape unchanged)

Existing wire shape (`results, total, limit, offset`) is byte-identical — only the Rust DTO it deserializes from changes. Defaults change from `SEARCH_DEFAULT_LIMIT=20`/`SEARCH_MAX_LIMIT=50` to `100`/`500` to unify the contract.

**Wire-impact note:** Bumping defaults on `/foods/search` from `limit=20` default to `limit=100` is a behavior change. PM mandated the unified contract (success criterion bullet "`/log`, `/weights`, and `/foods/search` use the same pagination contract — same parameter names, same envelope, same default + cap, same out-of-range behaviour"). Surface this in the commit message.

## Service-layer signatures

### New shared type — `crates/loseit-core/src/service/page.rs` (new file)

```rust
use crate::{CoreError, CoreResult};

/// Server-wide pagination defaults. Apply consistently across every paged
/// endpoint so the wire contract is one decision.
pub const DEFAULT_PAGE_LIMIT: i64 = 100;
pub const MAX_PAGE_LIMIT: i64 = 500;

/// Generic paginated result. `total` is the full match count (independent
/// of `limit`/`offset`); `results` is the current page.
#[derive(Debug, Clone)]
pub struct Paginated<T> {
    pub results: Vec<T>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

/// Validated + clamped pagination inputs. Produced by `resolve_page_params`.
#[derive(Debug, Clone, Copy)]
pub struct PageParams {
    pub limit: i64,
    pub offset: i64,
}

/// Apply the unified pagination policy:
///   * `None` or `Some(0)` for limit → `DEFAULT_PAGE_LIMIT`
///   * `Some(n)` where `n < 0` → `Validation("limit must be non-negative")`
///   * `Some(n)` where `n > MAX_PAGE_LIMIT` → silently clamp to MAX
///   * `None` for offset → 0
///   * `Some(n)` where `n < 0` → `Validation("offset must be non-negative")`
pub fn resolve_page_params(
    limit: Option<i64>,
    offset: Option<i64>,
) -> CoreResult<PageParams> {
    let limit = match limit {
        None | Some(0) => DEFAULT_PAGE_LIMIT,
        Some(n) if n < 0 => {
            return Err(CoreError::Validation("limit must be non-negative".into()));
        }
        Some(n) => n.min(MAX_PAGE_LIMIT),
    };
    let offset = match offset {
        None => 0,
        Some(n) if n < 0 => {
            return Err(CoreError::Validation("offset must be non-negative".into()));
        }
        Some(n) => n,
    };
    Ok(PageParams { limit, offset })
}
```

Re-export from `service/mod.rs`: `pub use page::{Paginated, PageParams, DEFAULT_PAGE_LIMIT, MAX_PAGE_LIMIT, resolve_page_params};`

### `FoodService` — `crates/loseit-core/src/service/food.rs`

```rust
// Replace SearchPage with the generic Paginated. SearchPage is removed
// (or kept as `pub type SearchPage = Paginated<FoodSearchHit>;` for one
// release if a soft migration is preferred — recommend hard removal).

#[tracing::instrument(skip(self))]
pub async fn search(
    &self,
    viewer: Uuid,
    q: &str,
    limit: Option<i64>,
    offset: Option<i64>,
) -> CoreResult<Paginated<FoodSearchHit>> {
    let trimmed = q.trim();
    if trimmed.is_empty() {
        return Err(CoreError::Validation("query is required".into()));
    }
    let page = resolve_page_params(limit, offset)?;
    let results = self.foods.search(viewer, trimmed, page.limit, page.offset).await?;
    let total = self.foods.search_count(viewer, trimmed).await?;
    Ok(Paginated { results, total, limit: page.limit, offset: page.offset })
}

/// List the caller's user-custom foods. Newest-first by `created_at`,
/// stable on `id`. Optional case-insensitive substring filter on `name`
/// + `brands`. Empty / whitespace `q` is treated as no filter.
#[tracing::instrument(skip(self))]
pub async fn list_mine(
    &self,
    owner: Uuid,
    q: Option<&str>,
    limit: Option<i64>,
    offset: Option<i64>,
) -> CoreResult<Paginated<FoodSearchHit>> {
    let page = resolve_page_params(limit, offset)?;
    let q_filter = q
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| {
            if s.chars().count() > 200 {
                return Err(CoreError::Validation("q must be 200 characters or fewer".into()));
            }
            Ok(s.to_string())
        })
        .transpose()?;
    let results = self.foods.list_mine(owner, q_filter.as_deref(), page.limit, page.offset).await?;
    let total = self.foods.count_mine(owner, q_filter.as_deref()).await?;
    Ok(Paginated { results, total, limit: page.limit, offset: page.offset })
}
```

### `LogService` — `crates/loseit-core/src/service/log.rs`

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

The existing `list_in_range(user, from, to)` is kept (used internally for `day_summary` and unpaginated callers) but the handler stops calling it directly.

### `WeightService` — `crates/loseit-core/src/service/weight.rs`

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

Old `list(user_id, from, to)` signature is removed (no other in-tree callers).

## Repository / SQL changes

### `FoodRepository` trait additions — `crates/loseit-core/src/repo/food.rs`

```rust
/// List the caller's user-custom foods, newest first, with stable id tiebreak.
/// `q` is an optional case-insensitive substring matched against `name` and
/// `brands` (whichever is non-null). Empty/None means no filter.
async fn list_mine(
    &self,
    owner: Uuid,
    q: Option<&str>,
    limit: i64,
    offset: i64,
) -> CoreResult<Vec<FoodSearchHit>>;

async fn count_mine(&self, owner: Uuid, q: Option<&str>) -> CoreResult<i64>;
```

### `LogRepository` trait additions — `crates/loseit-core/src/repo/log.rs`

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

Existing `list_in_range(user, from, to)` is **kept** — `LogService::day_summary` calls `list_for_day`, but other internal call sites may need the bounded variant. Mark `list_in_range` as `#[deprecated]` if it ends up unused after this work; do not remove in this PR.

### `WeightRepository` trait additions — `crates/loseit-core/src/repo/weight.rs`

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

`list_for_user` is removed (no other in-tree callers; signature was only used by the handler).

### SQL — `PgFoodRepository::list_mine` (in `crates/loseit-db/src/food_repo.rs`)

```sql
SELECT f.id,
       f.source::text AS source,
       f.name,
       f.brands,
       f.barcode,
       f.energy_kcal_100g,
       s.id    AS default_serving_id,
       s.label AS default_serving_label,
       s.grams AS default_serving_grams,
       f.created_at
  FROM foods f
  LEFT JOIN servings s ON s.food_id = f.id AND s.is_default
 WHERE f.owner_user_id = $1
   AND f.source = 'user'
   AND ( $2::text IS NULL
         OR f.name ILIKE '%' || $2 || '%'
         OR coalesce(f.brands, '') ILIKE '%' || $2 || '%' )
 ORDER BY f.created_at DESC, f.id DESC
 LIMIT $3 OFFSET $4
```

**Plan expectations:**
- `foods_owner_idx` (partial B-tree on `owner_user_id WHERE owner_user_id IS NOT NULL`) is the access path.
- When `q` is non-null, ILIKE with leading wildcard skips the trigram GIN; expected plan is "Index Scan on `foods_owner_idx` → Filter on `name ILIKE …`." That's the right plan for a personal library scale.
- Sort is performed on the small filtered set; no index on `created_at` needed for v1.

### SQL — `PgFoodRepository::count_mine`

```sql
SELECT count(*)
  FROM foods f
 WHERE f.owner_user_id = $1
   AND f.source = 'user'
   AND ( $2::text IS NULL
         OR f.name ILIKE '%' || $2 || '%'
         OR coalesce(f.brands, '') ILIKE '%' || $2 || '%' )
```

### SQL — `PgLogRepository::list_paginated`

```sql
SELECT <SELECT_COLS>
  FROM food_log_entries
 WHERE user_id = $1
   AND ($2::date IS NULL OR consumed_on >= $2)
   AND ($3::date IS NULL OR consumed_on <= $3)
 ORDER BY consumed_on DESC, created_at DESC, id DESC
 LIMIT $4 OFFSET $5
```

Hits `log_user_date_idx` for the filter; final `id` is the stable tiebreak.

### SQL — `PgLogRepository::count_in_range`

```sql
SELECT count(*)
  FROM food_log_entries
 WHERE user_id = $1
   AND ($2::date IS NULL OR consumed_on >= $2)
   AND ($3::date IS NULL OR consumed_on <= $3)
```

### SQL — `PgWeightRepository::list_paginated`

```sql
SELECT <SELECT_COLS>
  FROM weights
 WHERE user_id = $1
   AND ($2::date IS NULL OR recorded_on >= $2)
   AND ($3::date IS NULL OR recorded_on <= $3)
 ORDER BY recorded_on DESC, created_at DESC, id DESC
 LIMIT $4 OFFSET $5
```

Hits `weights_user_date_idx`.

### SQL — `PgWeightRepository::count_for_user`

```sql
SELECT count(*)
  FROM weights
 WHERE user_id = $1
   AND ($2::date IS NULL OR recorded_on >= $2)
   AND ($3::date IS NULL OR recorded_on <= $3)
```

### In-memory fakes — `crates/loseit-testing/`

Each fake gets the corresponding new method. For `InMemoryFoodRepository::list_mine`:
- Filter by `owner == owner_user_id && source == FoodSource::User`.
- Apply ILIKE-equivalent (`to_lowercase().contains(needle.to_lowercase())`) over `name` and `brands` when `q` is `Some(non-empty)`.
- Sort by `created_at DESC`, then `id` (use `Uuid` ord) for stability.
- Skip/take with `offset`/`limit`.

`InMemoryLogRepository::list_paginated` and `InMemoryWeightRepository::list_paginated` filter by user + optional `from`/`to`, sort by date desc + created_at desc + id, then skip/take.

`count_*` variants do the same filter, return `.len() as i64`.

### Handler-side DTO conversion — `crates/loseit-api/src/routes/pagination.rs` (new file)

```rust
use loseit_core::service::Paginated;
use serde::Serialize;

#[derive(Serialize)]
pub struct PaginatedResponse<T: Serialize> {
    pub results: Vec<T>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

impl<T, R> From<Paginated<T>> for PaginatedResponse<R>
where
    R: Serialize + From<T>,
{
    fn from(p: Paginated<T>) -> Self {
        Self {
            results: p.results.into_iter().map(Into::into).collect(),
            total: p.total,
            limit: p.limit,
            offset: p.offset,
        }
    }
}

#[derive(serde::Deserialize)]
pub struct PageQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}
```

`SearchResponse` in `routes/foods.rs` is replaced by `PaginatedResponse<FoodSearchHitResponse>`.

## Validation rules

| Endpoint | Param  | Rule                                                                                | Trigger |
|----------|--------|-------------------------------------------------------------------------------------|---------|
| All paged | `limit` | < 0 → 400; > 500 → silent clamp; 0 or absent → 100                                 | service |
| All paged | `offset`| < 0 → 400; absent → 0; no upper bound                                              | service |
| `/foods/search` | `q` | trimmed; empty → 400 (unchanged)                                              | service |
| `/foods/mine` | `q` | optional; trimmed; empty/whitespace → no filter; length > 200 chars → 400        | service |
| `/log` | `from`,`to` | both optional; if both present and `from > to` → 400                           | service |
| `/weights` | `from`,`to` | both optional; if both present and `from > to` → 400                       | service |

Non-integer `limit`/`offset` and non-ISO-date `from`/`to` are caught by axum's `Query` deserialization and surface as 400 (axum default), not via our `ApiError` validation path. That's existing behavior — no change.

## Error paths

| Failure                              | Maps to                                          | Wire status / code                |
|--------------------------------------|--------------------------------------------------|-----------------------------------|
| `limit < 0`                          | `CoreError::Validation`                          | 400 `bad_request`                 |
| `offset < 0`                         | `CoreError::Validation`                          | 400 `bad_request`                 |
| `q.len() > 200` on `/foods/mine`     | `CoreError::Validation`                          | 400 `bad_request`                 |
| `from > to`                          | `CoreError::Validation`                          | 400 `bad_request`                 |
| Non-integer `limit`/`offset`         | axum query deserialize error                     | 400 (axum default body)           |
| Non-ISO date `from`/`to`             | axum query deserialize error                     | 400 (axum default body)           |
| DB error                             | `CoreError::Internal`                            | 500 `internal_error`              |
| Missing/invalid auth                 | `AuthError::Missing`/`Invalid`                   | 401                               |
| Empty result set (no matches)        | n/a — success                                    | 200 with `results: [], total: 0`  |
| `limit > 500`                        | n/a — silently clamped                           | 200 with `limit: 500` in body     |
| `limit = 0`                          | n/a — resolves to default                        | 200 with `limit: 100` in body     |
| `q = ""` on `/foods/mine`            | n/a — treated as absent                          | 200 (all rows)                    |

## Tests to add

### Unit tests in `crates/loseit-core/src/service/page.rs`
- `resolve_page_params_applies_default_when_limit_none`
- `resolve_page_params_applies_default_when_limit_zero`
- `resolve_page_params_clamps_limit_above_max`
- `resolve_page_params_passes_limit_within_range`
- `resolve_page_params_rejects_negative_limit`
- `resolve_page_params_rejects_negative_offset`
- `resolve_page_params_defaults_offset_to_zero_when_none`

### Unit tests in `crates/loseit-core/src/service/food.rs` (new test module)
- `list_mine_returns_only_callers_user_customs` — seed an OFF food, the caller's custom, and another user's custom; expect 1 result, the caller's.
- `list_mine_excludes_off_foods` — explicit assertion the OFF food is filtered out.
- `list_mine_orders_newest_first` — three customs created at distinct timestamps; assert reverse-chrono order.
- `list_mine_filters_by_q_case_insensitive` — seed "Mom's Lasagna" and "Dad's Chili"; `q="mom"` returns just the lasagna.
- `list_mine_q_matches_brand` — confirms `brands` is in the haystack.
- `list_mine_blank_q_returns_all` — `q=Some("")` and `q=Some("   ")` both behave like `q=None`.
- `list_mine_clamps_limit_above_max` — `limit=Some(10_000)` returns at most 500.
- `list_mine_default_limit_is_100` — when `limit=None`, response carries `limit: 100`.
- `list_mine_rejects_q_over_200_chars` — 400.
- `list_mine_total_independent_of_pagination` — seed 5 customs, request `limit=2`; `total` reads 5.

### Unit tests in `crates/loseit-core/src/service/log.rs`
- `list_returns_paginated_envelope_with_total`
- `list_rejects_from_after_to`
- `list_orders_newest_first_with_id_tiebreak`
- `list_clamps_limit_above_max`
- `list_with_no_filters_returns_most_recent_default_page` — confirms the implicit "most recent N" behavior.

### Unit tests in `crates/loseit-core/src/service/weight.rs`
- Mirror the four `list_*` tests above for weights.

### Integration tests in `crates/loseit-api/tests/http_foods.rs`
- `test_foods_mine_returns_only_callers_customs`
- `test_foods_mine_orders_by_created_at_desc`
- `test_foods_mine_filters_by_q_substring_case_insensitive`
- `test_foods_mine_empty_when_no_customs` — confirms 200 + `{results: [], total: 0}` not 404.
- `test_foods_mine_default_limit_is_100`
- `test_foods_mine_clamps_limit_at_500`
- `test_foods_mine_negative_limit_returns_400`
- `test_foods_mine_pagination_does_not_overlap`
- `test_foods_search_default_limit_is_now_100` — guards the contract unification.

### Integration tests in `crates/loseit-api/tests/http_log.rs`
- `test_log_list_response_envelope_has_results_total_limit_offset` — confirms the wire-shape change.
- `test_log_list_returns_total_independent_of_limit`
- `test_log_list_with_no_from_to_returns_most_recent_default_page`
- `test_log_list_clamps_limit_at_500`
- `test_log_list_pagination_does_not_overlap`
- Update existing `test_get_log_filters_by_date_range_and_user` to read from `body["results"]` instead of `body.as_array()`.

### Integration tests in `crates/loseit-api/tests/http.rs` (or new `http_weights.rs`)
- `test_weights_list_response_envelope_has_results_total_limit_offset`
- `test_weights_list_rejects_from_after_to_with_400`
- `test_weights_list_orders_newest_first`
- `test_weights_list_clamps_limit_at_500`
- Update existing `weight_post_then_list_round_trip` to read from `body["results"]`.

### Migration of existing `/foods/search` tests
- `test_search_returns_lean_hits` — currently asserts `body["limit"] == 20`; update to `100`.
- Any test asserting the old `SEARCH_MAX_LIMIT=50` clamp gets updated to 500.

## Migration / deploy notes

- **No SQL migration.** All required indexes (`foods_owner_idx`, `log_user_date_idx`, `weights_user_date_idx`) exist in `0001_initial.sql`.
- **Wire-shape breaking changes** (no production clients today, per PM):
  - `GET /log` body: bare array → `{results, total, limit, offset}`.
  - `GET /weights` body: bare array → `{results, total, limit, offset}`.
  - `GET /foods/search` default `limit` changes from 20 to 100; max changes from 50 to 500.
- Document these in the commit message as "pre-v1 wire change."
- No env vars added.
- No new dependencies (uses `sqlx`, `axum`, `serde`, `uuid`, `chrono`, `rust_decimal` already in `Cargo.toml`).
- Tracing: new service methods carry `#[tracing::instrument(skip(self))]` matching the convention in `LogService` / `WeightService`.

## Order of implementation

Each step is independently mergeable and testable. Recommended sequence:

1. **Land `Paginated<T>` + `PageParams` + `resolve_page_params` in `loseit-core::service::page`.** Pure addition. Unit tests for the resolver. Re-export from `service/mod.rs`. No callers yet.

2. **Land `PaginatedResponse<T>` + `PageQuery` in `loseit-api::routes::pagination`.** Pure addition. No callers yet.

3. **Migrate `/foods/search` to the shared types.** `SearchPage` → `Paginated<FoodSearchHit>`. `SearchResponse` → `PaginatedResponse<FoodSearchHitResponse>`. Bump default to 100 and max to 500 (`SEARCH_DEFAULT_LIMIT`/`SEARCH_MAX_LIMIT` constants removed in favor of `DEFAULT_PAGE_LIMIT`/`MAX_PAGE_LIMIT`). Update existing `/foods/search` tests to match new defaults. Wire shape unchanged so existing integration tests stay green modulo the limit number.

4. **Add `LogRepository::list_paginated` + `count_in_range`** (trait + Pg impl + in-memory fake). Repo-level tests on the fake (sort stability, filter combinations). No service or handler changes yet.

5. **Wire `LogService::list` to the new repo methods, change handler.** Drop the in-handler sort (it moves to SQL). Update tests in `http_log.rs` to read `body["results"]`. Keep `list_in_range` on the repo + service for `day_summary`.

6. **Add `WeightRepository::list_paginated` + `count_for_user`** (trait + Pg impl + in-memory fake). Drop `list_for_user`. Repo-level tests.

7. **Wire `WeightService::list` to the new repo methods, change handler.** Update tests in `http.rs` (or factor a new `http_weights.rs`) to read `body["results"]` and add the new pagination assertions.

8. **Add `FoodRepository::list_mine` + `count_mine`** (trait + Pg impl + in-memory fake). Repo-level tests on the fake — visibility, sort, ILIKE.

9. **Add `FoodService::list_mine`** + service unit tests.

10. **Add `GET /foods/mine` handler in `routes/foods.rs`** + integration tests. Register the route *before* the `/:id` catch-all (matchit ordering note — `/foods/mine` would otherwise collide). See the existing `Order note` comment in `routes/foods.rs` for the established pattern.

Steps 1–3 unblock everything else; 4–7 and 8–10 are independent and can be parallelized after step 3.
