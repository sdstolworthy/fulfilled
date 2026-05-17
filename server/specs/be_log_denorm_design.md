# BE-010 — Denormalize `food_name` + `serving_name` onto `LogEntry` Wire Responses — Architect Design

Branch: `be-log-denorm`. Addresses `backend_tasks.md` Ask 9 (lines 760-816).

---

## 1. Overview

`GET /log` returns log entries with no `food_name` or `serving_name` fields. The
Flutter client decodes these via `LogEntry.fromJson` (`client/lib/domain/log_entry.dart:95`),
which falls back to `''` when the keys are absent — producing blank food labels on the
day-view. The fix is a JOIN-on-read: extend every SQL path that returns a
`FoodLogEntry` to `LEFT JOIN foods` and `LEFT JOIN servings`, appending
`f.name AS food_name` and `s.name AS serving_name` to the SELECT list. No
migration is required — both names already live in their respective tables;
this change only widens the wire projection.

**Explicit non-goals:** no schema migration, no backfill, no new endpoint, no
change to the `DaySummary` shape (`/days/{date}/summary` returns aggregated
`by_meal` subtotals — not individual entries — and that shape does not change
here). The `backend_tasks.md` Ask 9 mention of "embedded `entries` array" on
the day summary refers to the `GET /log?from=&to=` endpoint being the
authoritative individual-entries source; the existing day-summary route is
aggregation-only and remains so.

---

## 2. Design

### 2.1 Domain types

**Decision: add `food_name` and `serving_name` directly to `FoodLogEntry`
in `crates/loseit-core/src/domain/log_entry.rs`.**

This follows the exact precedent set by `Food.kind` (Ask 7c, `be_live_deploy_fixes_design.md`
§4.2) where a new domain field was added to the core struct rather than a
separate DTO. The handler's `From<FoodLogEntry> for LogEntryResponse` then
surfaces it automatically with no extra mapping layer.

Shape additions to `FoodLogEntry` (`domain/log_entry.rs:25`):

```rust
pub food_name: String,
pub serving_name: Option<String>,
```

`food_name` is `String` (not `Option<String>`) — see §2.5 for the FK invariant
that guarantees a non-NULL value. `serving_name` is `Option<String>` because
`serving_id` is nullable: a quick-add entry has `serving_id = NULL` and the
LEFT JOIN produces NULL, which maps naturally to `None`.

`PersistedLogEntry` does NOT gain these fields — it is the repo-facing write
shape and the repo is responsible for resolving names on the read path. The
write contract is unchanged.

### 2.2 Pg repo (`crates/loseit-db/src/log_repo.rs`)

Two structural changes:

**a) `LogEntryRow`** (`log_repo.rs:30`) gains two new fields:

```rust
food_name: String,
serving_name: Option<String>,
```

**b) `SELECT_COLS`** (`log_repo.rs:87`) is renamed and widened:

```rust
const SELECT_COLS: &str = "\
    le.id, le.user_id, le.food_id, le.serving_id, le.consumed_on, le.meal, \
    le.quantity, le.grams_total, le.calories_kcal, le.protein_g, le.carbs_g, le.fat_g, \
    le.fiber_g, le.sugar_g, le.sodium_mg, le.saturated_fat_g, le.note, \
    le.created_at, le.updated_at, \
    COALESCE(f.name, '') AS food_name, \
    s.name AS serving_name";

const FROM_CLAUSE: &str = "\
    food_log_entries le \
    LEFT JOIN foods    f ON f.id = le.food_id \
    LEFT JOIN servings s ON s.id = le.serving_id";
```

Using `COALESCE(f.name, '')` for `food_name` rather than a bare `f.name` is
belt-and-suspenders for the orphan case (see §2.5); all other places treat
`food_name` as non-nullable.

**Affected queries** — every method that currently emits `SELECT {SELECT_COLS}
FROM food_log_entries …` must switch to `SELECT {SELECT_COLS} FROM
{FROM_CLAUSE} …`. The full list:

