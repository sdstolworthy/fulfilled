# loseit-server

Rust backend for a food + weight tracking app. The shape is intentionally
small: a single axum binary (`loseit-api`) and a one-shot ingest binary
(`loseit-ingest`), wired together by a clean-architecture core that knows
nothing about HTTP or SQL.

This README covers everything you need to go from a fresh checkout to a
running dev server with passing tests and a coverage report. For product
scope see `NEXT_STEPS.md`; for the current task list see
`specs/v1_tasks.md`.

---

## Project layout

```
crates/
  loseit-core      Pure domain. Types, services, repository traits.
                   No I/O, no axum, no sqlx. The only crate with
                   business logic worth unit-testing directly.
  loseit-db        sqlx + Postgres adapters. One file per repository
                   trait from loseit-core. Function-style queries
                   (`sqlx::query_as::<_, Row>("…")`); no compile-time
                   `query!` macros so the workspace builds without a
                   live database.
  loseit-api       axum HTTP server. Owns routing, auth middleware,
                   wire DTOs, and the composition root that wires
                   sqlx repos into core services. Talks to the rest
                   of the codebase only through service objects.
  loseit-ingest    One-shot binary that pulls an Open Food Facts
                   dump (JSONL today, parquet in the future) and
                   upserts foods. Uses the same repository traits
                   as the API.
  loseit-testing   In-memory fakes for every repository trait, plus
                   a small auth test seam. The HTTP test suite wires
                   these into the real axum router so handlers are
                   exercised end-to-end without a database.

migrations/        sqlx migrations, applied at startup when
                   `LOSEIT_RUN_MIGRATIONS=true`. `0001_initial.sql`
                   is frozen; everything since is incremental.

specs/             Architect briefs and the current task plan
                   (`v1_tasks.md`). The PM briefing and resolved
                   product decisions live in `NEXT_STEPS.md`.

scripts/check.sh   Verification harness. Runs fmt, clippy, tests,
                   and a coverage summary. CI calls this.
coverage.sh        Wraps `cargo llvm-cov` for a friendlier HTML
                   report. `./coverage.sh --summary` for text only.

data/              Local-only sample data (gitignored). The OFF
                   sample lives at `data/off-sample.jsonl`.
```

Boundary rules, enforced by code review:
- `loseit-core` depends on nothing in this workspace.
- `loseit-db` depends only on `loseit-core`.
- `loseit-testing` depends only on `loseit-core` (it implements core's
  repository traits).
- `loseit-api` and `loseit-ingest` are the only crates that wire
  concrete adapters into services.

If you find yourself reaching from `loseit-core` into `loseit-db` or
`loseit-api`, stop — that's the violation we built this layout to
prevent.

---

## Prerequisites

- **Rust** stable 1.95 or newer. We track a `rust-toolchain.toml` so
  `rustup` will pick the right version automatically.
- **Docker** + **Docker Compose** for the local Postgres instance.
- **cargo-llvm-cov** for coverage reports (optional, but the verification
  harness will skip the coverage step without it).
  ```
  cargo install cargo-llvm-cov
  ```

Optional but recommended:
- `psql` for inspecting the local database.
- A modern shell — the helper scripts are POSIX `sh`-compatible but
  written with bash in mind.

---

## Running the dev server

```bash
# 1. Start Postgres.
docker compose up -d
docker compose ps           # confirm `loseit-postgres` is `healthy`.

# 2. Copy the env template and (optionally) tweak.
cp .env.example .env

# 3. Run the API. Migrations apply on boot in dev.
cargo run -p loseit-api
```

The server binds to `0.0.0.0:8080` by default (`LOSEIT_BIND`). Smoke test:

```bash
curl -s http://localhost:8080/api/v1/health
# → {"status":"ok"}

curl -s -H "Authorization: Bearer dev-token" \
     http://localhost:8080/api/v1/me
# → {"id":"…","email":"dev@example.com",…}
```

To run the OFF ingest against the dev DB (once `loseit-ingest` is
implemented — T18):

```bash
cargo run -p loseit-ingest -- \
    --source jsonl \
    --input data/off-sample.jsonl \
    --database-url "$DATABASE_URL"
```

---

## Environment variables

All taken from `.env.example`. The API binary reads them through
`std::env`; nothing else is involved.

