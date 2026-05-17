# BE-001 + BE-004 — User Unit Preferences — Implementation Tasks

Combined work for the two same-shape backend tickets adding `users.weight_unit`
and `users.height_unit`. The client (`client/lib/domain/user.dart`) already
renders and edits both preferences against a mock repo and tolerates missing
keys on `GET /me` (defaults `kg` / `cm`), so this batch is a silent rollout —
landing it does not break any pre-backend FE assumption.

Branch: `be-user-units` (already checked out — do not switch).

Read this file end-to-end. Each task is self-contained — do not look in
`be_user_units_design.md` for hints. If something genuinely isn't here, surface
it.

Flip `Status: pending` to `in_progress` when you start and `done` when finished
(in your commit message, not in this file).

---

## Conventions used in every task

- `server/...` paths are relative to the repository root.
- The next migration number is `0006`; `0001`–`0005` already exist on disk and
  are applied to the Coolify Postgres.
- Repo traits live in `loseit-core` (`server/crates/loseit-core/src/repo/`).
  Pg impls live in `loseit-db` (`server/crates/loseit-db/src/`). In-memory
  fakes live in `loseit-testing` (`server/crates/loseit-testing/src/`).
- Domain errors map: `CoreError::Validation` → 400, `CoreError::NotFound` →
  404. Wire-level invalid enum strings are converted via
  `ApiError::bad_request("...")` in `ProfilePatchBody::into_domain` *before*
  the service is invoked — see `routes/profile.rs:65-77` for the `sex` /
  `activity_level` precedent.
- The frontend reads the new fields with tolerant defaults; do not add a
  feature flag. Land the eight tasks back-to-back on `be-user-units` and let
  the FE pick up the fields once they exist.

---

## Task index

| ID | Title | Size | Suggested model |
|----|-------|------|----------------|
| T01 | Add migration `0006_user_units.sql` | S | sonnet |
| T02 | Add `WeightUnit` / `HeightUnit` enums and extend `User` / `ProfilePatch` | M | sonnet |
| T03 | Wire the in-memory user fake to default + COALESCE the new units | S | sonnet |
| T04 | Wire the Pg user repo to read/write the new columns | M | sonnet |
| T05 | Extend the `/me` handler + body type to expose / accept units | M | sonnet |
| T06 | Apply the OpenAPI delta for `WeightUnit`, `HeightUnit`, `User`, `ProfilePatch` | S | sonnet |
| T07 | Add core + in-memory tests for the unit round-trip | M | sonnet |
| T08 | Add HTTP-level tests on `http_profile.rs` covering GET/PATCH /me + unknown-key regression | M | sonnet |

---

### Task 1: Add migration `0006_user_units.sql`

**Status:** pending
**Depends on:** none
**Parallelizable with:** none — single file, but downstream tasks consume the column shape
**Estimated size:** S (1 file, ~15 LOC)
**Suggested model:** sonnet

**Scope.** Ship the schema change that adds `users.weight_unit` and
`users.height_unit`, both `TEXT NOT NULL DEFAULT`, with named `CHECK`
constraints. No Rust changes in this task.

**Context the dev needs.**
- Migration directory: `server/migrations/` — current head is
  `0005_quick_add_sentinel.sql`. Files run in lexical order on startup.
- Existing precedent for *unnamed* CHECK constraints causing pain:
  `server/migrations/0003_usda_source.sql` (had to do a DROP-by-text rather
  than DROP-by-name dance). We avoid that by naming our constraints.
- `users` is a small table (beta scale), so `ALTER TABLE ... ADD COLUMN ...
  NOT NULL DEFAULT` is a single fast rewrite; no online-migration ceremony
  required.

**Spec.**

Create `server/migrations/0006_user_units.sql` with **exactly** this content
(the leading comment header is required — it documents the enum-drift
contract for the next engineer who widens the units):

```sql
-- Add user-preference unit columns. Same shape for both: text + CHECK
-- against the OpenAPI enum + a documented default so existing rows
-- backfill cleanly. The columns are display preferences only — the
-- canonical storage (height_cm, weight_kg) is unchanged.
--
-- If the enum domain ever widens (e.g. add 'g' to weight_unit), three
-- files move together: this migration's CHECK, the Rust WeightUnit /
-- HeightUnit enums in loseit-core, and the OpenAPI schemas. The named
-- constraints below let a future migration DROP CONSTRAINT cleanly.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS weight_unit TEXT NOT NULL DEFAULT 'kg',
    ADD COLUMN IF NOT EXISTS height_unit TEXT NOT NULL DEFAULT 'cm';

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_weight_unit_check;
ALTER TABLE users ADD CONSTRAINT users_weight_unit_check
    CHECK (weight_unit IN ('kg', 'lb', 'st'));

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_height_unit_check;
ALTER TABLE users ADD CONSTRAINT users_height_unit_check
    CHECK (height_unit IN ('cm', 'ft_in'));
```

Notes on choices that the next engineer will second-guess:

- `NOT NULL DEFAULT` backfills existing rows in one statement. Postgres
  rewrites the column-default into existing rows at `ALTER TABLE` time —
  no separate `UPDATE` step.
- No index. `users` is keyed by `id` for every read path; the unit columns
  are projected by `SELECT … WHERE id = $1` and never appear in a
  predicate.
- Idempotent: `ADD COLUMN IF NOT EXISTS` + `DROP CONSTRAINT IF EXISTS`
  before `ADD CONSTRAINT` make this safe to re-run on an already-migrated
  database.

**Files to touch.**
- `server/migrations/0006_user_units.sql` — create.

**Acceptance criteria.**
- File exists at `server/migrations/0006_user_units.sql` with the content
  above (verbatim, including the comment header).
- File is the next lexical migration after `0005_quick_add_sentinel.sql`.
- No Rust files are modified by this task.

**Test plan.**
- Visual inspection — the contents must match the Spec block exactly. No
  unit test exercises this directly; T04 / T07 / T08 will catch any
  semantic mismatch between the column shape and the Rust code.
- If you have a local Postgres handy, run `sqlx migrate run` from
  `server/crates/loseit-db/` and confirm the existing `users` rows now
  carry `weight_unit = 'kg'` and `height_unit = 'cm'`. Optional but a fast
  smoke check.

