# LoseIt Re-implementation — Handoff Document

This document captures the design decisions made so far for an open-source
re-implementation of the LoseIt nutrition tracking app. Hand it to a Claude
Code session (or to yourself) to bootstrap the project.

---

## Project Overview

A headless Rust service that mirrors LoseIt's core functionality: logging food
intake, tracking weight, setting goals, and looking up foods by name or barcode.
Food data is sourced from OpenFoodFacts (OFF). A mobile client will be built
later against this API.

The project name is a placeholder — "LoseIt" is trademarked, so pick a real
name before going public. Code below uses `loseit-*` as crate prefixes;
swap as desired.

---

## Stack

- **Language:** Rust
- **Web framework:** Axum 0.7 (with `tower`, `tower-http`)
- **Async runtime:** Tokio
- **Database:** PostgreSQL 14+ via `sqlx`
- **Auth:** OAuth/OIDC-ready. JWT validation against a JWKS endpoint
  (`jsonwebtoken` crate). Dev-mode bypass flag for local testing without an IdP.
- **HTTP client:** `reqwest` (for the ingest binary)
- **Parquet parsing:** `parquet` + `arrow` crates
- **Logging:** `tracing` + `tracing-subscriber`
- **Errors:** `thiserror` for library code, `anyhow` at binary edges
- **Search:** PostgreSQL `pg_trgm` + full-text search (`tsvector`/`ts_rank`).
  No external search service in v1.

---

## Workspace Layout

```
loseit/
├── Cargo.toml              (workspace)
├── crates/
│   ├── loseit-api/         axum HTTP layer, main binary
│   ├── loseit-core/        domain logic, services, traits
│   ├── loseit-db/          sqlx models, queries, migration runner
│   └── loseit-ingest/      OpenFoodFacts bulk import binary
├── migrations/             sqlx migrations
└── docker-compose.yml      postgres + dev tooling
```

- `loseit-core` takes repository traits, not concrete DB types — keeps it
  testable and keeps the API layer thin.
- `loseit-ingest` is a separate binary, run on a schedule (cron, systemd
  timer, k8s CronJob). Not part of the API process.

---

## Architectural Decisions

### Server is timezone-agnostic

The server never computes "today." Clients assert absolute dates (e.g.
`consumed_on: "2026-05-14"`) and the server stores those as `DATE`. Audit
fields (`created_at`, `updated_at`) are `TIMESTAMPTZ` in UTC.

Rationale: avoids DST math, timezone-crossing edge cases, and lets clients
on phone/web/CLI each decide for themselves what date it is.

### OpenFoodFacts: bulk import, no live queries

We download OFF's full Parquet dump, parse it, and load it into our own
`foods` table. No runtime calls to OFF's API. Ingest runs on a schedule
(weekly is plenty — OFF changes slowly).

Rationale: no rate limits, no network dependency, full control over search
ranking, offline-capable.

### Foods: one table, two sources

Both OFF foods and user-created customs live in the `foods` table,
distinguished by a `source` column (`'off'` or `'user'`) and an
`owner_user_id`. A CHECK constraint enforces the invariants:

- `source = 'off'` → must have barcode, must NOT have owner
- `source = 'user'` → must have owner, barcode optional

`id` is a UUID. Barcode is a *property* of a food (nullable, unique when
present), not its identity. Food log entries reference `food_id`, not
barcode, so user customs are first-class.

### Nutrition is snapshotted on every log entry

`food_log_entries` stores `calories_kcal`, `protein_g`, etc. as columns on
the row. When OFF reimports change a food's nutrition next month, the
user's June log doesn't silently mutate.

Cost: ~80 bytes per entry. Benefit: history is immutable.

### Goals are time-ranged, not "active"

A goal has `starts_on` and a nullable `ends_on`. The "current" goal is
whichever row's window contains today's date. No `is_active` boolean to
keep in sync. Gives free goal history.

### Search uses pg_trgm + full-text together

- **Full-text search** (`tsvector`, `ts_rank`) handles multi-word queries
  with word-level matching: "greek yogurt plain" ranks Fage above
  yogurt-covered raisins.
- **Trigram similarity** (`pg_trgm`, `similarity()`) handles typos:
  "yogrut" still finds yogurt.

Search query combines both scores plus a `quality_score` column (computed
at ingest time from OFF data completeness) so well-documented foods rank
above sparse entries.

---

## Database Schema

See `migrations/0001_initial.sql` (attached separately). High-level:

| Table | Purpose |
|---|---|
| `users` | OIDC-identified users; optional profile fields for TDEE math |
| `food_import_batches` | One row per ingest run; foods reference last batch |
| `foods` | OFF + user-custom foods; UUID id, optional barcode |
| `servings` | Named portions per food; exactly one is default |
| `weights` | Body weight readings on absolute dates |
| `goals` | Time-ranged calorie/macro/weight targets |
| `food_log_entries` | The core feature; snapshotted nutrition per entry |

Key extensions: `pgcrypto` (UUIDs), `pg_trgm` (fuzzy search).

---

## API Surface (v1 draft)

All endpoints under `/api/v1`. All authenticated except `/health`.

### Health
- `GET /health` — liveness/readiness

### Foods
- `GET /foods/search?q={q}&limit=&offset=` — fuzzy + FTS over name/brand
- `GET /foods/barcode/{barcode}` — direct barcode lookup
- `GET /foods/{id}` — full food detail including all servings
- `POST /foods` — create a user-custom food
- `PATCH /foods/{id}` — edit a user-custom food (own only)
- `DELETE /foods/{id}` — delete a user-custom food (own only, no logs referencing it)

