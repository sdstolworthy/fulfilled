# BE-009 — Live-deploy fixes (Ask 7) Task Breakdown

8 tasks on branch `be-live-deploy-fixes`. Each maps to one commit; each
ends green on `cargo check --workspace` minimum, with targeted tests
added in their dedicated tasks.

Design reference: [`be_live_deploy_fixes_design.md`](be_live_deploy_fixes_design.md)
Ledger: [`backend_tickets_ledger.md`](backend_tickets_ledger.md) — BE-009

---

## T01 — Fix 7a SQL bug

**Subject:** Delete the inline `--` comment from `log_repo.rs:463`; add substring regression test.

**What changes:**
- `server/crates/loseit-db/src/log_repo.rs` — remove the trailing `-- nullable: Vec<Option<Uuid>>` comment on the `$3::uuid[]` line of the `create_many` `format!`-built SQL string. One-line deletion. Add a `#[cfg(test)] mod tests` unit test (`create_many_sql_has_no_inline_comment`) that rebuilds the SQL string the same way `create_many` does and asserts `!sql.contains("-- ")`. Pure string work; no DB required.

**Key implementation notes:**
- The bug: Rust's `\` line-continuation glues the `-- comment` and the next line into one physical string. Postgres reads `--` as a line comment and consumes the rest of the query, producing `syntax error at end of input`. `map_sqlx` bins the DB error under `CoreError::Internal`; the API renders 500.
- Fix is a single character deletion. The rest of the `create_many` SQL has no other `--` comments inside continuations.
- PR description must include a before/after curl + server-log paste from a local stack (manual reproduction required — see §2 of design).

**Acceptance:**
- `cargo check --workspace` green.
- `cargo test -p loseit-db -- create_many_sql_has_no_inline_comment` passes.
- Manual curl repro (§2 of design) returns 200 after the fix.

**Files touched:** 1

**Depends on:** none — **first to land** (P1 server bug)

**Design ref:** §2 of be_live_deploy_fixes_design.md

---

## T02 — Audit `format!`-built SQL strings for the same bug class

**Subject:** Grep every `format!` in `loseit-db/src/` for `--` inside line-continuations; document findings.