**Risks / gotchas.**
- Do not omit the CHECK constraint names — an unnamed constraint will
  force a `DROP CONSTRAINT` by introspecting `pg_constraint` in the next
  widening migration, which is exactly the pain point `0003_usda_source.sql`
  already hit.
- Do not split into two migrations (one per column). One alter, one
  rewrite, fewer Coolify-deploy moving parts.

---

### Task 2: Add `WeightUnit` / `HeightUnit` enums and extend `User` / `ProfilePatch`

**Status:** pending
**Depends on:** T01
**Parallelizable with:** none — every downstream task imports from this file
**Estimated size:** M (2 files, ~80 LOC)
**Suggested model:** sonnet

**Scope.** Add two new domain enums and extend the `User` and `ProfilePatch`
structs in `loseit-core` with the new fields. Re-export the new types from
`domain/mod.rs`. After this lands, `cargo check -p loseit-core` must pass —
no other crate has been updated yet, so the workspace as a whole will not
compile until T03 and T04 land.

**Context the dev needs.**
- `server/crates/loseit-core/src/domain/user.rs` — current home of `Sex`
  (lines ~15-39), `ActivityLevel` (lines ~41-71), `User` struct (lines
  ~73-83), `ProfilePatch` struct (lines ~89-97). The new enums sit between
  `ActivityLevel` and `User`; the new struct fields sit at the bottom of
  `User` and `ProfilePatch`.
- `server/crates/loseit-core/src/domain/mod.rs` — public exports. Current
  user re-export is at line 24: `pub use user::{ActivityLevel, ProfilePatch,
  Sex, User, UserIdentity};`. Add `WeightUnit` and `HeightUnit` to that
  same line.
- Naming precedent: `ActivityLevel::VeryActive` → `"very_active"` (see
  `as_str` at user.rs:57). Use `"ft_in"` (with underscore), not `"ftin"`.

**Spec.**

Append two new enums to `server/crates/loseit-core/src/domain/user.rs`,
sibling to `ActivityLevel`, with the same `as_str` + `parse` shape:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WeightUnit {
    Kg,
    Lb,
    St,
}