### Servings
- `POST /foods/{id}/servings` — add a serving to a food (user customs only,
  or override on OFF foods — TBD)
- `PATCH /servings/{id}` — edit
- `DELETE /servings/{id}` — delete (not if default)

### Food log
- `POST /log` — create entry. Body includes `food_id`, `consumed_on` (DATE),
  `meal`, `serving_id` (or raw grams), `quantity`. Server computes
  `grams_total` and snapshots nutrition.
- `GET /log?from={date}&to={date}` — list entries in a date range
- `GET /days/{date}/summary` — totals for one day vs active goal
- `PATCH /log/{id}` — edit (recompute nutrition snapshot)
- `DELETE /log/{id}` — delete

### Weights
- `POST /weights` — record weight on a date
- `GET /weights?from={date}&to={date}` — list
- `DELETE /weights/{id}` — delete

### Goals
- `POST /goals` — create a new goal (closes the previous open-ended one)
- `GET /goals` — list, newest first
- `GET /goals/active?on={date}` — the goal active on that date
- `PATCH /goals/{id}` — edit
- `DELETE /goals/{id}` — delete

### Profile
- `GET /me` — current user
- `PATCH /me` — update profile (sex, birth_date, height, activity_level)

Search response shape (lean — full servings list only on detail fetch):

```json
{
  "results": [{
    "id": "uuid",
    "source": "off",
    "name": "Apple, raw, with skin",
    "brand": null,
    "barcode": "0000000000000",
    "default_serving": { "label": "medium apple", "grams": 182 },
    "calories_per_serving": 95
  }],
  "total": 142, "limit": 20, "offset": 0
}
```

Log create body:

```json
{
  "food_id": "uuid",
  "consumed_on": "2026-05-14",
  "meal": "lunch",
  "serving_id": "uuid",
  "quantity": 1.5
}
```

(Alternative serving form: `{ "grams": 200 }` instead of `serving_id` +
`quantity` — TBD whether to support both or normalize to one.)

---

## Ingest Binary Design

Separate binary in `loseit-ingest`. Responsibilities:

1. **Download** the latest Parquet dump from
   `https://static.openfoodfacts.org/data/openfoodfacts-products.parquet`.
   Stream to disk; don't buffer in memory. Capture ETag.
2. **Open a `food_import_batches` row** with `status = 'running'`.
3. **Stream-parse** the Parquet file row-group by row-group.
4. **Filter** records: must have `code`, `product_name`, and at least
   `energy_kcal_100g`. Skip junk.
5. **Compute `quality_score`** from completeness signals (has brand?
   has serving_size? has multiple nutrients? trustworthy contributor tags?).
6. **Upsert** into `foods` by barcode in batches (COPY or
   `INSERT ... ON CONFLICT (barcode) DO UPDATE`).
7. **Insert servings**: derive one from OFF's `serving_size`/
   `serving_quantity` (if present), plus a synthetic "100 g" so users
   always have a raw-weight option. Default = OFF-derived if present,
   else 100 g.
8. **Stamp** `last_import_batch_id` on each upserted food.
9. **Mark batch complete** with counts.

Must be idempotent (re-runs update, don't duplicate) and resumable (track
progress so a crashed run can pick up).

First import will take 30–60 min. Subsequent runs should be faster if we
ETag-skip unchanged data, or diff against the previous batch.

---

## Auth

OIDC-ready from v1. Validate incoming JWTs against the issuer's JWKS endpoint
(cached, refreshed periodically). User identity is `(issuer, external_id)`
where `external_id` is the `sub` claim — emails are not used as identity
because they change and aren't unique across issuers.

For local dev: a `DEV_AUTH_BYPASS` env flag accepts a static bearer token
that maps to a configured dev user. Off by default, refuses to start with
the flag set if `RUST_ENV=production`.

---

## Build Order

1. Workspace skeleton, config loader, tracing, `/health`
2. Run migration `0001_initial.sql`; verify schema with `sqlx prepare`
3. Auth middleware (JWKS validation + dev bypass)
4. Profile endpoints (`GET/PATCH /me`) — simplest authenticated path
5. Weights + goals endpoints — no external deps, exercises the date model
6. Ingest binary (download → parse → upsert), tested against a small OFF
   sample first
7. Food search + lookup endpoints
8. Food log endpoints
9. Daily summary endpoint

---

## Open Questions

These came up during design and were deferred:

- **Sodium units.** Stored per-100g in grams (OFF convention) but the log
  entry column is `sodium_mg`. Confirm the conversion happens at log time,
  or normalize both to mg.
- **Editing OFF foods.** Can a user override nutrition on a globally-shared
  OFF food, or only on their own customs? Current schema does not support
  per-user overrides on OFF foods.
- **Raw-grams logging.** Should `POST /log` accept `{ "grams": 200 }` in
  place of `serving_id` + `quantity`, or always require a serving (which
  may be the synthetic "100 g")? Latter is simpler.
- **Soft deletes.** Not in v1. Add per-table when needed.
- **Meal templates, recipes, exercise.** Deferred past v1.

---

## What's Already Written

- `migrations/0001_initial.sql` — full initial schema, ready to apply.

Everything else is greenfield.