| Method | Lines (approx) |
|---|---|
| `create` — RETURNING clause | `log_repo.rs:101` |
| `update` — RETURNING clause | `log_repo.rs:179` |
| `find_by_id` | `log_repo.rs:219-221` |
| `list_in_range` | `log_repo.rs:238-241` |
| `list_for_day` | `log_repo.rs:256-259` |
| `list_paginated` | `log_repo.rs:356-361` |
| `create_many` — RETURNING clause | `log_repo.rs:485` |

`count_in_range` (`log_repo.rs:382`) and `any_entry_references_food`
(`log_repo.rs:335`) do not return rows, so they are untouched.
`recent_food_ids` and `frequent_food_ids` already carry their own `JOIN foods`
and do not return `FoodLogEntry` — unchanged.

The `From<LogEntryRow> for FoodLogEntry` impl (`log_repo.rs:54`) gains two
field mappings:

```rust
food_name: row.food_name,
serving_name: row.serving_name,
```

### 2.3 In-memory fake (`crates/loseit-testing/src/logs.rs`)

**Decision: inject `Arc<InMemoryFoodRepository>` + `Arc<InMemoryServingRepository>`
at construction / via setter, and look up names on every `FoodLogEntry`-producing
read path.**

Rationale: option (a) — inject repos and look up at read time — is more
realistic than option (b) (stamp at write time). Write-time stamping would
silently stale if a test mutates a food name after logging; read-time lookup
matches the semantics of the Pg JOIN, and it is the established precedent in
this codebase — `InMemoryLogRepository` already does exactly this for
`recent_food_ids` / `frequent_food_ids` via the
`set_food_repo_for_sentinel_filter` pattern (`logs.rs:33-35`).

The existing `foods: Mutex<Option<Arc<InMemoryFoodRepository>>>` field is
repurposed. Add a parallel `servings: Mutex<Option<Arc<InMemoryServingRepository>>>`.
Add a paired setter `set_serving_repo(...)`. Then introduce a helper:

```rust
async fn resolve_names(&self, user_id: Uuid, entry: &mut FoodLogEntry) {
    if let Some(foods) = self.foods.lock().unwrap().clone() {
        if let Ok(Some(food)) = foods.find_by_id(user_id, entry.food_id).await {
            entry.food_name = food.name;
        }
    }
    if let Some(sid) = entry.serving_id {
        if let Some(servings) = self.servings.lock().unwrap().clone() {
            if let Ok(Some(serving)) = servings.find_by_id(sid).await {
                entry.serving_name = Some(serving.label);
            }
        }
    }
}
```

This helper is called after every path that constructs a `FoodLogEntry` from
`PersistedLogEntry`: `create`, `create_many`, `update`, `find_by_id`,
`list_in_range`, `list_for_day`, `list_paginated`.

**Test wiring:** tests that do not call the new setters will compile and run
correctly — `food_name` will be an empty string (repo not wired, COALESCE
semantics). Tests that need `food_name` populated (the new HTTP tests) wire
both repos explicitly, same as the existing `set_food_repo_for_sentinel_filter`
usage.

### 2.4 Handler / DTO (`crates/loseit-api/src/routes/log.rs`)

`LogEntryResponse` (`log.rs:137`) gains two fields:

```rust
food_name: String,
serving_name: Option<String>,
```

`From<FoodLogEntry> for LogEntryResponse` (`log.rs:160`) maps them straight
through:

```rust
food_name: e.food_name,
serving_name: e.serving_name,
```

`DaySummaryResponse` is unchanged — it does not embed `LogEntry` objects; it
embeds `MealSubtotalResponse` aggregates. No change to `routes/days.rs` (note:
day summary lives in `routes/log.rs:349` per the module comment, not a
separate file).

### 2.5 Orphan food / FK invariant