impl WeightUnit {
    pub fn as_str(self) -> &'static str {
        match self {
            WeightUnit::Kg => "kg",
            WeightUnit::Lb => "lb",
            WeightUnit::St => "st",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "kg" => Some(Self::Kg),
            "lb" => Some(Self::Lb),
            "st" => Some(Self::St),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeightUnit {
    Cm,
    FtIn,
}

impl HeightUnit {
    pub fn as_str(self) -> &'static str {
        match self {
            HeightUnit::Cm => "cm",
            HeightUnit::FtIn => "ft_in",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "cm" => Some(Self::Cm),
            "ft_in" => Some(Self::FtIn),
            _ => None,
        }
    }
}
```

Extend the `User` struct with two new **required** fields (non-Option —
the DB columns are NOT NULL by construction):

```rust
pub struct User {
    pub id: Uuid,
    pub identity: UserIdentity,
    pub sex: Option<Sex>,
    pub birth_date: Option<NaiveDate>,
    pub height_cm: Option<Decimal>,
    pub activity_level: Option<ActivityLevel>,
    pub weight_unit: WeightUnit,
    pub height_unit: HeightUnit,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
```

Extend `ProfilePatch` with two new **optional** fields (`#[derive(Default)]`
on `ProfilePatch` continues to work — `Option<T>::default()` is `None`):

```rust
#[derive(Debug, Clone, Default)]
pub struct ProfilePatch {
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub sex: Option<Sex>,
    pub birth_date: Option<NaiveDate>,
    pub height_cm: Option<Decimal>,
    pub activity_level: Option<ActivityLevel>,
    pub weight_unit: Option<WeightUnit>,
    pub height_unit: Option<HeightUnit>,
}
```

Re-export the new enums from `server/crates/loseit-core/src/domain/mod.rs`:

```rust
pub use user::{ActivityLevel, HeightUnit, ProfilePatch, Sex, User, UserIdentity, WeightUnit};
```

**Files to touch.**
- `server/crates/loseit-core/src/domain/user.rs` — add enums, extend
  structs.
- `server/crates/loseit-core/src/domain/mod.rs` — extend the `pub use`
  line.

**Acceptance criteria.**
- `cargo check -p loseit-core` succeeds.
- `WeightUnit::Lb.as_str() == "lb"` and `WeightUnit::parse("st") ==
  Some(WeightUnit::St)`, plus the obvious symmetry for `HeightUnit`.
- `WeightUnit::parse("foo") == None` and `HeightUnit::parse("meters") ==
  None`.
- `ProfilePatch::default().weight_unit.is_none()` and
  `ProfilePatch::default().height_unit.is_none()`.
- The whole workspace (`cargo check --workspace`) will **not** build yet —
  that is expected; T03 and T04 close the loop.

**Test plan.**
No new tests in this task — the round-trip and validation cases land in
T07 / T08. Sanity-check yourself with `cargo check -p loseit-core`. If the
enum strings drift from `"kg" / "lb" / "st" / "cm" / "ft_in"` the CHECK
constraint in T01 will reject any persisted value; T08's HTTP tests catch
this.

**Risks / gotchas.**
- `HeightUnit::FtIn → "ft_in"` (snake_case), **not** `"ftin"` or `"ft-in"`.
  The CHECK in T01 and the OpenAPI enum in T06 both encode `ft_in`. If
  you typo this, every PATCH /me with `height_unit: "ft_in"` will 400
  before the SQL ever runs.
- Both new `User` fields are non-Option. Resist the urge to make them
  `Option<WeightUnit>` "for safety" — the column is `NOT NULL DEFAULT`
  by construction.
- The re-export line is alphabetised — keep it that way
  (`ActivityLevel, HeightUnit, ProfilePatch, Sex, User, UserIdentity,
  WeightUnit`).

---

### Task 3: Wire the in-memory user fake to default + COALESCE the new units

**Status:** pending
**Depends on:** T02
**Parallelizable with:** T04 (different crate; both consume T02)
**Estimated size:** S (1 file, ~10 LOC)
**Suggested model:** sonnet

**Scope.** Update `InMemoryUserRepository` so `create` populates the new
`User` fields with the same defaults the DB applies (`Kg` / `Cm`), and
`update_profile` overwrites them when `patch.weight_unit` /
`patch.height_unit` are `Some`. No trait change.

**Context the dev needs.**
- `server/crates/loseit-testing/src/users.rs` — the entire fake.
  `create` is at lines ~47-61 (constructs a `User` with all fields).
  `update_profile` is at lines ~63-86 (chain of `if let Some(v) =
  patch.xxx { user.xxx = Some(v); }` blocks for each patchable field).
- Imports already include `loseit_core::domain::{ProfilePatch, User,
  UserIdentity}`. You will need to extend that to bring `HeightUnit` and
  `WeightUnit` into scope.

**Spec.**

Extend the import line:

```rust
use loseit_core::domain::{HeightUnit, ProfilePatch, User, UserIdentity, WeightUnit};
```

In `create` (the `User { ... }` literal around line 49), add the two new
fields after `activity_level: None,` and before `created_at: now,`:

```rust
weight_unit: WeightUnit::Kg,
height_unit: HeightUnit::Cm,
```

In `update_profile`, after the existing `if let Some(v) = patch.activity_level
{ user.activity_level = Some(v); }` block and before
`user.updated_at = Utc::now();`, add the two parallel blocks. Note that the
new fields on `User` are non-Option, so the assignment shape differs from
the existing blocks:

```rust
if let Some(v) = patch.weight_unit {
    user.weight_unit = v;
}
if let Some(v) = patch.height_unit {
    user.height_unit = v;
}
```

This mirrors the COALESCE semantics of the Pg repo in T04: omitted patch
field → keep the previous value; provided patch field → overwrite.

**Files to touch.**
- `server/crates/loseit-testing/src/users.rs` — extend `create` and
  `update_profile`; extend the `use` import.

**Acceptance criteria.**
- `cargo check -p loseit-testing` succeeds (after T02 lands).
- After `ensure_user` against a fresh `InMemoryUserRepository`, the
  returned user has `weight_unit == WeightUnit::Kg` and
  `height_unit == HeightUnit::Cm`.
- A `ProfilePatch { weight_unit: Some(WeightUnit::Lb), ..Default::default()
  }` against an existing user overwrites only the weight unit; the height
  unit is unchanged.

**Test plan.**
No new tests in this file. T07 covers both behaviours through the service
layer using this fake.

**Risks / gotchas.**
- The new `User` fields are **non-Option** — the in-`update_profile`
  assignment is `user.weight_unit = v;`, not `user.weight_unit = Some(v);`.
- Do not change the trait. `UserRepository::update_profile` still takes
  `&ProfilePatch` as today.

---

### Task 4: Wire the Pg user repo to read/write the new columns

**Status:** pending
**Depends on:** T01, T02
**Parallelizable with:** T03 (different crate; both consume T02)
**Estimated size:** M (1 file, ~25 LOC)
**Suggested model:** sonnet

**Scope.** Update `PgUserRepository` so the new columns flow through every
read and write path. Four surgical edits in one file. After this lands the
workspace compiles end-to-end again.

**Context the dev needs.**
- `server/crates/loseit-db/src/user_repo.rs` — the entire Pg user repo.
  Anchors:
  - `UserRow` struct at lines ~22-35.
  - `impl From<UserRow> for User` at lines ~37-55. Existing parse-or-
    fallback shape: `row.sex.as_deref().and_then(Sex::parse)` for the
    nullable enums (line ~47, line ~50).
  - `SELECT_USER_COLUMNS` constant at lines ~57-58.
  - `update_profile` at lines ~103-129. Bind positions `$2`–`$7` are
    already taken (email, display_name, sex, birth_date, height_cm,
    activity_level). The new units go at `$8` and `$9`.
- Imports at the top of the file already pull in
  `loseit_core::domain::{ActivityLevel, ProfilePatch, Sex, User,
  UserIdentity}`. Extend with `HeightUnit` and `WeightUnit`.
- The Pg columns are `NOT NULL` (T01), so `UserRow`'s new fields are
  `String`, not `Option<String>`.

**Spec.**

Extend the import:

```rust
use loseit_core::domain::{
    ActivityLevel, HeightUnit, ProfilePatch, Sex, User, UserIdentity, WeightUnit,
};
```

Extend `UserRow`:

```rust
#[derive(sqlx::FromRow)]
struct UserRow {
    id: Uuid,
    issuer: String,
    external_id: String,
    email: Option<String>,
    display_name: Option<String>,
    sex: Option<String>,
    birth_date: Option<NaiveDate>,
    height_cm: Option<Decimal>,
    activity_level: Option<String>,
    weight_unit: String,
    height_unit: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}
```

Extend `impl From<UserRow> for User`. The new mappings use
`parse(...).unwrap_or(...)` — defence-in-depth: the CHECK constraint
guarantees the string is valid, but if a future Rust-enum widening lags
the migration we still produce a sensible value rather than panicking on
`unwrap`.

```rust
impl From<UserRow> for User {
    fn from(row: UserRow) -> Self {
        User {
            id: row.id,
            identity: UserIdentity {
                issuer: row.issuer,
                external_id: row.external_id,
                email: row.email,
                display_name: row.display_name,
            },
            sex: row.sex.as_deref().and_then(Sex::parse),
            birth_date: row.birth_date,
            height_cm: row.height_cm,
            activity_level: row.activity_level.as_deref().and_then(ActivityLevel::parse),
            weight_unit: WeightUnit::parse(&row.weight_unit).unwrap_or(WeightUnit::Kg),
            height_unit: HeightUnit::parse(&row.height_unit).unwrap_or(HeightUnit::Cm),
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}
```

Extend `SELECT_USER_COLUMNS` to append the two new columns. The
`INSERT … RETURNING` in `create` uses this same constant, so the migration's
column defaults flow through on INSERT — no insert-side `bind` is needed.

```rust
const SELECT_USER_COLUMNS: &str = "id, issuer, external_id, email, display_name, sex, \
    birth_date, height_cm, activity_level, weight_unit, height_unit, created_at, updated_at";
```

Update `update_profile`'s SQL and bindings — add `weight_unit` /
`height_unit` to the SET clause at positions `$8` and `$9`, and bind the
two new patch fields with the same `Option::map(... .as_str())` style as
`sex` / `activity_level`:

```rust
async fn update_profile(&self, id: Uuid, patch: &ProfilePatch) -> CoreResult<User> {
    let sql = format!(
        "UPDATE users SET \
            email          = COALESCE($2, email), \
            display_name   = COALESCE($3, display_name), \
            sex            = COALESCE($4, sex), \
            birth_date     = COALESCE($5, birth_date), \
            height_cm      = COALESCE($6, height_cm), \
            activity_level = COALESCE($7, activity_level), \
            weight_unit    = COALESCE($8, weight_unit), \
            height_unit    = COALESCE($9, height_unit) \
         WHERE id = $1 \
         RETURNING {SELECT_USER_COLUMNS}"
    );
    let row: UserRow = sqlx::query_as(&sql)
        .bind(id)
        .bind(patch.email.as_deref())
        .bind(patch.display_name.as_deref())
        .bind(patch.sex.map(|s| s.as_str()))
        .bind(patch.birth_date)
        .bind(patch.height_cm)
        .bind(patch.activity_level.map(|a| a.as_str()))
        .bind(patch.weight_unit.map(|u| u.as_str()))
        .bind(patch.height_unit.map(|u| u.as_str()))
        .fetch_one(&self.pool)
        .await
        .map_err(map_sqlx)?;
    Ok(row.into())
}
```

`find_by_id`, `find_by_identity`, `create`, and `delete_user` are not
modified — they reference `SELECT_USER_COLUMNS` or never touch the new
columns.

**Files to touch.**
- `server/crates/loseit-db/src/user_repo.rs` — four edits as above.

**Acceptance criteria.**
- `cargo check --workspace` succeeds.
- `SELECT_USER_COLUMNS` includes `weight_unit, height_unit` in the same
  comma-list position as the SQL's RETURNING (i.e. before `created_at,
  updated_at`).
- The `update_profile` SQL is one string with `weight_unit` at parameter
  `$8` and `height_unit` at `$9`, both inside `COALESCE`.
- The bindings are added in the same order as the `$n` they fill.
- No new module / file is created.

**Test plan.**
No Postgres integration test is added in this task — CI doesn't run Pg
today (see the `delete_me` note at `server/crates/loseit-api/tests/
http_profile.rs:1-13`). T07 covers the fake-side semantics that are
expected to mirror this; T08 exercises the same code path through HTTP via
the fake. If we later wire up CI Postgres, the case to add is
`pg_user_repo_rejects_invalid_weight_unit_with_check_violation`.

**Risks / gotchas.**
- The `unwrap_or` fallback in the `From<UserRow>` impl is intentional —
  do not change it to `.expect("CHECK invariant")` or `.unwrap()`. The
  CHECK is the canonical guard; the Rust read path stays graceful.
- The bind order is positional. Off-by-one between `$n` and `.bind(...)`
  is the easiest way to break this; eyeball the column-to-bind alignment
  before merging.
- Do not bind a placeholder on `INSERT … RETURNING` in `create` — the
  column DEFAULT in the migration handles new rows.

---

### Task 5: Extend the `/me` handler + body type to expose / accept units

**Status:** pending
**Depends on:** T02, T03, T04
**Parallelizable with:** T06 (different file)
**Estimated size:** M (1 file, ~40 LOC)
**Suggested model:** sonnet

**Scope.** Add the two new fields to `UserResponse` (required, not Option),
map them in `From<User> for UserResponse` via `.as_str().to_string()`, add
the two new optional string fields to `ProfilePatchBody`, and extend
`into_domain` with two parse-or-400 blocks mirroring the existing `sex` /
`activity_level` branches. The `get_me` and `patch_me` handler bodies are
unchanged structurally.

**Context the dev needs.**
- `server/crates/loseit-api/src/routes/profile.rs` — the entire profile
  handler module. Anchors:
  - `UserResponse` struct at lines ~21-34.
  - `impl From<User> for UserResponse` at lines ~36-52.
  - `ProfilePatchBody` at lines ~54-62.
  - `into_domain` at lines ~64-86. The `sex` parse block (lines 66-69)
    and `activity_level` parse block (lines 70-76) are the templates.
  - `get_me` at lines ~88-90 and `patch_me` at lines ~92-100 — unchanged.
- Current import: `use loseit_core::domain::{ActivityLevel, ProfilePatch,
  Sex, User};`.

**Spec.**

Extend the import:

```rust
use loseit_core::domain::{ActivityLevel, HeightUnit, ProfilePatch, Sex, User, WeightUnit};
```

Extend `UserResponse` with two **required** (non-Option) string fields. The
columns are NOT NULL in the DB so the serializer always emits them:

```rust
#[derive(Serialize)]
struct UserResponse {
    id: Uuid,
    issuer: String,
    external_id: String,
    email: Option<String>,
    display_name: Option<String>,
    sex: Option<String>,
    birth_date: Option<NaiveDate>,
    height_cm: Option<Decimal>,
    activity_level: Option<String>,
    weight_unit: String,
    height_unit: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}
```

Extend `impl From<User> for UserResponse`. The mapping for the new
non-nullable enums is plain `.as_str().to_string()` (no `Option::map`):

```rust
impl From<User> for UserResponse {
    fn from(u: User) -> Self {
        Self {
            id: u.id,
            issuer: u.identity.issuer,
            external_id: u.identity.external_id,
            email: u.identity.email,
            display_name: u.identity.display_name,
            sex: u.sex.map(|s| s.as_str().to_string()),
            birth_date: u.birth_date,
            height_cm: u.height_cm,
            activity_level: u.activity_level.map(|a| a.as_str().to_string()),
            weight_unit: u.weight_unit.as_str().to_string(),
            height_unit: u.height_unit.as_str().to_string(),
            created_at: u.created_at,
            updated_at: u.updated_at,
        }
    }
}
```

Extend `ProfilePatchBody`:

```rust
#[derive(Deserialize, Default)]
struct ProfilePatchBody {
    email: Option<String>,
    display_name: Option<String>,
    sex: Option<String>,
    birth_date: Option<NaiveDate>,
    height_cm: Option<Decimal>,
    activity_level: Option<String>,
    weight_unit: Option<String>,
    height_unit: Option<String>,
}
```

Extend `into_domain` with two parse-or-400 blocks (place them after the
`activity_level` block; the final `ProfilePatch { ... }` literal also
needs the two new fields):

```rust
impl ProfilePatchBody {
    fn into_domain(self) -> Result<ProfilePatch, ApiError> {
        let sex = match self.sex.as_deref() {
            None => None,
            Some(s) => Some(Sex::parse(s).ok_or_else(|| ApiError::bad_request("invalid sex"))?),
        };
        let activity_level = match self.activity_level.as_deref() {
            None => None,
            Some(s) => Some(
                ActivityLevel::parse(s)
                    .ok_or_else(|| ApiError::bad_request("invalid activity_level"))?,
            ),
        };
        let weight_unit = match self.weight_unit.as_deref() {
            None => None,
            Some(s) => Some(
                WeightUnit::parse(s)
                    .ok_or_else(|| ApiError::bad_request("invalid weight_unit"))?,
            ),
        };
        let height_unit = match self.height_unit.as_deref() {
            None => None,
            Some(s) => Some(
                HeightUnit::parse(s)
                    .ok_or_else(|| ApiError::bad_request("invalid height_unit"))?,
            ),
        };
        Ok(ProfilePatch {
            email: self.email,
            display_name: self.display_name,
            sex,
            birth_date: self.birth_date,
            height_cm: self.height_cm,
            activity_level,
            weight_unit,
            height_unit,
        })
    }
}
```

`get_me` and `patch_me` themselves are unchanged — the new fields ride
the existing `Json(user.into())` path.

**Note on unknown-key behaviour.** Do **not** add
`#[serde(deny_unknown_fields)]` to `ProfilePatchBody`. The FE's
pre-backend window assumed the server tolerates unknown keys (the
mock-repo client was already shipping `weight_unit` writes), and this
deploy plan ("land BE-001 + BE-004 silently") only works if the server
keeps ignoring extras. T08 includes a regression test
(`update_me_ignores_unrecognised_keys_returns_200`) that locks this in.

**Files to touch.**
- `server/crates/loseit-api/src/routes/profile.rs` — five surgical edits
  in one file as detailed above.

**Acceptance criteria.**
- `cargo check -p loseit-api` succeeds.
- `GET /api/v1/me` (HTTP) returns a body with `"weight_unit": "kg"` and
  `"height_unit": "cm"` for a freshly-provisioned user (verified by T08).
- `PATCH /api/v1/me` with `{"weight_unit": "lb"}` returns 200 and a body
  echoing `"weight_unit": "lb"` (T08).
- `PATCH /api/v1/me` with `{"weight_unit": "stones-and-bones"}` returns
  400 with `code: bad_request` and message `invalid weight_unit` (T08).
- Same for `{"height_unit": "meters"}` → 400 with `invalid height_unit`.
- `PATCH /api/v1/me` with `{"weight_unit": "lb", "totally_made_up_field":
  "xyzzy"}` returns 200; the unknown field is silently ignored (T08).
- No new module / file is created.

**Test plan.**
No new tests in this file — T08 owns the HTTP-level coverage.

**Risks / gotchas.**
- The new `UserResponse` fields are **required** (`String`, not
  `Option<String>`) because the columns are NOT NULL. If you make them
  `Option<String>`, the FE will see `null`s and the round-trip test in
  T08 will fail.
- The two new `into_domain` branches **must** return `400` (via
  `ApiError::bad_request`) on parse failure, not `500`. The error
  variant matches `sex` / `activity_level`.
- Resist the temptation to add `#[serde(deny_unknown_fields)]`. The
  current behaviour is a *contract* with the FE.

---

### Task 6: Apply the OpenAPI delta for `WeightUnit`, `HeightUnit`, `User`, `ProfilePatch`

**Status:** pending
**Depends on:** T05 (the wire shape is real once T05 ships; ordering keeps
the spec from running ahead of the implementation)
**Parallelizable with:** T07 (different file)
**Estimated size:** S (1 file, ~12 LOC)
**Suggested model:** sonnet

**Scope.** Three surgical edits to `server/specs/openapi.yaml`: two new
schemas under `components.schemas`, plus extensions to the existing `User`
and `ProfilePatch` schemas.

**Context the dev needs.**
- `server/specs/openapi.yaml` — anchors:
  - `NutriscoreGrade` at line 854.
  - `User` schema at line 858 (current `required: [id, issuer,
    external_id, created_at, updated_at]` at line 860).
  - `ProfilePatch` schema at line 886.
- Stylistic precedent: `Sex` and `ActivityLevel` are defined as
  `type: string, enum: [...]` standalone schemas (search nearby in
  the same file). Match that shape.
- The frontend already tolerates a missing `weight_unit` / `height_unit`
  on `GET /me` (defaults `kg` / `cm`). Marking them required here closes
  the contract but does not break the FE — the wire will now always
  carry them.

**Spec.**

**Edit 1.** Insert two new schemas immediately after `NutriscoreGrade`
(currently at line 854-856) and before `User` (line 858). Maintain the
four-space indentation that the surrounding `components.schemas` block
uses:

```yaml
    WeightUnit:
      type: string
      enum: [kg, lb, st]

    HeightUnit:
      type: string
      enum: [cm, ft_in]
```

**Edit 2.** Extend the `User` schema (line 858 onward). Add
`weight_unit` and `height_unit` to the `required` list, and add the two
properties immediately after `activity_level`. The full schema becomes:

```yaml
    User:
      type: object
      required: [id, issuer, external_id, created_at, updated_at, weight_unit, height_unit]
      properties:
        id: { type: string, format: uuid }
        issuer: { type: string }
        external_id: { type: string }
        email:
          type: [string, "null"]
          format: email
        display_name:
          type: [string, "null"]
        sex:
          oneOf:
            - $ref: "#/components/schemas/Sex"
            - type: "null"
        birth_date:
          type: [string, "null"]
          format: date
        height_cm:
          $ref: "#/components/schemas/NullableDecimal"
        activity_level:
          oneOf:
            - $ref: "#/components/schemas/ActivityLevel"
            - type: "null"
        weight_unit: { $ref: "#/components/schemas/WeightUnit" }
        height_unit: { $ref: "#/components/schemas/HeightUnit" }
        created_at: { type: string, format: date-time }
        updated_at: { type: string, format: date-time }
```

**Edit 3.** Extend the `ProfilePatch` schema (line 886 onward). The two
new properties are optional (not in `required`, no `nullable`); omission
means "leave unchanged," consistent with the existing description:

```yaml
    ProfilePatch:
      type: object
      description: Any omitted field is left unchanged.
      properties:
        email: { type: string, format: email }
        display_name: { type: string }
        sex: { $ref: "#/components/schemas/Sex" }
        birth_date: { type: string, format: date }
        height_cm: { $ref: "#/components/schemas/Decimal" }
        activity_level: { $ref: "#/components/schemas/ActivityLevel" }
        weight_unit: { $ref: "#/components/schemas/WeightUnit" }
        height_unit: { $ref: "#/components/schemas/HeightUnit" }
```

**Files to touch.**
- `server/specs/openapi.yaml` — three edits as above. Do not re-order
  any existing keys.

**Acceptance criteria.**
- `WeightUnit` and `HeightUnit` schemas are present under
  `components.schemas`.
- `User.required` contains both `weight_unit` and `height_unit`.
- `User.properties.weight_unit.$ref` and
  `User.properties.height_unit.$ref` point at the new schemas.
- `ProfilePatch.properties.weight_unit.$ref` and
  `ProfilePatch.properties.height_unit.$ref` point at the new schemas;
  `ProfilePatch.required` is unchanged (still absent from the schema).
- The file is valid YAML — `yamllint` (or your editor's YAML parser)
  reports no errors.
- `redocly lint server/specs/openapi.yaml` (if available locally) passes;
  if not, eyeball the indentation against the surrounding schemas.

**Test plan.**
No code test exercises this directly. T08's HTTP tests are the de-facto
contract check — if the wire shape diverges from this YAML, those tests
fail.

**Risks / gotchas.**
- Indentation matters. The schemas under `components.schemas` use
  four-space indent for the schema name, six-space for top-level keys
  (`type`, `required`, `properties`), and eight-space for property
  entries. Match it exactly.
- Do **not** mark `weight_unit`/`height_unit` on `ProfilePatch` as
  `required` — `ProfilePatch` is omission-tolerant by design.
- Do not re-order existing properties on `User`. Insert the new ones
  between `activity_level` and `created_at` to keep the diff minimal.

---

### Task 7: Add core + in-memory tests for the unit round-trip

**Status:** pending
**Depends on:** T03 (in-memory fake supports the new fields)
**Parallelizable with:** T06, T08 (different files)
**Estimated size:** M (2 files, ~80 LOC)
**Suggested model:** sonnet

**Scope.** Add the service-level round-trip cases against
`InMemoryUserRepository`, plus one targeted in-memory repo case that pins
the COALESCE-equivalent semantics. These tests run in milliseconds, need
no Postgres, and live as siblings to the existing
`profile_patch_applies_provided_fields_only`.

**Context the dev needs.**
- `server/crates/loseit-core/tests/services.rs` — anchors:
  - `dev_identity()` helper at lines ~14-21.
  - `ensure_user_is_idempotent` at line 24.
  - `profile_patch_applies_provided_fields_only` at line 37 — closest
    template for the new cases.
  - Imports already include `ProfilePatch`, `Sex`, `UserIdentity`,
    `UserService`, `InMemoryUserRepository`. Extend with `HeightUnit`
    and `WeightUnit`.
- `server/crates/loseit-testing/tests/in_memory_repos.rs` — currently
  covers food/log/serving/weight repos. The user repo is mostly
  exercised through the service tests, so this file gets exactly one
  targeted user-repo case.

**Spec.**

**Edit 1.** In `server/crates/loseit-core/tests/services.rs`, extend the
domain import:

```rust
use loseit_core::domain::{
    GoalDraft, HeightUnit, ProfilePatch, Sex, UserIdentity, WeightDraft, WeightUnit,
};
```

Add four new `#[tokio::test]` functions immediately after
`profile_patch_applies_provided_fields_only` (i.e. before
`weights_list_filters_by_date_window` at line 57):

```rust
#[tokio::test]
async fn new_user_defaults_to_kg_and_cm() {
    let repo = Arc::new(InMemoryUserRepository::new());
    let users = UserService::new(repo);

    let user = users.ensure_user(&dev_identity()).await.unwrap();
    assert_eq!(user.weight_unit, WeightUnit::Kg);
    assert_eq!(user.height_unit, HeightUnit::Cm);
}

#[tokio::test]
async fn update_profile_persists_weight_unit_roundtrip() {
    let repo = Arc::new(InMemoryUserRepository::new());
    let users = UserService::new(repo);

    let user = users.ensure_user(&dev_identity()).await.unwrap();

    let updated = users
        .update_profile(
            user.id,
            ProfilePatch {
                weight_unit: Some(WeightUnit::Lb),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(updated.weight_unit, WeightUnit::Lb);

    // Subsequent patch with weight_unit: None preserves the previous value
    // (COALESCE semantics).
    let untouched = users
        .update_profile(
            user.id,
            ProfilePatch {
                display_name: Some("Renamed".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(untouched.weight_unit, WeightUnit::Lb);
}

#[tokio::test]
async fn update_profile_persists_height_unit_roundtrip() {
    let repo = Arc::new(InMemoryUserRepository::new());
    let users = UserService::new(repo);

    let user = users.ensure_user(&dev_identity()).await.unwrap();

    let updated = users
        .update_profile(
            user.id,
            ProfilePatch {
                height_unit: Some(HeightUnit::FtIn),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(updated.height_unit, HeightUnit::FtIn);

    // Omitted on the next patch — preserved.
    let untouched = users
        .update_profile(
            user.id,
            ProfilePatch {
                display_name: Some("Renamed".into()),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(untouched.height_unit, HeightUnit::FtIn);
}

#[tokio::test]
async fn update_profile_changes_both_units_atomically() {
    let repo = Arc::new(InMemoryUserRepository::new());
    let users = UserService::new(repo);

    let user = users.ensure_user(&dev_identity()).await.unwrap();

    let updated = users
        .update_profile(
            user.id,
            ProfilePatch {
                weight_unit: Some(WeightUnit::St),
                height_unit: Some(HeightUnit::FtIn),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(updated.weight_unit, WeightUnit::St);
    assert_eq!(updated.height_unit, HeightUnit::FtIn);
}
```

**Edit 2.** In `server/crates/loseit-testing/tests/in_memory_repos.rs`,
add a single user-repo case at the bottom of the file. You will need to
extend the imports — at minimum `InMemoryUserRepository`, `ProfilePatch`,
`UserIdentity`, `UserRepository`, `WeightUnit`, `HeightUnit`:

```rust
#[tokio::test]
async fn in_memory_user_repo_update_profile_only_overwrites_provided_units() {
    let repo = InMemoryUserRepository::new();
    let identity = UserIdentity {
        issuer: "test".into(),
        external_id: "alice".into(),
        email: None,
        display_name: None,
    };
    let user = repo.create(&identity).await.unwrap();

    // Set weight only.
    let after_weight = repo
        .update_profile(
            user.id,
            &ProfilePatch {
                weight_unit: Some(WeightUnit::Lb),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(after_weight.weight_unit, WeightUnit::Lb);
    assert_eq!(after_weight.height_unit, HeightUnit::Cm, "height untouched");

    // Now patch height only — weight must survive.
    let after_height = repo
        .update_profile(
            user.id,
            &ProfilePatch {
                height_unit: Some(HeightUnit::FtIn),
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(after_height.weight_unit, WeightUnit::Lb, "weight survived");
    assert_eq!(after_height.height_unit, HeightUnit::FtIn);
}
```

If the existing imports at the top of `in_memory_repos.rs` don't yet
include `UserRepository` or `InMemoryUserRepository`, add them — this is
the first user-repo case in the file.

**Files to touch.**
- `server/crates/loseit-core/tests/services.rs` — extend imports; add four
  test functions.
- `server/crates/loseit-testing/tests/in_memory_repos.rs` — extend
  imports; add one test function.

**Acceptance criteria.**
- `cargo test -p loseit-core --test services` passes, including the four
  new functions.
- `cargo test -p loseit-testing --test in_memory_repos` passes, including
  the new function.
- The four service tests cover: (1) defaults on `ensure_user`, (2) weight
  round-trip with COALESCE-on-None, (3) height round-trip with
  COALESCE-on-None, (4) atomic both-units patch.

**Test plan.**
The tests themselves are the test plan. There are no negative-path cases
at this layer because invalid enum strings are caught at the wire boundary
(see T08); the service signature only accepts strongly-typed
`WeightUnit` / `HeightUnit`.

**Risks / gotchas.**
- The `..Default::default()` shorthand on `ProfilePatch` keeps these test
  literals readable — don't expand them.
- The "preserved after subsequent patch with `None`" assertion is the
  core COALESCE-semantics guard. If you drop it, a future refactor that
  accidentally overwrites with `Default` won't be caught here.
- These tests run against the **in-memory** fake. Pg behaviour is asserted
  by inspection of the SQL in T04 (no Pg CI today).

---

### Task 8: Add HTTP-level tests on `http_profile.rs` covering GET/PATCH /me + unknown-key regression

**Status:** pending
**Depends on:** T05
**Parallelizable with:** T06, T07 (different files)
**Estimated size:** M (1 file, ~150 LOC of test additions)
**Suggested model:** sonnet

**Scope.** Extend `server/crates/loseit-api/tests/http_profile.rs` (today
it covers only `DELETE /me`) with the full GET / PATCH round-trip across
the new unit fields, plus the regression guard for the unknown-keys
contract. Uses the existing `build_test_app_alice` harness.

**Context the dev needs.**
- `server/crates/loseit-api/tests/http_profile.rs` — the entire test
  module. Anchors:
  - `ALICE_TOKEN` constant at line 32.
  - `alice_identity()` helper at lines ~35-42.
  - `build_test_app_alice` at lines ~54-69 — returns the router plus a
    handle on the in-memory user repo; reuse it directly.
  - Existing tests start at line 102 (`delete_me_returns_204`). Add new
    tests below the existing ones; keep the module-level doc comment
    at the top intact.
- Imports already include `axum::body::Body`, `axum::http::{Request,
  StatusCode}`, `tower::ServiceExt`, plus all the in-memory repo types.
  You will likely also want `serde_json::Value` for body parsing — add it
  to `Cargo.toml`'s dev-dependencies if not present (it almost certainly
  already is via the api crate; check `loseit-api/Cargo.toml`
  `[dev-dependencies]`).
- Wire shape under test:
  - `GET /api/v1/me` → 200 with JSON body including
    `"weight_unit": "kg"`, `"height_unit": "cm"` for a fresh user.
  - `PATCH /api/v1/me` accepts a JSON object; the new fields are
    `weight_unit` (one of `"kg"|"lb"|"st"`) and `height_unit` (one of
    `"cm"|"ft_in"`); both optional. Invalid value → 400 with
    `ApiError::bad_request("invalid weight_unit")` /
    `("invalid height_unit")`.
  - Unknown keys are silently ignored (locked-in contract).

**Spec.**

Add a small helper near the top of the test module (after
`build_test_app_alice`, before the `// Tests` divider) so the PATCH cases
stay readable:

```rust
fn patch_body(body: &str) -> Request<Body> {
    Request::builder()
        .method("PATCH")
        .uri("/api/v1/me")
        .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
        .header("content-type", "application/json")
        .body(Body::from(body.to_string()))
        .unwrap()
}

async fn body_json(resp: axum::http::Response<Body>) -> serde_json::Value {
    let bytes = axum::body::to_bytes(resp.into_body(), 64 * 1024)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn get_me_request(app: &axum::Router) -> serde_json::Value {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    body_json(resp).await
}
```

(`axum::body::to_bytes` is the 0.7+ idiom; if the project pins an older
axum, fall back to `hyper::body::to_bytes`. Check the existing
`http_log.rs` test file for whichever helper is already in use.)

Add the following `#[tokio::test]` functions at the bottom of the file:

```rust
#[tokio::test]
async fn get_me_returns_default_units_for_new_user() {
    let (app, _users) = build_test_app_alice();
    let body = get_me_request(&app).await;
    assert_eq!(body["weight_unit"], "kg");
    assert_eq!(body["height_unit"], "cm");
}

#[tokio::test]
async fn update_me_persists_weight_unit_roundtrip() {
    let (app, _users) = build_test_app_alice();

    // Provision via GET /me first.
    let _ = get_me_request(&app).await;

    let resp = app
        .clone()
        .oneshot(patch_body(r#"{"weight_unit":"lb"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["weight_unit"], "lb");

    // Follow-up GET /me still returns "lb".
    let after = get_me_request(&app).await;
    assert_eq!(after["weight_unit"], "lb");
}

#[tokio::test]
async fn update_me_persists_height_unit_roundtrip() {
    let (app, _users) = build_test_app_alice();
    let _ = get_me_request(&app).await;

    let resp = app
        .clone()
        .oneshot(patch_body(r#"{"height_unit":"ft_in"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["height_unit"], "ft_in");

    let after = get_me_request(&app).await;
    assert_eq!(after["height_unit"], "ft_in");
}

#[tokio::test]
async fn update_me_rejects_unknown_weight_unit_value_400() {
    let (app, _users) = build_test_app_alice();
    let _ = get_me_request(&app).await;

    let resp = app
        .clone()
        .oneshot(patch_body(r#"{"weight_unit":"stones-and-bones"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    // The exact error envelope matches ApiError::bad_request; check both
    // the code (or status) and the human-readable message.
    let msg = body["message"].as_str().unwrap_or_default();
    assert!(
        msg.contains("invalid weight_unit"),
        "expected `invalid weight_unit` in error body, got {body:?}"
    );
}

#[tokio::test]
async fn update_me_rejects_unknown_height_unit_value_400() {
    let (app, _users) = build_test_app_alice();
    let _ = get_me_request(&app).await;

    let resp = app
        .clone()
        .oneshot(patch_body(r#"{"height_unit":"meters"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    let msg = body["message"].as_str().unwrap_or_default();
    assert!(
        msg.contains("invalid height_unit"),
        "expected `invalid height_unit` in error body, got {body:?}"
    );
}

#[tokio::test]
async fn update_me_ignores_unrecognised_keys_returns_200() {
    // Regression guard for the deliberate "ignore unknown JSON keys"
    // contract on PATCH /me. The FE shipped weight_unit/height_unit
    // pre-backend assuming the server would silently drop them; this
    // test locks the assumption in so a future hygiene refactor adding
    // `#[serde(deny_unknown_fields)]` hits a red test instead of
    // breaking customers in the field.
    let (app, _users) = build_test_app_alice();
    let _ = get_me_request(&app).await;

