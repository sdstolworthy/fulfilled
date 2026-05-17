# BE-009 — Live-deploy fixes from Ask 7 — Architect Design

Three FE-reported bugs surfaced by the repo-wiring pass against
`https://api.coolify.stolworthy.co` (`backend_tasks.md` Ask 7).
Bundled as one branch / one ticket: all small, all P1 (modulo 7b),
all blocking the FE's first live-wire session.

Branch: `be-live-deploy-fixes` (forked from `main@925d0c1`, post
BE-008). TPM splits §5 into engineer-sized chunks.

---

## 1. Overview

- **7a — `POST /log/copy` → 500.** One-line SQL formatting bug in
  `loseit-db`: a Rust line-continuation `\` immediately after an SQL
  `--` comment swallows the rest of the query, yielding `syntax
  error at end of input`. Architect's preliminary "service-layer
  panic" lean was wrong — it's the repo layer. P1.
- **7b — `GET /foods/{id}/servings` → 405.** Not a bug. Route exists
  for `POST` only, by design; `GET /foods/{id}` already returns the
  `servings` array. Close as documentation. P3.
- **7c — quick-add entries return a real food UUID, not a sentinel.**
  Add `Food.kind: 'normal' | 'quick_add'` to the wire, default
  `'normal'`. Backfill the per-user sentinel rows. P1.

7a and 7c land schema/wire changes; 7b is YAML-only. All three on
the same branch with one migration (`0008_food_kind.sql`), one PR.

**Out of scope** (explicit):

- Idempotency keys on writes (`backend_tasks.md:375-378`). v1.1.
- Mounting `GET /foods/{food_id}/servings`. Duplicate-source-of-truth
  risk; FE works without it.
- Rate-limiting on `/auth/login`. Deferred in BE-008 §1.
- A Postgres-backed integration-test harness. The 7a bug shipped
  because `http_log.rs::copy_day_*` runs against
  `InMemoryLogRepository`, which doesn't share the SQL string.
  Separate ticket; flagged in §6.

---

## 2. Bug 7a — `POST /log/copy` 500: root cause + fix

### Root cause

`server/crates/loseit-db/src/log_repo.rs:463`. The `create_many` SQL
is built with `format!` over a multi-line string-literal continuation:

```rust
let sql = format!(
    "INSERT INTO food_log_entries (\
        ...\
     ) \
     SELECT \
        $1, x.food_id, ... \
     FROM UNNEST(\
        $2::uuid[], \
        $3::uuid[],  -- nullable: Vec<Option<Uuid>>\          // <-- bug
        $4::date[], \
        ...
```

Rust's `\` line-continuation strips the newline *and* leading
whitespace, gluing the two fragments into one string. Result:
`$3::uuid[],  -- nullable: Vec<Option<Uuid>>$4::date[], $5::text[] …`
on one physical line. Postgres reads `--` as line-comment and
consumes through end-of-input — no closing paren, no `WITH
ORDINALITY`, no `RETURNING`. `map_sqlx` (`loseit-db/src/error.rs:7-24`)
bins the database error under `CoreError::Internal`; the API layer
renders `500 internal_error`.

Reproduced locally against `loseit-postgres`:

```bash
curl -X POST -H "Authorization: Bearer dev-token" \
  -H "Content-Type: application/json" \
  -d '{"calories_kcal":"100","meal":"snack","consumed_on":"2026-05-17"}' \
  http://localhost:8081/api/v1/log/quick_add   # seed one row
curl -X POST -H "Authorization: Bearer dev-token" \
  -H "Content-Type: application/json" \
  -d '{"from_date":"2026-05-17","to_date":"2026-05-18"}' \
  http://localhost:8081/api/v1/log/copy
# → 500 {"code":"internal_error","message":"something went wrong"}
# server log: error returned from database: syntax error at end of input
```

Empty-source-day (`tests/http_log.rs:1789`) doesn't trigger the bug:
`create_many` short-circuits on `entries.is_empty()` at
`log_repo.rs:402-404`. Every other `copy_day_*` test runs against
`InMemoryLogRepository::create_many`, which loops over `self.create`
(`loseit-testing/src/logs.rs:281-292`) — never touches the SQL.

### Fix

`loseit-db/src/log_repo.rs:463` — delete the trailing inline comment.
Replacement line:

```rust
                $3::uuid[], \
```

One-line diff, one file. The rest of the SQL string is safe — no
other `--` comments inside line-continuations.

**Belt-and-braces (separate commit on the same PR):** audit every
`format!`-built SQL in `loseit-db/`:

```bash
grep -nE '--.*\\\s*$' crates/loseit-db/src/*.rs
```

Verified by hand: this is the only hit today.

### Test to add

Real-PG integration testing is the right answer, but we have no
`#[sqlx::test]` harness today (separate ticket — §6 risk #1). For
*this* ticket:

1. **Manual reproduction in the PR description.** Before/after curl
   + server-log paste. Required.
2. **Sanity unit test in `log_repo.rs`** that rebuilds the SQL
   string the same way `create_many` does and asserts
   `!sql.contains("-- ")`. Pure string work — no DB. Lives under
   `#[cfg(test)] mod tests` in `log_repo.rs`. Cheap regression
   guard; would have caught the bug.

---

## 3. Bug 7b — `GET /foods/{food_id}/servings` 405: spec clarification

`/foods/{food_id}/servings` is mounted at
`crates/loseit-api/src/routes/foods.rs:58` with `POST` only.
`GET /foods/{id}` returns `FoodDetail` including `servings: [Serving]`
(`openapi.yaml:1098-1136`, `routes/foods.rs:321-322`). A symmetric
GET would duplicate the read path.

**Decision: no new route.** Document the read path inline. Two
edits to `server/specs/openapi.yaml`:

### Edit A — on the `POST /foods/{food_id}/servings` operation

Add a `description` field directly under `summary` (currently absent).
Insert at line 533 (between the existing `summary` line and
`parameters`):

```yaml
      description: |
        Servings are read via `GET /foods/{id}`, which returns the
        full `FoodDetail` (including `servings`). This endpoint exists
        only for **creating** a new serving on a food; there is no
        symmetric `GET /foods/{id}/servings` listing — it would
        duplicate the `FoodDetail.servings` read path.
```

### Edit B — on the `FoodDetail` schema

Augment the existing `servings` property at line 1134 with a
description so a tooling generator that reads only the schema picks
this up too:

```yaml
        servings:
          type: array
          description: |
            Authoritative list of this food's servings. Clients
            reading servings should fetch the parent food — there is
            no separate `GET /foods/{id}/servings` endpoint.
          items: { $ref: "#/components/schemas/Serving" }
```

Both edits are pure YAML — no handler changes, no Rust changes, no
migration. Verify the spec lints with the existing tooling (if any)
in `server/scripts/`.

---

## 4. Bug 7c — `Food.kind` field

### Decision

Add `Food.kind: 'normal' | 'quick_add'` to the wire, default
`'normal'`, required on every `Food` projection. Backed by
`foods.kind TEXT NOT NULL DEFAULT 'normal' CHECK …`, with a backfill
flipping the per-user sentinel rows to `'quick_add'`.

**Why not `Food.source = 'quick_add'`?** `source` is already
provenance (`off | user | usda`) tied to the
`foods_source_identity_check` invariants in
`migrations/0003_usda_source.sql:41-46`. Overloading `source` either
widens that CHECK or re-implements a magic name predicate at every
read site. Clean split: `source` = origin; `kind` = role.

**Why enum, not `is_sentinel: bool`?** Matches every other
domain-discriminator on the wire (`FoodSource`, `Meal`). Future
`'recipe' | 'meal_template'` slot in without a bool→enum migration.

**Why required, not optional?** DB column is `NOT NULL` after
backfill; optional wire creates a phantom "absent" state the FE has
to map to `'normal'` anyway.

### 4.1 Schema migration — `0008_food_kind.sql`

```sql
-- Add `kind` discriminator to foods. Default `'normal'`; the per-user
-- quick-add sentinel rows backfill to `'quick_add'`. The FE uses this
-- to route Edit on quick-add log entries to the quick-add sheet
-- (instead of the canonical food-edit sheet) without UUID coordination.
--
-- Future kinds (e.g. 'recipe', 'meal_template') extend the CHECK domain
-- without a column rename.

ALTER TABLE foods
    ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'normal';

ALTER TABLE foods DROP CONSTRAINT IF EXISTS foods_kind_check;
ALTER TABLE foods ADD CONSTRAINT foods_kind_check
    CHECK (kind IN ('normal', 'quick_add'));

-- Backfill the existing per-user sentinel rows. The
-- `foods_quick_add_singleton` partial unique index
-- (migration 0005) is keyed on exactly the same predicate, so this
-- update touches one row per user and zero rows otherwise.
UPDATE foods
   SET kind = 'quick_add'
 WHERE source = 'user'
   AND name = '__quick_add__'
   AND kind <> 'quick_add';

-- Defensive: the sentinel singleton index is already partial-unique on
-- (owner_user_id) WHERE source='user' AND name='__quick_add__'. With
-- the new column, an alternative phrasing of that invariant becomes
-- possible (WHERE kind='quick_add'). We do NOT touch the existing index
-- — it stays the source of truth on per-user uniqueness so 0005's
-- on-conflict path keeps working byte-for-byte.
```

Idempotent (`IF NOT EXISTS`, `DROP CONSTRAINT IF EXISTS`, conditional
`UPDATE`). Matches the precedent set by `0006_user_units.sql:15-21`.

### 4.2 Domain — `FoodKind` enum

Inline in `crates/loseit-core/src/domain/food.rs` alongside
`FoodSource` (line 5-29). Shape:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoodKind {
    Normal,
    QuickAdd,
}

impl FoodKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Normal   => "normal",
            Self::QuickAdd => "quick_add",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "normal"    => Some(Self::Normal),
            "quick_add" => Some(Self::QuickAdd),
            _ => None,
        }
    }
}
```

Add `pub kind: FoodKind` to the `Food` struct in
`crates/loseit-core/src/domain/food.rs:80-105`. Re-export
from `domain/mod.rs`.

### 4.3 Repo — `crates/loseit-db/src/food_repo.rs`

Three updates, all mechanical:

1. **`SELECT_FOOD_COLS`** (line 97) — append `, kind`.
2. **`FoodRow`** (line 29) — add `kind: String` field. In the
   `From<FoodRow> for Food` impl (line 55), parse via
   `FoodKind::parse(&r.kind).unwrap_or(FoodKind::Normal)` — same
   defensive pattern as `FoodSource::parse` already uses.
3. **`find_or_create_quick_add`** (line 566) — set `kind = 'quick_add'`
   on insert. Don't lean on the column DEFAULT (which would set
   `'normal'`). New INSERT:

   ```sql
   INSERT INTO foods (
       source, owner_user_id, name, energy_kcal_100g,
       quality_score, categories_tags, kind
   ) VALUES ('user', $1, '__quick_add__', 1, 0, ARRAY[]::text[], 'quick_add')
   ON CONFLICT (owner_user_id) WHERE source = 'user' AND name = '__quick_add__'
     DO UPDATE SET updated_at = now()
   RETURNING <SELECT_FOOD_COLS>
   ```

   The DO UPDATE branch returns the existing (already-backfilled)
   row, so concurrent first-uses both surface `kind = 'quick_add'`.

4. **`create_custom`** — no change. Column DEFAULT covers it.

### 4.4 API wire — `routes/foods.rs`

Add `kind: &'static str` to `FoodDetailResponse` (line 127);
populate in `from_pair` (line 146) via a `food_kind_str` helper —
same pattern as `food_source_str` at line 119.

`FoodSearchHitResponse` (line 183) does **not** get `kind` — search
strips the sentinel via `f.name <> '__quick_add__'` at every list
path, so the field would always be `'normal'`. Dead code.

`POST /log/quick_add`'s `LogEntryResponse` is unchanged — only
`food_id`. The FE already round-trips through `GET /foods/{id}` to
render the meal section
(`client/lib/features/today/today_internals.dart`); `kind` lands
there.

### 4.5 OpenAPI — `specs/openapi.yaml`

Two edits:

1. **New `FoodKind` schema** alongside `FoodSource` at line 875,
   inserted between `FoodSource` (line 873) and `ServingSource`
   (line 877):

   ```yaml
       FoodKind:
         type: string
         enum: [normal, quick_add]
         description: |
           Role this food plays for its owner. `normal` is every
           food (OFF, USDA, or user-custom). `quick_add` flags the
           per-user sentinel that backs `POST /log/quick_add` —
           clients use this to route the Edit action on a quick-add
           log entry to the quick-add sheet, not the canonical
           food-edit sheet.
   ```

2. **`FoodDetail`** (line 1098) — add `kind` to `required` (line
   1107) and to `properties`:

   ```yaml
       FoodDetail:
         type: object
         required:
           - id
           - source
           - kind            # <-- added
           - name
           ...
         properties:
           ...
           source: { $ref: "#/components/schemas/FoodSource" }
           kind:   { $ref: "#/components/schemas/FoodKind" }   # <-- added
           ...
   ```

### 4.6 Test plan

- **Unit:** `FoodKind::parse` round-trip + unknown→`None`.
- **Repo (in-memory):** `find_or_create_quick_add` stamps
  `QuickAdd`; `create_custom` stays `Normal`.
- **HTTP (`tests/http_foods.rs`):**
  1. `GET /foods/{id}` on a custom food → `kind: "normal"`.
  2. After `POST /log/quick_add`, `GET /foods/{food_id_from_response}`
     → `kind: "quick_add"`.
- **OpenAPI lint:** spec validates.

---

## 5. Sequenced task list

Engineer-sized. Each ships its own commit; ticket lands one PR.

| # | Task | Files | Est |
|---|---|---|---|
| T1 | **Fix 7a SQL bug.** Drop the inline `--` comment on `log_repo.rs:463`. Add the substring assertion regression test under `log_repo.rs::tests`. Verify by running the manual curl repro against a local stack and pasting the before/after in the PR. | `crates/loseit-db/src/log_repo.rs` | S |
| T2 | **Audit other SQL `format!`s for the same pattern.** Grep + manual review of every `format!` in `loseit-db/src/`. Document findings in PR (likely zero further hits). | `crates/loseit-db/src/*.rs` | S |
| T3 | **Add `0008_food_kind.sql` migration.** Add column + CHECK + backfill. Apply locally and verify the sentinel row's `kind` flips. | `migrations/0008_food_kind.sql` | S |
| T4 | **Add `FoodKind` domain enum + extend `Food` struct.** Re-export from `domain/mod.rs`. Touch `service/log.rs` test-helpers that build `Food` literals (one fn `food_with_nutrition` at `service/log.rs:617`). | `crates/loseit-core/src/domain/food.rs`, `crates/loseit-core/src/domain/mod.rs`, `crates/loseit-core/src/service/log.rs` (test helpers) | M |
| T5 | **Wire `kind` through repos.** `PgFoodRepository`: add column to `SELECT_FOOD_COLS`, add field to `FoodRow`, parse in `From`, set `kind='quick_add'` in `find_or_create_quick_add`. `InMemoryFoodRepository`: stamp `kind` on both `create_custom` (Normal) and `find_or_create_quick_add` (QuickAdd). | `crates/loseit-db/src/food_repo.rs`, `crates/loseit-testing/src/foods.rs` | M |
| T6 | **Expose `kind` on the wire.** `FoodDetailResponse` adds `kind`. Update `tests/http_foods.rs` for both the `normal` and `quick_add` paths. | `crates/loseit-api/src/routes/foods.rs`, `crates/loseit-api/tests/http_foods.rs` | M |
| T7 | **OpenAPI: add `FoodKind` schema + update `FoodDetail`.** Two YAML edits per §4.5. | `server/specs/openapi.yaml` | S |
| T8 | **7b spec clarification.** Two YAML edits per §3 (operation description + schema description). No Rust. | `server/specs/openapi.yaml` | S |

Total: 8 tasks. T1+T2 land first (the actual P1 server bug). T3 is
the migration gate for T4-T7. T8 can land alongside T1 — independent
of the rest.

---

## 6. Risks / open questions

1. **No Postgres-backed integration tests.** 7a shipped precisely
   because the HTTP tests run against `InMemoryLogRepository`. A
   `#[sqlx::test]` harness against containerised PG is a separate,
   larger ticket; the §2 substring assertion + manual PR-description
   curl is the v1 regression guard. Flag for next planning.

2. **`create_many`'s ordering claim.** SQL has
   `ORDER BY x.ord … RETURNING …`; the trait docstring promises
   input-order returns. PG's planner is technically free to ignore
   ORDER BY ahead of RETURNING. In practice PG 14+ honours it on
   function-scan SELECTs, but it's not documented. Out of scope —
   no consumer depends on the order today.

3. **Sentinel name coupling in the backfill.** `0008` matches
   sentinels by `source = 'user' AND name = '__quick_add__'` —
   identical to the partial unique index in
   `0005_quick_add_sentinel.sql:3-5`. The SQL has to hardcode the
   literal; the Rust seam (`QUICK_ADD_SENTINEL_NAME` at
   `crates/loseit-core/src/repo/food.rs:12`) doesn't reach the
   migration. Any future rename ships its own migration anyway —
   acceptable.

4. **`FoodSearchHitResponse` lacks `kind`.** Conscious (§4.4).
   Search strips the sentinel, so the field would always be
   `'normal'`. Revisit if a future kind ever needs to surface there.

5. **No FE-side coordination.** `kind` is additive on the wire —
   FE flips its `foodId == quickAddFoodId` check to
   `food.kind == 'quick_add'` at its own pace.