`food_log_entries.food_id` has `REFERENCES foods(id) ON DELETE RESTRICT`
(`migrations/0001_initial.sql:209`). This means a food cannot be deleted while
any log entry references it — `FoodService::delete_custom` surfaces a 409
before the repo even attempts the DELETE (`service/food.rs:250`). Therefore
`food_id` in any live log row always has a corresponding foods row, and
`f.name` after `LEFT JOIN foods f ON f.id = le.food_id` can never be NULL in
practice. The `COALESCE(f.name, '')` in `SELECT_COLS` is defense-in-depth
only — it prevents a surprising `sqlx` decode error if the invariant is ever
violated outside the API (e.g. manual DB intervention). **No behavioral change
is needed; `food_name: String` is the correct type.**

`serving_id` is `ON DELETE SET NULL` (`migrations/0001_initial.sql:210`).
A deleted serving legitimately produces a NULL `s.name` — correctly mapped to
`serving_name: None` on the domain and `null` on the wire.

### 2.6 OpenAPI delta (`server/specs/openapi.yaml`)

`LogEntry` schema (`openapi.yaml:1451`):

Add `food_name` to `required`:

```yaml
      required:
        - id
        - food_id
        - food_name          # added
        - consumed_on
        - meal
        - quantity
        - grams_total
        - calories_kcal
        - created_at
        - updated_at
```

Add two properties after `food_id`:

```yaml
        food_name:
          type: string
          description: |
            Denormalized name of the referenced food at read time. Always
            present; the foods FK is RESTRICT so the food row is guaranteed
            to exist while any log entry references it.
        serving_name:
          type: [string, "null"]
          description: |
            Denormalized label of the referenced serving, or null when
            serving_id is null (e.g. quick-add entries).
```

---

## 3. Sequenced task list

Four tasks. Each is well-scoped to 1–3 files with associated test churn.

**T01 — Core domain: add `food_name` + `serving_name` to `FoodLogEntry`**

Files: `crates/loseit-core/src/domain/log_entry.rs`.

Add the two fields to the struct. Every place that constructs a `FoodLogEntry`
literal — primarily test helpers and the in-memory fake's `create` path — must
be updated to supply values. Likely locations:
- `crates/loseit-core/src/service/log.rs` test helpers (e.g.
  `food_with_nutrition` analogue around `service/log.rs:617`).
- Any `FoodLogEntry { … }` struct literal in `crates/loseit-core/tests/`.
- `crates/loseit-testing/src/logs.rs:72` — the `create` impl.

Compile gate: `cargo check -p loseit-core -p loseit-testing` must pass before
moving to T02.

**T02 — Pg repo: JOIN + populate**

Files: `crates/loseit-db/src/log_repo.rs`.

