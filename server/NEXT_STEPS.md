# Next steps — v1 priorities

Reconciled from the PM brief (2026-05-15). The v1 cut focuses on the
smallest API surface that supports a mobile/web client doing food + weight
tracking. Anything not in this list is explicitly out for v1.

Already shipped (initial pass): `/health`, `/me`, `/weights/*`, `/goals/*`,
auth scaffolding (dev bypass), in-memory testing harness.

## Resolved product decisions

These were open in the spec; PM brief settled them.

- **Log entry shape: `serving_id` + `quantity` only.** Every food gets a
  synthetic `100 g` serving at ingest, so raw-grams logging is just
  `serving_id=<100g> quantity=2.0`. No dual API shape.

## Priority 1 — must-have v1 (in build order)

These have hard dependencies on each other and should land roughly in this
order. Each item is a small enough chunk for one PR / one dev session.

1. **OFF ingest pipeline (`loseit-ingest`).** Without foods, every other
   item is blocked. Sample data is already at `data/off-sample.jsonl`
   (5000 real records). Build the binary to:
   - Open a `food_import_batches` row.
   - Stream-parse JSONL (dev) **and** parquet (prod) — same row shape via
     an internal trait.
   - Filter records: must have `code`, `product_name`, `energy_kcal_100g`.
   - Compute `quality_score` from completeness signals.
   - Upsert by barcode with `ON CONFLICT`.
   - Always synthesize a `100 g` serving; derive an OFF-named serving from
     `serving_size`/`serving_quantity` when present, mark it default.
   - Stamp `last_import_batch_id`, close the batch.
   - Resumable + idempotent.

2. **Food detail + barcode lookup.**
   `GET /foods/{id}` and `GET /foods/barcode/{barcode}`. Returns the food
   with all its servings. Public-via-auth like everything else.

3. **Food search.** `GET /foods/search?q&limit&offset`.
   Combines `pg_trgm` similarity + FTS rank + `quality_score`. Returns the
   lean shape from the spec (id, name, brand, barcode, default_serving,
   calories_per_serving).

4. **Custom foods CRUD.** `POST/PATCH/DELETE /foods` (own-only enforcement
   in the service layer, not the handler).

5. **Servings CRUD.** `POST /foods/{id}/servings`, `PATCH /servings/{id}`,
   `DELETE /servings/{id}` (cannot delete the default; flipping default is
   a single transaction).

6. **Food log CRUD + day summary.** `POST/PATCH/DELETE /log`,
   `GET /log?from&to`, `GET /days/{date}/summary`. The nutrition snapshot
   is computed in `LogService`, not the handler. Day summary totals the
   day's entries and joins to the active goal on that date.

7. **Recent / frequent foods.** `GET /foods/recent?limit`,
   `GET /foods/frequent?limit`. Queries over `food_log_entries` for the
   caller. No schema change. **PM-flagged as the single thing that makes
   daily logging tolerable** — don't skip it.

## Priority 2 — should-have (next sprint, not v1-blocking)

- **Copy day or meal.** `POST /log/copy {from_date, to_date, meal?}`.
  Pure server-side convenience over existing rows.
- **Quick-add calories.** Log raw calories with no food. Recommended
  implementation: a per-user sentinel "Quick Add" food rather than making
  `food_id` nullable (keeps the snapshot invariants clean).

## Priority 3 — nice-to-have

- Weight-trend summary endpoint (7/30-day moving average).
- CSV export of food log + weights.
- Server-computed `daily_calorie_target` suggestion from profile (Mifflin-
  St Jeor + activity multiplier).

## Open product questions to resolve before / during architect work

1. **Per-user nutrition overrides on OFF foods.** If a user finds an OFF
   food has wrong serving sizes or stale nutrition, do they (a) clone it
   as a custom, (b) get a per-user override row, or (c) edit globally?
   *Recommend (a) for v1.* Cheapest; no schema change.

2. **Meal slots.** Are `breakfast/lunch/dinner/snack` enough, or do we
   need user-defined meals?
   *Recommend hardcoded for v1.* The four cover ~95% of usage; adding
   user-defined meals is a schema change with low leverage.

3. **Migration from Lose It! exports.** Do we want to accept a Lose It!
   CSV export at signup?
   *Recommend deferring entirely.* Not a v1 blocker.

## Explicit non-goals for v1

Exercise log, water intake, sleep/BP/glucose, body measurements beyond
weight, AI photo/voice logging, recipes (real ones with ingredients),
meal plans, insights/analytics dashboards, social/friends/challenges,
third-party device sync (Fitbit/Garmin/HealthKit/Google Fit), premium
tiers.

## Infrastructure / quality items running in parallel

- **docker-compose for Postgres.** *Landed.* `docker compose up -d`
  brings up Postgres 16 with the right defaults; `.env.example` lists
  the runtime env vars.
- **JWKS authenticator.** Implement as a sibling to `DevAuthenticator`;
  composition root already dispatches on it via `AuthConfig::Jwks`.
  Not v1-blocking — dev bypass is the v1 auth path.
- **Real-Postgres integration tests** for `loseit-db`. Gate behind an
  env var so they don't run by default. Each test runs in a transaction
  that rolls back.
- **Tracing spans on services.** *Landed for `UserService` /
  `WeightService` / `GoalService`.* Phase 2–6 services should add
  `#[tracing::instrument(skip(self))]` as their bodies are filled in.
- **Coverage tooling.** *Landed.* `./coverage.sh` wraps `cargo
  llvm-cov`; `./scripts/check.sh` runs fmt + clippy + tests + coverage.
  Baseline 2026-05-15: 29.52% regions / 27.74% lines — see
  `docs/coverage.md` for caveats (the number is structurally floored
  by `loseit-db` having no integration tests yet).
- **README.** *Landed.* `/README.md` covers crate layout, dev server,
  env vars, tests, coverage.
- **Toolchain pin + editorconfig.** *Landed.* `rust-toolchain.toml`
  pins stable 1.95 and `llvm-tools-preview`; `.editorconfig` standardises
  whitespace.
- **OpenAPI / typed client.** Once the v1 surface is stable.