**What changes:**
- `server/crates/loseit-db/src/log_repo.rs` (possibly) — if further hits are found, delete the offending comments. If none are found (architect's expectation: zero further hits), this task is code-zero: add a one-line policy comment in `server/crates/loseit-db/src/lib.rs` (`// Policy: do not use SQL `--` comments inside format!() line-continuations.`) and paste the audit grep + output in the PR description.

**Key implementation notes:**
- Audit command: `grep -nE '--.*\\\s*$' server/crates/loseit-db/src/*.rs`
- Architect verified by hand that T01's hit is the only occurrence as of the design date. Still run the grep fresh — the branch may have diverged.

**Acceptance:**
- Audit grep output recorded in the PR description.
- `cargo check --workspace` still green.
- If further hits found: each is fixed (same approach as T01) and tested.

**Files touched:** 0–2 (grep determines; likely 1 for the policy comment)

**Depends on:** T01

**Design ref:** §2 ("Belt-and-braces") of be_live_deploy_fixes_design.md

---

## T03 — Add migration `0008_food_kind.sql`

**Subject:** Add `foods.kind TEXT NOT NULL DEFAULT 'normal'` column, CHECK constraint, and sentinel backfill.

**What changes:**
- Create `server/migrations/0008_food_kind.sql` — verbatim per §4.1 of the design. Contents: `ALTER TABLE foods ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'normal'`; drop-then-re-add `foods_kind_check` CHECK (`kind IN ('normal', 'quick_add')`); `UPDATE foods SET kind = 'quick_add' WHERE source = 'user' AND name = '__quick_add__' AND kind <> 'quick_add'`. All DDL is idempotent.

**Key implementation notes:**
- The backfill matches sentinel rows via the same predicate as the `foods_quick_add_singleton` partial unique index in `0005_quick_add_sentinel.sql` — one row per user, zero rows otherwise.
- Do not touch the existing index; the `0005` on-conflict path must keep working byte-for-byte.
- Apply locally against `loseit-postgres` and verify the sentinel row's `kind` flips to `'quick_add'`.
- No Rust changes.

**Acceptance:**
- File exists at `server/migrations/0008_food_kind.sql`.
- `cargo check --workspace` still green (no Rust touched).
- Re-running the file against an already-migrated DB is a no-op.
- After apply: `SELECT kind FROM foods WHERE name = '__quick_add__'` returns `quick_add`.

**Files touched:** 1

**Depends on:** none (parallelizable with T01/T02 — different concern, no shared file). Must land before T04–T07 begin.

**Design ref:** §4.1 of be_live_deploy_fixes_design.md

---

## T04 — Add `FoodKind` domain enum and extend `Food` struct

**Subject:** Add `FoodKind` to `domain/food.rs`; add `kind: FoodKind` to `Food`; re-export; fix test helpers.

**What changes:**
- `server/crates/loseit-core/src/domain/food.rs` — add `FoodKind` enum (`Normal`, `QuickAdd`) with `as_str()` and `parse()` methods per §4.2 of the design, inline alongside `FoodSource`. Add `pub kind: FoodKind` field to the `Food` struct.
- `server/crates/loseit-core/src/domain/mod.rs` — re-export `FoodKind`.
- `server/crates/loseit-core/src/service/log.rs` — update the `food_with_nutrition` test-helper function (line 617) that constructs `Food` literals to supply `kind: FoodKind::Normal`. This is the only test-helper that builds a `Food` directly; the struct addition will fail to compile otherwise.

**Key implementation notes:**
- `FoodKind::parse` returns `Option<Self>` — same defensive pattern as `FoodSource::parse`. Unknown DB values fall back to `Normal`.
- `FoodKind` derives `Debug, Clone, Copy, PartialEq, Eq`.

**Acceptance:**
- `cargo check -p loseit-core` green.
- `cargo test -p loseit-core` green (existing tests still pass after helper update).

**Files touched:** 3

**Depends on:** T03 (migration must exist before wiring the column)

**Design ref:** §4.2 of be_live_deploy_fixes_design.md

---

## T05 — Wire `kind` through Pg and in-memory repos

**Subject:** Update `PgFoodRepository` and `InMemoryFoodRepository` to read and write the `kind` column.

**What changes:**
- `server/crates/loseit-db/src/food_repo.rs` — four edits: (1) append `, kind` to `SELECT_FOOD_COLS`; (2) add `kind: String` field to `FoodRow`; (3) in `From<FoodRow> for Food`, parse via `FoodKind::parse(&r.kind).unwrap_or(FoodKind::Normal)`; (4) in `find_or_create_quick_add`, add `kind` to the INSERT column list and pass `'quick_add'` as its value — do not lean on the column DEFAULT, which would write `'normal'`.
- `server/crates/loseit-testing/src/foods.rs` — update `InMemoryFoodRepository`: stamp `kind: FoodKind::Normal` on `create_custom` and `kind: FoodKind::QuickAdd` on `find_or_create_quick_add`.

**Key implementation notes:**
- `create_custom` does not need an explicit `kind` in the SQL — the column DEFAULT (`'normal'`) handles it. But the in-memory fake must stamp it explicitly to keep semantics aligned.
- The `find_or_create_quick_add` DO UPDATE branch returns the existing (already-backfilled) row; concurrent first-uses both surface `kind = 'quick_add'` correctly.

**Acceptance:**
- `cargo check --workspace` green.
- `cargo test -p loseit-testing -- foods` green (in-memory `find_or_create_quick_add` stamps `QuickAdd`; `create_custom` stays `Normal`).

**Files touched:** 2

**Depends on:** T04

**Design ref:** §4.3 of be_live_deploy_fixes_design.md

---

## T06 — Expose `kind` on the API wire

**Subject:** Add `kind` to `FoodDetailResponse`; update HTTP food tests for both `normal` and `quick_add` paths.

**What changes:**
- `server/crates/loseit-api/src/routes/foods.rs` — add `kind: &'static str` field to `FoodDetailResponse` (line 127); populate in `from_pair` (line 146) via a `food_kind_str` helper following the same pattern as the existing `food_source_str` at line 119.
- `server/crates/loseit-api/tests/http_foods.rs` — add two test cases: (1) `GET /foods/{id}` on a custom food asserts `kind == "normal"`; (2) after `POST /log/quick_add`, `GET /foods/{food_id_from_response}` asserts `kind == "quick_add"`.

**Key implementation notes:**
- `FoodSearchHitResponse` does **not** get `kind` — the search query strips the sentinel via `f.name <> '__quick_add__'` at every list path, so the field would always be `'normal'`. Omitting it is intentional (§4.4 of design).
- `POST /log/quick_add`'s `LogEntryResponse` is unchanged — only `food_id`. The FE reads `kind` by fetching `GET /foods/{id}`.

**Acceptance:**
- `cargo check --workspace` green.
- `cargo test -p loseit-api --test http_foods` passes (all pre-existing + 2 new cases).

**Files touched:** 2

**Depends on:** T05

**Design ref:** §4.4 of be_live_deploy_fixes_design.md

---

## T07 — OpenAPI: add `FoodKind` schema and update `FoodDetail` (7c)

**Subject:** Add `FoodKind` enum schema and wire `kind` into `FoodDetail.required` and `properties`.

**What changes:**
- `server/specs/openapi.yaml` — two edits per §4.5 of the design:
  1. Insert `FoodKind` schema block between `FoodSource` (line 873) and `ServingSource` (line 877).
  2. On `FoodDetail` (line 1098): add `kind` to the `required` list (line 1107) and add `kind: { $ref: "#/components/schemas/FoodKind" }` to `properties`.

**Acceptance:**
- `cargo check --workspace` still green (no Rust touched).
- OpenAPI spec lints clean (run any existing lint tooling in `server/scripts/` if present).
- `FoodDetail` schema declares `kind` as required with a `$ref` to `FoodKind`.

**Files touched:** 1

**Depends on:** T06 (the Rust wire must exist before the spec reflects it)

**Design ref:** §4.5 of be_live_deploy_fixes_design.md

---

## T08 — OpenAPI: 7b spec clarification (no-GET-servings note)

**Subject:** Add prose to `POST /foods/{food_id}/servings` and to `FoodDetail.servings` explaining there is no symmetric GET.

**What changes:**
- `server/specs/openapi.yaml` — two edits per §3 of the design:
  1. On the `POST /foods/{food_id}/servings` operation (line 533), insert a `description` field between the existing `summary` and `parameters` lines explaining that servings are read via `GET /foods/{id}` and no symmetric `GET /foods/{id}/servings` endpoint exists.
  2. On `FoodDetail.servings` (line 1134), add a `description` field stating the same read-path guidance.

**Key implementation notes:**
- No handler changes. No Rust changes. No migration.
- This closes 7b as a documentation task — the 405 the FE observed is by design; `POST` only is intentional.

**Acceptance:**
- `cargo check --workspace` still green.
- Both YAML edits are present; spec lints clean.

**Files touched:** 1

**Depends on:** none — independent of T01–T07. Can land alongside T01.

**Design ref:** §3 of be_live_deploy_fixes_design.md

---

## Notes for engineers

**Landing order.** T01 is P1 — ship it first. T08 is fully independent and can be committed in the same early batch as T01 (same PR, different commit). T03 is the gate for T04–T07; do not start the domain/repo/wire/spec chain until the migration commit is in. The full sequencing:

```
T01 → T02         (7a fix + audit; P1 first)
T08               (7b YAML-only; commit alongside T01)
T03 → T04 → T05 → T06 → T07   (7c chain; migration gates all)
```

**Sequencing matches the architect's §5.** No dependency changes are needed for this ticket, unlike BE-008's T06→T09 correction. T08 is correctly listed as independent in the design table.

**T02 is likely a no-op in code.** The architect's hand-audit found only one `--`-inside-continuation hit. Run the grep fresh on the current branch, record the output in the PR, and add the policy comment regardless. The task closes with zero code diff if the grep returns no new hits.

**No Postgres integration tests.** 7a shipped precisely because `http_log.rs::copy_day_*` runs against `InMemoryLogRepository`, which never touches the SQL string. The T01 substring-assertion unit test is the v1 regression guard. A `#[sqlx::test]` harness against containerised PG is a separate larger ticket (flagged in §6 of the design) — do not attempt it on this branch.

**`FoodSearchHitResponse` intentionally omits `kind`.** If a reviewer questions it: search strips the sentinel; the field would always be `'normal'`; dead wire is worse than absent wire. Revisit if a future `FoodKind` variant needs to surface in search results.

**FE coordination on 7c.** `kind` is additive on the wire — the FE can flip its `foodId == quickAddFoodId` constant-check to `food.kind == 'quick_add'` at its own pace after this PR merges. No FE deploy is required before this branch ships.
