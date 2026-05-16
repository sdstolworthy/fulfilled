# v1 Finish-up — Architect Design

Six-item batch closing out the v1 server surface: finish unified pagination, add the two log conveniences PM signed off on (quick-add, copy-day), ship the JWKS authenticator, ship account lifecycle (delete-me + async data export), and keep `openapi.yaml` in lockstep.

The TPM should be able to slice this into ordered tasks without coming back for clarifications.

---

## 1. Overview

Pagination foundation already landed in this worktree (commit `133eb84`): `loseit_core::service::page::{Paginated<T>, PageParams, resolve_page_params}` with `DEFAULT_PAGE_LIMIT=100` / `MAX_PAGE_LIMIT=500` (`server/crates/loseit-core/src/service/page.rs`) plus `loseit_api::routes::pagination::{PaginatedResponse<T>, PageQuery}` (`server/crates/loseit-api/src/routes/pagination.rs`); `/foods/search` is migrated. This batch fans the same envelope out to `/foods/mine` (new), `/log`, `/weights`; adds `POST /log/quick_add`, `POST /log/copy`, `DELETE /me`, async export (`POST /me/export` + `GET /me/export/:job_id`); ships a provider-agnostic JWKS authenticator; updates `openapi.yaml` plus the sodium-units note.

Out of scope: cursor pagination, soft deletes, recipes, real-time export streaming, weight-trend / insight endpoints, CSV export, S3/GCS-specific bindings (abstraction + local-filesystem impl ship; bucket binding is a later swap).

---

## 2. Per-item designs

### Item 1 — `GET /foods/mine` + paginated `/log` and `/weights`

The prior architect note (`server/specs/audit_followup_arch.md:216-866`) is the canonical design; this section ratifies it and notes the PM amendment on default behaviour when `from`/`to` are omitted.

#### `GET /foods/mine` (new)