| Variable                  | Default                                              | What it does                                                       |
|---------------------------|------------------------------------------------------|--------------------------------------------------------------------|
| `DATABASE_URL`            | (required)                                           | Postgres connection string.                                        |
| `LOSEIT_BIND`             | `0.0.0.0:8080`                                       | Listener address.                                                  |
| `LOSEIT_RUN_MIGRATIONS`   | `true`                                               | Apply sqlx migrations at startup.                                  |
| `RUST_ENV`                | `development`                                        | Used to refuse insecure config combinations in prod.               |
| `RUST_LOG`                | `info,tower_http=info,sqlx=warn`                     | `tracing-subscriber` env filter.                                   |
| `DEV_AUTH_BYPASS`         | `true` (dev), illegal in prod                        | Skip JWT validation; map a static bearer token to one identity.    |
| `DEV_AUTH_TOKEN`          | `dev-token`                                          | The static token. Pass as `Authorization: Bearer …`.               |
| `DEV_AUTH_ISSUER`         | `dev`                                                | Synthetic `iss` claim for the dev identity.                        |
| `DEV_AUTH_USER_ID`        | `dev-user`                                           | External-id half of `(issuer, external_id)` user key.              |
| `DEV_AUTH_EMAIL`          | `dev@example.com`                                    | Email of the dev identity.                                         |
| `DEV_AUTH_DISPLAY_NAME`   | `Dev User`                                           | Display name of the dev identity.                                  |
| `OIDC_ISSUER`             | (required when bypass is off)                        | JWKS issuer URL. Not wired up for v1 — JWKS is post-v1.            |
| `OIDC_JWKS_URL`           | (required when bypass is off)                        | JWKS metadata URL.                                                 |

The binary refuses to start if `RUST_ENV=production` and
`DEV_AUTH_BYPASS=true` — that combination has bitten us before.

---

## Running tests

```bash
cargo test --workspace
```

The whole suite runs against in-memory fakes from `loseit-testing`. No
database, no network. As of this snapshot the suite finishes in well
under five seconds and exercises:

- Domain types (parse/round-trip, validation).
- Core services using `InMemoryXxxRepository` fakes.
- The full axum router via `tower::ServiceExt::oneshot` in
  `crates/loseit-api/tests/http.rs`.

A real-Postgres integration suite for the sqlx repos is on the deferred
list (see `NEXT_STEPS.md` → "Real-Postgres integration tests"). When it
lands it'll be gated behind an env var so the default `cargo test` stays
fast.

To run a single test:

```bash
cargo test -p loseit-core test_meal_from_str_round_trip
cargo test -p loseit-api  test_get_me_returns_dev_identity
```

---

## Verification harness

`scripts/check.sh` is the one entry point a future CI job (or a
sufficiently paranoid developer) needs. It chains:

1. `cargo fmt --all -- --check`
2. `cargo clippy --workspace --all-targets -- -D warnings`
3. `cargo test --workspace`
4. `cargo llvm-cov --workspace --summary-only` (skipped if the tool
   isn't installed)

```bash
./scripts/check.sh            # full pass
./scripts/check.sh --no-cov   # skip the coverage step
```

Treat a clean run of this script as "ready to push." It is intentionally
*not* CI itself — we don't ship CI config until the v1 surface stops
moving — but it's the contract any future CI runner will honour.

---

## Coverage

`./coverage.sh` wraps `cargo llvm-cov` so anyone can produce an HTML
report without remembering the flags.

```bash
./coverage.sh             # HTML report → target/llvm-cov/html/index.html
./coverage.sh --summary   # text summary only (what check.sh uses)
./coverage.sh --lcov      # also emit lcov.info for editor integration
./coverage.sh --open      # generate + open the HTML report
```

**Baseline coverage** (captured 2026-05-15, post-Phase-1 scaffold):

| Metric    | Coverage |
|-----------|----------|
| Regions   | 29.52%   |
| Functions | 30.08%   |
| Lines     | 27.74%   |

The bulk of uncovered code is intentional:
- `loseit-db` repos: 0% locally because there's no Postgres integration
  suite yet (see "Running tests" above).
- Several `loseit-core` services have `todo!()` bodies awaiting Phase
  2–6 of `specs/v1_tasks.md`.

Expect the line number to roughly double once Phases 2–4 land — those
phases bring service bodies *and* their service-level tests.

See `docs/coverage.md` for tracker notes and a longer-form discussion of
what we'd ideally cover vs. what's structurally untestable without a
real database.

---

## Day-to-day workflow

```bash
# bring the world up
docker compose up -d

# work loop
cargo check -p loseit-core            # quick type-check
cargo test  -p loseit-core            # focused tests
./scripts/check.sh --quick            # pre-commit gate (no coverage)

# before pushing
./scripts/check.sh                    # full pass with coverage
```

`tracing` is wired through `tracing-subscriber`'s env filter — set
`RUST_LOG=loseit_core=debug,loseit_api=debug` to see service-level spans
and request traces.

---

## Where to look next

- `NEXT_STEPS.md` — what's in/out of v1, and the priority order.
- `specs/v1_tasks.md` — the live task list, broken down by phase. Each
  task is sized for one ~30–60-minute developer session.
- `specs/initial_spec.md` — the original handoff if you want full
  product context.
- `specs/sql_handoff.sql` — the canonical schema.
- `docs/coverage.md` — coverage tracker + what we intend to push toward.

## Troubleshooting

- **`error: failed to connect to database`** — check `docker compose ps`.
  The Postgres container needs to be `healthy` (not just running) before
  the API will start cleanly.
- **`cargo fmt --check` fails on files you haven't touched** — Phase 1
  agents are landing scaffolding in parallel right now; some files have
  pending fmt-only diffs that will be cleaned up during their PR review.
  Run `cargo fmt` to fix in place.
- **`cargo llvm-cov` complains about `llvm-tools-preview`** — `rustup
  component add llvm-tools-preview` once and you're set.