Introduce `SELECT_COLS` and `FROM_CLAUSE` constants as specified in §2.2.
Alias existing `food_log_entries` columns with `le.` prefix. Add
`food_name: String` and `serving_name: Option<String>` to `LogEntryRow`.
Update `From<LogEntryRow>`. Update every SELECT query per the table in §2.2.
Run `cargo check -p loseit-db`. No Pg integration tests today (existing gap
documented in `be_live_deploy_fixes_design.md` §6 risk #1); add a
`select_cols_no_inline_comment` regression string-test under
`log_repo.rs::tests` matching the existing `create_many_sql_has_no_inline_comments`
pattern.

**T03 — In-memory fake: inject serving repo + populate names**

Files: `crates/loseit-testing/src/logs.rs`.

Add `servings: Mutex<Option<Arc<InMemoryServingRepository>>>` field and
`set_serving_repo` setter (mirroring the existing food-repo setter at
`logs.rs:33`). Add `resolve_names` async helper. Call it from `create`,
`update`, `find_by_id`, `list_in_range`, `list_for_day`, `list_paginated`,
`create_many`. Populate `food_name = ""` and `serving_name = None` by default
when repos are not wired — this satisfies the `String` (not `Option`) type
without panicking.

Run `cargo test -p loseit-testing -p loseit-core`.

**T04 — Handler wire + HTTP tests + OpenAPI delta**

Files:
- `crates/loseit-api/src/routes/log.rs` — add fields to `LogEntryResponse`
  and `From<FoodLogEntry>` per §2.4.
- `crates/loseit-api/tests/http_log.rs` — two new tests:
  1. `list_log_entries_include_food_name_and_serving_name` — create a food +
     serving + log entry, call `GET /log?from=&to=`, assert `food_name` equals
     the food's name and `serving_name` equals the serving's label.
  2. `list_log_entries_quick_add_has_no_serving_name` — create via
     `POST /log/quick_add`, call `GET /log`, assert `food_name` is non-empty
     and `serving_name` is null.
- `server/specs/openapi.yaml` — apply §2.6 delta.

Run `cargo test -p loseit-api`. Full workspace check:
`cargo check --manifest-path /workplace/fulfilled/server/Cargo.toml --workspace`.

---

## 4. Risks / open questions

**R1 — NULL `food_name` from orphaned `food_id`.** Covered in §2.5: the RESTRICT
FK makes this impossible via the API. The `COALESCE(f.name, '')` in the SQL is
defense-in-depth. No action needed.

**R2 — `create` / `update` RETURNING paths carry the JOIN.**
`RETURNING {SELECT_COLS}` in the INSERT and UPDATE queries will now resolve
names in the same round-trip as the write. This is safe and avoids a separate
SELECT, but it requires the `FROM {FROM_CLAUSE}` alias approach to work with
`RETURNING`. Postgres supports `RETURNING expr` over JOINed aliases in
`INSERT … SELECT … FROM … RETURNING` and `UPDATE … FROM … RETURNING`. The
plain `INSERT … VALUES … RETURNING` and `UPDATE … SET … WHERE … RETURNING`
forms do **not** support `FROM` joins. Architect's ruling: for `create` and
`update`, issue a follow-up `find_by_id` SELECT after the RETURNING, OR use a
CTE wrapper (`WITH ins AS (INSERT … RETURNING id) SELECT … FROM ins JOIN foods …`).
The CTE wrapper is cleaner. Alternatively, accept that `create`/`update`
RETURNING populates `food_name`/`serving_name` as empty strings at the Pg
layer and rely on a second select. **Simplest path: after the INSERT/UPDATE,
execute a `find_by_id` using the returned `id`** — one extra round-trip on
writes, zero risk of SQL restructuring. The list/paginated paths are pure
SELECTs and the JOIN works cleanly there. T02 engineer should pick the CTE
approach if they want single-round-trip; the find_by_id approach if they want
minimal SQL risk. Document the choice in the PR.

**R3 — Test wiring boilerplate.** HTTP tests for `GET /log` need a food +
serving pre-seeded in the in-memory repos AND the log repo wired to both. The
existing `build_test_app_*` harness (`tests/http_log.rs`) already seeds Alice
with a food via `InMemoryFoodRepository` — T04 extends this pattern.

---

## 5. Notes for engineers

- The `food_name`/`serving_name` fields are additive on the wire — the FE
  `LogEntry.fromJson` already handles their absence with `?? ''` fallback
  (`client/lib/domain/log_entry.dart:95`). No FE coordination needed; the FE
  will switch from the cache-based stopgap to direct field reads once this
  lands.
- `serving_name` maps to the `Serving.label` field in the domain/DB (e.g.
  `"100 g"`, `"kcal"`), not a separate `name` column. Verify the column name
  in `servings` before writing the SQL alias; it is `label` in
  `crates/loseit-core/src/domain/serving.rs`.
- The existing `SELECT_COLS` const is currently used in the
  `create_many_sql_has_no_inline_comments` unit test (`log_repo.rs:527`).
  Update that test's SQL string when renaming/widening `SELECT_COLS`.
- The `DaySummary` shape is NOT changing. Do not add an `entries` array to
  `DaySummary`/`DaySummaryResponse` — that is a separate, unspecified ticket.