- **Contract.** `GET /api/v1/foods/mine`. Query: `q: Option<String>` (trim; empty = no filter; >200 chars → 400), `limit: Option<i64>`, `offset: Option<i64>` — deserialise via a route-local `MineQuery` (don't reuse `PageQuery` because of `q`). Response 200: `PaginatedResponse<FoodSearchHitResponse>` (`source` is always `"user"`). 400 on bad inputs, 401 on missing auth.
- **Service.** `FoodService::list_mine(owner, q: Option<&str>, limit, offset) -> CoreResult<Paginated<FoodSearchHit>>` in `service/food.rs`. Validation in service; `resolve_page_params` owns clamp/default.
- **Repo.** Add to `FoodRepository` (`repo/food.rs`): `list_mine` + `count_mine`. Pg SQL: `WHERE owner_user_id=$1 AND source='user' AND ($2::text IS NULL OR name ILIKE '%' || $2 || '%' OR coalesce(brands,'') ILIKE '%' || $2 || '%') ORDER BY created_at DESC, id DESC LIMIT $3 OFFSET $4`. Index path: `foods_owner_idx`. Default-serving joined in the same query (no N+1). In-memory fake in `loseit-testing/src/foods.rs`.
- **Migration.** None — `foods_owner_idx` exists at `migrations/0001_initial.sql:126`.
- **Edge cases.** Zero customs → 200 `results: []`, `total: 0`. Another user's customs never appear. OFF foods the caller logged never appear. `q=""` / whitespace → treated as absent. `limit=0` → 100. Sentinel `__quick_add__` food filtered out (see Item 2).

#### `GET /log` (changed — wire break)

- **Contract.** Query: `from`/`to: Option<NaiveDate>` (both now **optional**), `limit`/`offset: Option<i64>`. Replace `RangeQuery` (`routes/log.rs:93`) with `ListLogQuery`. Response 200: `PaginatedResponse<LogEntryResponse>` (per-row shape unchanged). 400 on `from > to` or negative bounds.
- **Service.** Add `LogService::list(user, from, to, limit, offset) -> Paginated<FoodLogEntry>`. **Keep** existing `list_in_range` — `day_summary` uses `list_for_day` separately and other internal callers may still want the unbounded variant.
- **Repo.** Add to `LogRepository`: `list_paginated` + `count_in_range` (`Option<NaiveDate>` both ends). Pg SQL: `WHERE user_id=$1 AND ($2::date IS NULL OR consumed_on>=$2) AND ($3::date IS NULL OR consumed_on<=$3) ORDER BY consumed_on DESC, created_at DESC, id DESC LIMIT $4 OFFSET $5`. Index path: `log_user_date_idx` (`0001_initial.sql:236`). No N+1.
- **Migration.** None.
- **Edge cases.** No params → most-recent 100 log rows across all history. `from`/`to` alone or together still honoured. `from > to` → 400. Sort triple `(consumed_on, created_at, id)` is stable — pagination never duplicates or drops rows.

#### `GET /weights` (changed — wire break)

- **Contract.** Query: `from`/`to: Option<NaiveDate>`, `limit`/`offset: Option<i64>`. Replace `ListQuery` (`routes/weights.rs:29`). Response 200: `PaginatedResponse<WeightResponse>`. 400 on `from > to` (new for `/weights`) or negative bounds.
- **Service.** Rewrite `WeightService::list` (`service/weight.rs:25`) to return `Paginated<Weight>`.
- **Repo.** Replace `WeightRepository::list_for_user` (no other callers) with `list_paginated` + `count_for_user`. Pg SQL mirrors log on `recorded_on`. Index path: `weights_user_date_idx`. Sort: `recorded_on DESC, created_at DESC, id DESC`.
- **Migration.** None.
- **Edge cases.** No params → full history capped at page limit, newest first.

---

### Item 2 — `POST /log/quick_add`

Log raw calories without choosing a food. Backed by a per-user sentinel "Quick Add" food auto-provisioned on first use.

- **Contract.** `POST /api/v1/log/quick_add`. Body `QuickAddBody { calories_kcal: Decimal (>0, <100_000), meal: String, consumed_on: NaiveDate, note: Option<String> }`. Response 201: `LogEntryResponse`. The entry references the caller's sentinel food + its synthetic 100 g serving. Macros (`protein_g`/etc.) are **null** in the snapshot; only `calories_kcal` carries a value. 400 on validation, 401 on auth.
- **Sentinel encoding.** Sentinel food has `energy_kcal_100g = 1` (1 kcal per 100 g). Its default serving has `grams = 100`, `label = "kcal"`, `is_default = true`, `source = 'system'`. A quick-add of `calories_kcal = N` writes a log entry with `quantity = N`, `grams_total = N * 100` rounded to `NUMERIC(10,2)`. Computing the snapshot via the existing `LogService::compute_snapshot` then yields exactly `N` kcal with all macros null (because the sentinel food's macro fields are null) — no special-case snapshot constructor required.
- **Service.** Add `LogService::quick_add(user, calories_kcal, meal, consumed_on, note)`. Internally calls `FoodRepository::find_or_create_quick_add(user) -> (Food, Serving)`, then reuses the normal create path (`compute_snapshot` + `logs.create`) — the snapshot naturally drops to "only calories" because the sentinel food has null macros.
- **Repo.** Add `FoodRepository::find_or_create_quick_add(&self, owner: Uuid) -> CoreResult<(Food, Serving)>`. Pg impl: `INSERT … ON CONFLICT … DO UPDATE SET updated_at=now() RETURNING …` against the new partial unique index `foods_quick_add_singleton`, plus a `SELECT` of its default serving. Idempotent under concurrent first-uses.
- **Migration.** New `0005_quick_add_sentinel.sql` — partial unique index only; no new table. See Section 4.
- **Edge cases.** `calories_kcal <= 0` or `>= 100_000` → 400 (mirrors existing `grams_total` overflow guard at `service/log.rs:124`). The sentinel is hidden from `/foods/search`, `/foods/mine`, `/foods/recent`, `/foods/frequent` via `AND name <> '__quick_add__'` in those queries. `GET /foods/:id` on the sentinel returns it normally (acceptable — clients don't know the id). `PATCH`/`DELETE /foods/:id` on the sentinel return `Forbidden` at the service layer. `POST /foods` with `name='__quick_add__'` rejected as `Validation("name is reserved")`. `DELETE /me` cleans it up via the existing `ON DELETE CASCADE` chain.

---

### Item 3 — `POST /log/copy`

Bulk-copy a day's entries to another day, re-snapshotting nutrition.

- **Contract.** `POST /api/v1/log/copy`. Body `CopyDayBody { from_date: NaiveDate, to_date: NaiveDate, meal: Option<String> }`. Response 201: `CopyDayResponse { copied: Vec<LogEntryResponse> }` (wrapped, not bare array, so a `skipped` counter can be added later without breaking the wire). 400 on invalid `meal` string, 401 on auth.
- **Service.** `LogService::copy_day(user, from_date, to_date, meal: Option<Meal>) -> Vec<FoodLogEntry>`. Algorithm: fetch source entries via `logs.list_for_day(user, from_date)`; optionally filter by `meal`; for each, re-resolve `food` (`foods.find_by_id`) and `serving` (`servings.find_by_id`) — skip silently when either is `None` (food deleted / cross-tenant / serving deleted). Recompute `grams_total = serving.grams * e.quantity` rounded to `NUMERIC(10,2)`, then `snapshot = LogService::compute_snapshot(&food, grams_total)` — **re-snapshot from the *current* food, not `e.snapshot`**, per PM ("custom-food edit between dates doesn't bleed through"). Insert via new `LogRepository::create_many` in one transaction.
- **Repo.** `LogRepository::create_many(&self, user_id: Uuid, entries: &[PersistedLogEntry]) -> CoreResult<Vec<FoodLogEntry>>`. Pg impl: single `INSERT … RETURNING …` over `UNNEST` arrays, mirroring the `upsert_off_batch` pattern at `food_repo.rs`. No N+1.
- **Migration.** None.
- **Edge cases.** `from_date == to_date` allowed. `from_date > to_date` allowed (copy backward is legitimate). Source day empty → 201 with `copied: []`. Deleted serving / cross-tenant food → skipped silently, logged at `tracing::info`. Document the skip rule in the OpenAPI description. `to_date` already has entries → new entries coexist (per PM, no replace). Quick-add sentinel entries copy fine (sentinel food is stable). All-or-nothing tx: full success or full rollback.

---

### Item 4 — JWKS authenticator

Wire up the unimplemented `AuthConfig::Jwks` branch (`server.rs:158`) with a provider-agnostic validator.

- **Contract.** No new endpoints. `require_auth` middleware (`auth/mod.rs:32`) already calls `state.authenticator.authenticate(token)` — that's the seam.
- **Module.** `server/crates/loseit-api/src/auth/jwks.rs`. Sibling of `DevAuthenticator`; implements `loseit_core::auth::Authenticator`. Holds: `issuer: String`, `audience: String`, `jwks: Arc<JwksCache>`, `http: reqwest::Client`. The cache holds `RwLock<HashMap<String /* kid */, DecodingKey>>` + `Instant fetched_at` + a `tokio::sync::Mutex<()>` that serialises refresh so concurrent miss-handlers coalesce.
- **Per-request algorithm.** (1) `jsonwebtoken::decode_header` to read `kid`, `alg`. (2) Cache lookup. (3) On miss or expired TTL, force-refresh under the mutex; re-look up. Still missing → `AuthError::Invalid`. (4) Validate with `jsonwebtoken::decode::<Claims>` against a pre-built `Validation` that asserts `iss`, `aud`, `exp`, `nbf` (60s leeway), `iat`, with `algorithms` whitelisted to `RS256/RS384/RS512/ES256/ES384` — **never** `HS*`. (5) Map claims into `UserIdentity { issuer: claims.iss, external_id: claims.sub, email, display_name: claims.name }`. The existing `users.ensure_user` step in `require_auth` (`auth/mod.rs:43`) auto-provisions on first sight unchanged.
- **Crate choice.** `jsonwebtoken = "9"` (RFC-7517 JWK → `DecodingKey` parsing; ubiquitous; unopinionated about fetch) plus `reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "json"] }` to match `sqlx`'s `runtime-tokio-rustls` TLS stack. Owning the cache lets us tracing-instrument refreshes; `jwks-client-rs` ships its own opinions, which we don't want.
- **Config.** Extend `AuthConfig::Jwks` (`config.rs:29`) with `audience: String` and `cache_ttl_secs: u64` (default 600). Env vars: `OIDC_ISSUER` (exists), `OIDC_AUDIENCE` (new, required), `OIDC_JWKS_URL` (exists), `OIDC_JWKS_CACHE_TTL_SECS` (new, optional). Loaded in `load_auth` (`config.rs:56`). Document in `README.md`.
- **Composition root.** `build_authenticator` (`server.rs:136`) handles `AuthConfig::Jwks` by constructing `JwksAuthenticator::new(...).await?`. `build_state` becomes `async`; the `main.rs` call site is already async.
- **Error → HTTP.** Token errors → `AuthError::Invalid` → 401. Upstream JWKS fetch failure → `AuthError::Upstream(...)` → **503** (new mapping in `loseit-api/src/error.rs`). 503 is accurate and won't get cached as "user logged out" by clients.
- **Edge cases.** No `kid` → 401. `alg=none` or `alg=HS*` → 401 (validator rejects). 60s skew leeway. JWKs with `use != "sig"` filtered at parse. Empty JWKS set → all subsequent tokens 401. Audience as array containing configured value → accepted (`jsonwebtoken` handles).
- **Tests.** Unit tests in `auth/jwks.rs` against synthetic JWKS + tokens signed with a generated RSA test key (`rsa` crate + `jsonwebtoken::EncodingKey`). Integration test in `tests/http.rs` using `wiremock` to serve a JWKS document.
- **Migration / OpenAPI.** None.

---

### Item 5 — Account lifecycle (`DELETE /me` + async data export)

Two endpoints with different runtime shapes: delete is synchronous + cascading; export is async with a job table.

#### `DELETE /me` (synchronous cascade)

- **Contract.** `DELETE /api/v1/me`. No body. 204 on success, 401 on auth, 500 on DB.
- **Service.** `UserService::delete_self(user_id)` delegates entirely to `UserRepository::delete_user`.
- **Repo.** `UserRepository::delete_user(user_id)` runs one transaction (full SQL in Section 3, *Cascading delete order*). Order matters because `food_log_entries.food_id` is `ON DELETE RESTRICT` (`0001_initial.sql:209`) — log entries must be deleted before user-owned foods; everything else cascades. Servings on user-owned foods drop via the `foods` cascade (`0001_initial.sql:135`).
- **Migration.** None for the cascade itself — existing tables already CASCADE from `users.id`. The new `export_jobs` table (Item 5b) declares `ON DELETE CASCADE` on `user_id`.
- **Edge cases.** 0-row user → 204. In-flight export job → pre-marked failed; the runner double-checks status before writing storage. Subsequent requests with the same token → 401 (the auth middleware re-resolves the user every request; no cache).

#### Async data export

- **Contracts.**
  - `POST /api/v1/me/export` — no body. 202 with `{ job_id, status: "pending", created_at }`. **Idempotent on pending:** if the caller already has a pending job, return it as 200 with the same body. 401 on auth.
  - `GET /api/v1/me/export/:job_id` — path `job_id: Uuid`. 200 with `ExportJobResponse { job_id, status: "pending"|"ready"|"failed"|"expired", created_at, updated_at, signed_url?: String, expires_at?: DateTime<Utc>, error?: String }`. 404 when not found OR not the caller's (no info leak). 401 on auth.
- **Domain.** New `loseit-core/src/domain/export.rs`: `enum ExportStatus { Pending, Ready, Failed }` (no `Expired` in DB; computed at GET time from `expires_at < now()`); `struct ExportJob { id, user_id, status, storage_key: Option<String>, error: Option<String>, created_at, updated_at, expires_at: Option<DateTime<Utc>> }`.
- **Service.** New `ExportService` in `loseit-core/src/service/export.rs` holding the job + storage traits plus every per-user repo (foods, servings, logs, weights, goals, users). Methods: `enqueue(user_id)` (insert-or-get pending, then push id to runner channel); `get(user_id, job_id)` (read + signed-url on ready); `run(job_id)` (assemble → upload → mark ready). Assembly pulls all rows per table by looping `list_paginated`/`list_mine`/etc. until empty (no new "dump_all" methods needed).
- **Repo.** New `ExportJobRepository` (`loseit-core/src/repo/export.rs`):
  - `insert_or_get_pending(user_id) -> ExportJob` — `INSERT … ON CONFLICT (user_id) WHERE status='pending' DO UPDATE SET updated_at=now() RETURNING …`.
  - `find(user_id, job_id) -> Option<ExportJob>` — scoped by user.
  - `mark_ready(job_id, storage_key, expires_at)`; `mark_failed(job_id, error)`.
  - `list_pending() -> Vec<ExportJob>` — startup recovery.
  Pg impl in `loseit-db/src/export_repo.rs`; fake in `loseit-testing/src/exports.rs`.
- **Bundle.** Single gzipped JSON `export-{user_id}-{job_id}.json.gz`:
  ```
  { schema_version: 1, exported_at, user, foods, servings, log_entries, weights, goals }
  ```
  Only the user's own customs (not OFF/USDA foods). For 5y of heavy logging this is a few MB; safe to assemble in-memory.
- **Migration.** New `0006_export_jobs.sql` — see Section 4 for full SQL (CREATE TABLE + the partial unique index `export_jobs_one_pending_per_user` + two supporting indexes + `set_updated_at` trigger).
- **Edge cases.** POST with pending → returns it (200). POST with non-expired ready → **creates a fresh pending** (user wants a re-snapshot; the unique index is on pending only, so no conflict). POST with expired ready → fresh pending. GET on someone else's job → 404. GET on ready+expired → response status `"expired"`, no signed_url. Concurrent user-delete → `find` returns `None`, 404. Server restart with pending jobs → `list_pending()` on `build_state` re-enqueues into the runner; runner re-checks status before each storage write.

---

### Item 6 — OpenAPI lockstep + sodium note

Single-file edit pass on `server/specs/openapi.yaml`. Concrete changes:

1. **`NutritionPer100g.sodium_g`** (line 841): expand description to `Sodium in grams per 100 g (OFF convention). Clients should multiply by 1000 to display as milligrams, which is the customer-expected unit.`
2. **`/foods/search` GET** (line 253): description note that default `limit=100`, max `500`. No structural change.
3. **New `Paginated` base schema** in components plus `PaginatedFoodSearchHits`, `PaginatedLogEntries`, `PaginatedWeights` (each `allOf: [Paginated, { properties: { results: [items of T] } }]`). Drop `FoodSearchPage` and point `/foods/search` at `PaginatedFoodSearchHits` instead.
4. **New path `/foods/mine`** (operationId `list_my_foods`) with `q?`, `limit?`, `offset?` and response `PaginatedFoodSearchHits`.
5. **`/log` GET** (line 526): `from`/`to` become `required: false`; add `limit?`/`offset?`; response → `PaginatedLogEntries`.
6. **`/weights` GET** (line 128): add `limit?`/`offset?`; response → `PaginatedWeights`.
7. **New path `/log/quick_add`** POST with `QuickAddBody` and `LogEntry` response.
8. **New path `/log/copy`** POST with `CopyDayBody` and `CopyDayResponse` schemas.
9. **Extend `/me` block** (line 75) with DELETE.
10. **New paths `/me/export`** POST and `/me/export/{job_id}` GET with `ExportJobResponse` schema (four-state enum).
11. Top-of-file changelog note documenting the v1-pre-release wire-shape break on `/log` and `/weights`.

---

## 3. Cross-cutting decisions

### `Paginated<T>` adoption strategy (`/log`, `/weights`)

`total` queries share the WHERE of the page query minus `ORDER BY/LIMIT/OFFSET` — two SQL round-trips per request, mirroring the `search`/`search_count` split. `EXPLAIN` should show `Aggregate -> Index Scan` on `log_user_date_idx` / `weights_user_date_idx`. Default sort both: `<date_col> DESC, created_at DESC, id DESC`. With `from`/`to` omitted the predicate degenerates to `WHERE user_id = $1`; the default-limit cap keeps it a bounded scan along the same index. Concretely: `/log` with no params returns the 100 most-recent rows across all history; `/weights` likewise; `total` always reflects the full unpaginated match count.

Keep the existing `LogRepository::list_in_range` and `LogService::list_in_range` — `day_summary` doesn't go through them (it uses `list_for_day`), but they're cheap to leave around and a future Phase-3 cleanup can rip them out.

### Quick-Add sentinel food strategy

**Per-user singleton**, identified by `(owner_user_id, name='__quick_add__', source='user')`. Owned by the user, lives in the `foods` table, follows their `ON DELETE CASCADE` chain. Hidden from:
- `GET /foods/search`: add `AND f.name <> '__quick_add__'` to the existing search SQL in `PgFoodRepository::search` / `search_count`.
- `GET /foods/mine`: same filter on the new `list_mine` / `count_mine` SQL.
- `GET /foods/recent`: filter the resulting `Vec<Uuid>` against `foods.name = '__quick_add__'` in `hydrate_hits` (`service/log.rs:362`) — there's a single SQL exclusion in the repo SQL too: `AND foods.name <> '__quick_add__'` in the `JOIN` already.
- `GET /foods/frequent`: same.

Visible from:
- `GET /foods/:id` (caller's own only): visible — but undocumented, and a normal client won't have the id.

**Not editable.** `FoodService::update_custom` and `FoodService::delete_custom` short-circuit with `CoreError::Forbidden` when `food.name == "__quick_add__"`.

**Provisioning.** First call to `POST /log/quick_add` triggers `find_or_create_quick_add`, which is a single `INSERT … ON CONFLICT DO UPDATE … RETURNING …` plus a `SELECT` of the synthetic 100 g serving. Idempotent under concurrency thanks to the partial unique index added in `0005_quick_add_sentinel.sql`.

Snapshot semantics: macros stay `None`, calories are exactly the requested value.

### JWKS authenticator architecture

See Item 4 above. Single-paragraph recap: `auth/jwks.rs` houses a `JwksAuthenticator` implementing `loseit_core::auth::Authenticator`; `jsonwebtoken = "9"` + `reqwest = "0.12"` (rustls) underpin it; cache is an in-process `RwLock<HashMap<kid, DecodingKey>>` with `Mutex<()>`-serialised refresh on TTL expiry or `kid` miss; validation asserts `iss`/`aud`/`exp`/`nbf`/`iat` with 60s leeway and a `RS*/ES*` algorithm whitelist; 401 on token errors, 503 on JWKS upstream errors. `AuthConfig::Jwks` extends with `audience` and `cache_ttl_secs`.

### Export-job storage abstraction

**Trait** `ExportStorage` in `loseit-core/src/repo/export_storage.rs`:
- `put(key, body: Bytes, content_type) -> String` (returns canonical key)
- `signed_url(key, ttl: Duration) -> String`
- `delete(key) -> ()`

Shallow on purpose — future bucket bindings don't need to know about retries / multipart.

**v1 impl: local filesystem.** `loseit-db/src/local_export_storage.rs` (no new crate; avoid premature factoring). Config: `LOSEIT_EXPORT_DIR` env var (default `./exports`). `signed_url` returns a URL pointing at a new **public** route `GET /api/v1/me/export/file/:token`, where `token = base64(HMAC-SHA256(LOSEIT_EXPORT_HMAC_SECRET, key || expires_at) || key || expires_at)`. The route is intentionally unauthenticated — the HMAC is the auth. Bytes stream from disk via `tokio::fs::File`. Production swaps an `S3ExportStorage` / `GcsExportStorage` at the composition root; we ship the abstraction now and the bucket later.

**Job runner.** In-process: a `tokio::sync::mpsc::UnboundedSender<Uuid>` on `AppState`. `ExportService::enqueue` writes the row then sends the id; a `tokio::spawn`-ed worker in `build_state` loops on the receiver and calls `export_service.run(job_id).await`. Errors → `mark_failed(err)`. **Startup recovery**: `build_state` calls `export_jobs.list_pending()` and re-enqueues every id, so a crashed server picks up where it left off. The runner double-checks `find(...).status == Pending` before each storage write so a concurrent `DELETE /me` cancellation is honoured.

Sync-vs-async: client-facing POST is synchronous (returns 202 immediately); the work is async background. **No separate worker binary in v1** — one container is the deploy unit. Extract to a binary if/when workload demands horizontal scale.

### Cascading delete order

`UserRepository::delete_user(user_id)` runs one transaction:

```sql
BEGIN;
UPDATE export_jobs SET status='failed', error='user deleted', updated_at=now()
  WHERE user_id = $1 AND status = 'pending';
DELETE FROM food_log_entries WHERE user_id = $1;
DELETE FROM weights          WHERE user_id = $1;
DELETE FROM goals            WHERE user_id = $1;
DELETE FROM foods            WHERE owner_user_id = $1 AND source = 'user'; -- cascades to servings
DELETE FROM export_jobs      WHERE user_id = $1;
DELETE FROM users            WHERE id = $1;
COMMIT;
```

Order rationale: `food_log_entries.food_id` is `ON DELETE RESTRICT` (`0001_initial.sql:209`), so log entries must clear before user foods. Weights / goals / export_jobs cascade naturally on the `users` FK but are listed explicitly so the "what cleans up a user" surface is one SQL block. If a job is in flight at delete time, the runner re-reads `status` before its next write and bails on non-pending; worst case a small file is orphaned on disk — an out-of-band sweep handles that. Acceptable for v1.

---

## 4. Migration plan

Existing migrations end at `0004_foods_data_type.sql`. Next sequential numbers:

1. **`0005_quick_add_sentinel.sql`** — partial unique index on the sentinel food.
   ```sql
   -- Per-user singleton for the /log/quick_add sentinel food. Allows
   -- INSERT … ON CONFLICT to be the idempotent provisioning path.
   CREATE UNIQUE INDEX foods_quick_add_singleton
     ON foods(owner_user_id)
     WHERE source = 'user' AND name = '__quick_add__';
   ```

2. **`0006_export_jobs.sql`** — new table + indexes (see SQL in item 5 above).

No other DDL is required for items 1–4. Item 1 reuses `foods_owner_idx`, `log_user_date_idx`, `weights_user_date_idx` (all in `0001_initial.sql`).

---

## 5. Risks and open questions

- **JWKS audience semantics.** Some providers (Google) put `aud` as a single string; others (Auth0) put it as an array including the API identifier. `jsonwebtoken::Validation::set_audience` handles both, but we should test against at least one real JWKS in CI before declaring this done. **Action:** TPM should add a wiremock-backed integration test as part of the JWKS task; production smoke can wait until a real OIDC binding is chosen.
- **Quick-add sentinel name collision.** A user could in principle create a normal custom called `__quick_add__` via `POST /foods` before they ever quick-add. The `0005` partial unique index would then reject the sentinel insert. **Mitigation:** in `FoodService::create_custom`, reject `name == "__quick_add__"` with `CoreError::Validation("name is reserved")`. Mention in the OpenAPI `FoodCreate` description.
- **Export bundle size.** A heavy user with 5 years of data is on the order of ~50k rows. JSON-gzipped that's a few MB. Fine in-memory; just don't materialise without streaming if we ever hit 10× that. **Action:** TPM should keep the in-memory assembly for v1 but flag in the commit message that streaming is a future task if a user complains.
- **Signed-URL token replay.** The HMAC scheme above doesn't bind the token to a specific user; the user is implicit in the key. If two users requested the same job id (impossible since UUIDs are not predictable) they'd share access. Acceptable.
- **`/log/copy` and quick-add entries.** A user copies a day whose entries include a quick-add. Re-snapshotting the sentinel food gives the same calories. **Confirmed acceptable**, but worth a unit test.
- **`from > to` on `/log/copy` not rejected.** This is a feature — copying forward and backward in time is legitimate. Don't add the check that's on `/log` GET.

---

## 6. Suggested task order

Each unit is ~200–500 LOC. Arrows show dependencies; everything else is parallelisable.

1. **`/foods/mine` repo.** `FoodRepository::list_mine` + `count_mine` (trait, Pg, fake).
2. **`/foods/mine` service + handler.** `FoodService::list_mine` + handler + `tests/http_foods.rs`. → 1.
3. **`/log` paginated repo + service.** `list_paginated` + `count_in_range`; rewire `LogService::list`; keep `list_in_range`.
4. **`/log` handler + tests.** Migrate `routes/log.rs::list`; update `tests/http_log.rs`. → 3.
5. **`/weights` paginated repo + service.** Replace `list_for_user` with `list_paginated` + `count_for_user`.
6. **`/weights` handler + tests.** Add `from > to` 400; new `tests/http_weights.rs`. → 5.
7. **Quick-add sentinel infra.** Migration `0005_quick_add_sentinel.sql` + `find_or_create_quick_add` + sentinel filters in `search`/`list_mine`/`recent`/`frequent` SQL + `"name is reserved"` guard in `create_custom`.
8. **`POST /log/quick_add`.** `LogService::quick_add` + handler + tests. → 7.
9. **`/log/copy` repo.** `LogRepository::create_many` (trait, Pg via UNNEST, fake).
10. **`/log/copy` service + handler.** `LogService::copy_day` + handler + tests. → 9.
11. **JWKS authenticator.** New `auth/jwks.rs`; extend `AuthConfig::Jwks`; wire `build_authenticator`; add `jsonwebtoken` + `reqwest` deps; wiremock-based integration test.
12. **`DELETE /me`.** `UserRepository::delete_user` + `UserService::delete_self` + handler.
13. **Export migration + repo.** `0006_export_jobs.sql` + `ExportJobRepository` (trait, Pg, fake) + `domain::export`.
14. **Export storage + signed-URL route.** `ExportStorage` trait + local-FS impl + public `GET /me/export/file/:token` route + HMAC token helpers.
15. **Export service + endpoints + runner.** `ExportService` + `POST /me/export` + `GET /me/export/:job_id` + in-process tokio runner spawned in `build_state` + startup recovery. → 13 + 14.
16. **OpenAPI lockstep.** Single sweep over `server/specs/openapi.yaml` per Item 6. → all earlier.

Parallelism: after 1, the pairs (3+4), (5+6), 7+(8), 9+(10), 11, 12 run independently. 13+14 → 15. 16 is the final pass.

---

End of design. Hand to TPM.