    let resp = app
        .clone()
        .oneshot(patch_body(
            r#"{"weight_unit":"lb","totally_made_up_field":"xyzzy"}"#,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["weight_unit"], "lb");
}

#[tokio::test]
async fn update_me_unit_only_patch_preserves_other_fields() {
    let (app, _users) = build_test_app_alice();
    let _ = get_me_request(&app).await;

    // Pre-set display_name.
    let _ = app
        .clone()
        .oneshot(patch_body(r#"{"display_name":"Alice Cooper"}"#))
        .await
        .unwrap();

    // Patch weight_unit only.
    let resp = app
        .clone()
        .oneshot(patch_body(r#"{"weight_unit":"lb"}"#))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["weight_unit"], "lb");
    assert_eq!(body["display_name"], "Alice Cooper");
}
```

**Files to touch.**
- `server/crates/loseit-api/tests/http_profile.rs` — append helpers and
  seven new `#[tokio::test]` functions.

**Acceptance criteria.**
- `cargo test -p loseit-api --test http_profile` passes (all existing
  `delete_me_*` tests + all seven new tests).
- The unknown-keys test (`update_me_ignores_unrecognised_keys_returns_200`)
  asserts a `200` and that `weight_unit == "lb"` is in the response body.
- The two `*_400` tests assert both the status code **and** the message
  fragment `invalid weight_unit` / `invalid height_unit` — message
  matching catches a regression where the handler silently coerces
  garbage to a default.
- `update_me_unit_only_patch_preserves_other_fields` confirms the
  COALESCE-equivalent semantics end-to-end through the wire layer.

**Test plan.**
The tests themselves. The only manual smoke worth running is
`cargo test --manifest-path server/Cargo.toml --workspace` once T01–T08
are all merged, to confirm nothing else regressed.

**Risks / gotchas.**
- Body decoding: use whichever helper the rest of the test files in
  `server/crates/loseit-api/tests/` use today (axum 0.7+: `axum::body::
  to_bytes`; older: `hyper::body::to_bytes`). The pattern `to_bytes(body,
  usize::MAX)` is fine; the 64KB cap above is generous.
- The error-message assertion uses substring match (`contains(...)`)
  rather than equality, in case `ApiError::bad_request` wraps the
  message. Keep it as substring — full-equality assertions on error
  bodies are brittle to envelope churn.
- The `update_me_ignores_unrecognised_keys_returns_200` test is **not**
  optional. The whole rollout plan ("FE pre-shipped against the mock and
  assumed the server would ignore extras") depends on this contract.
  Document the test in its body comment so a future reviewer doesn't
  delete it as "redundant."

---

## Dependency graph

```
                T01 (migration)
                  │
                  ▼
                T02 (domain enums + struct fields)
                  │
        ┌─────────┼─────────┐
        ▼                   ▼
       T03                 T04
   (in-mem fake)         (Pg repo)
        │                   │
        └─────────┬─────────┘
                  ▼
                T05 (handler + body type)
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
       T06       T07       T08
    (OpenAPI)  (svc+fake  (HTTP
               tests)     tests)
```

Parallelism notes (assuming separate engineer-sessions per task):

- T03 and T04 can land in parallel once T02 is merged — different crates,
  no shared file.
- T06, T07, T08 can land in parallel once T05 is merged — different files.
- T01 is technically parallelizable with T02 (T02 only imports the columns
  logically), but in practice both are tiny and a clean linear order is
  easier to review.

Critical path: T01 → T02 → T04 → T05 → T08 — five tasks long.

Final workspace verification once all eight are merged on
`be-user-units`:

```
cargo check --manifest-path /workplace/fulfilled/server/Cargo.toml --workspace
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-core -p loseit-testing -p loseit-api --test http_profile
```
