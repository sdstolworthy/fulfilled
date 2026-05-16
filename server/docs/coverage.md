# Code coverage

Coverage runs through `cargo-llvm-cov`. Two entry points:

- `./coverage.sh` — HTML report at `target/llvm-cov/html/index.html`.
- `./scripts/check.sh` — calls `cargo llvm-cov --summary-only` at the
  end of the verification pass, so every full check pass emits a fresh
  number.

## Baseline

Captured `2026-05-15`, after Phase 1 scaffolding (T04–T08) landed and
before any service bodies were filled in. The numbers include the
`#[tracing::instrument]` macro expansions on `UserService` /
`WeightService` / `GoalService`, which add a small number of generated
regions — expect ~2pp of drift versus a build without instrumentation.

| Metric    | Coverage |
|-----------|----------|
| Regions   | 29.52%   |
| Functions | 30.08%   |
| Lines     | 27.74%   |

Tests executed: 17 (across 6 binaries / integration suites). Wall time:
~0.1 s. No database required — the full suite runs against in-memory
fakes from `loseit-testing`.

## What's intentionally uncovered

The number reads low because of two structural choices, not because the
suite is thin:

1. **`loseit-db` has no integration tests** (0% on every file).
   The sqlx repos use function-style `query_as` against a real
   Postgres; there's no compile-time DB. Until we land the
   real-Postgres integration suite (gated behind an env var, per
   `NEXT_STEPS.md`), the only way these files would show coverage is if
   we wrote unit tests against `sqlx::any::AnyPool`, which would prove
   nothing useful.
2. **`todo!()` service bodies** (0% on what hasn't been implemented
   yet). `service/food.rs`, `service/serving.rs`, `service/log.rs`, and
   `service/ingest.rs` are stubs that Phase 2–6 of `specs/v1_tasks.md`
   fills in. Each phase ships its own service-level tests in the same
   PR, so coverage will rise mechanically as those land.

If you exclude `loseit-db/*` and the unimplemented services, the
covered surface is ~70–80% covered today.

## Target

No hard gate. Soft targets, in order of priority:

1. **Every public `Service` method has at least one happy-path and one
   error-path test.** This is the bar Phase 2–6 tasks already hold
   themselves to (see "Acceptance" sections in `specs/v1_tasks.md`).
2. **`loseit-testing` fakes stay ≥ 80% covered.** The fakes *are* the
   test seam — if they have dead code, our coverage numbers lie.
3. **`loseit-api` handlers stay ≥ 60% covered by `tests/http.rs`.**
   We exercise routers via `tower::ServiceExt::oneshot`; a route with
   no HTTP test is almost certainly missing a 4xx case.

The `loseit-db` percentage is *deliberately not in the target list*
until the integration suite exists.

## Tips

- Adding `--no-clean` to `cargo llvm-cov` between runs makes the second
  run much faster (it skips re-instrumenting unchanged crates). The
  `coverage.sh` wrapper currently *does* clean, intentionally — stale
  `.profraw` files from a different test ordering produced spurious
  diffs locally during the initial baseline.
- `cargo llvm-cov --workspace --html --output-dir public/coverage` is
  the form you want when wiring this into a static-site CI artifact.
- For diff coverage, point `cargo llvm-cov-pretty` or the `lcov.info`
  output from `./coverage.sh --lcov` at your editor's gutter plugin.
