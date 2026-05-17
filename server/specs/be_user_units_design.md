# BE-001 + BE-004 — User Unit Preferences — Architect Design

Combined design for the two same-shape tickets adding user-preference unit
columns (`users.weight_unit`, `users.height_unit`). The TPM should be able
to slice this into ordered, single-engineer tasks without coming back for
clarifications.

---

## 1. Overview

The client already renders and edits `weight_unit` and `height_unit`
preferences (`WeightUnit { kg, lb, st }` and `HeightUnit { cm, ft_in }`)
against the mock repository. `User.fromJson` tolerates missing keys and
defaults to `kg` / `cm`, so the FE has been shipping pre-backend. This
batch closes the cross-device parity gap: a preference set on one device
survives re-login on another.

The two tickets are routed as a single design effort because they are
structurally identical (one new `text` column on `users` with a CHECK,
one new domain enum mirroring `Sex`/`ActivityLevel`, one new `User` field,
one new optional `ProfilePatch` field, one OpenAPI enum + two schema
edits). Shipping them together avoids two migrations on a hot table and
two near-identical PRs.

Dependencies — none. The columns are independent of every other
in-flight backend ticket (BE-002/3 are barcode-side; BE-005 is a separate
query). Migration `0006_user_units.sql` is the next number; `0001`–`0005`
are already applied to the Coolify Postgres.

---

## 2. Schema migration — `server/migrations/0006_user_units.sql`

Single combined migration. Idempotent so a re-run on an already-migrated
database is a no-op. CHECKs are named so a future migration can `DROP
CONSTRAINT` them by name (`0003_usda_source.sql` had to do this song-and-
dance for the unnamed `source` check; we avoid that).

```sql
-- Add user-preference unit columns. Same shape for both: text + CHECK
-- against the OpenAPI enum + a documented default so existing rows
-- backfill cleanly. The columns are display preferences only — the
-- canonical storage (height_cm, weight_kg) is unchanged.

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

Notes:

- `NOT NULL DEFAULT` backfills the existing rows in a single statement;
  Postgres rewrites the default for existing rows at `ALTER TABLE` time.
- No new index. `users` is keyed by `id` for every read path; the unit
  columns are returned by `SELECT … WHERE id = $1` and never appear in a
  predicate.
- The `WeightUnit`/`HeightUnit` OpenAPI enums (§5) and the Rust enums
  (§3) keep these CHECK strings in sync. If the enum domain ever widens,
  it's a three-file change — migration + Rust enum + OpenAPI — and the
  CHECK constraint is the canonical truth at the DB.

---

## 3. Domain / service / repo changes

### 3.1 New domain enums — `server/crates/loseit-core/src/domain/user.rs`

Two new enums sibling to `Sex` (`user.rs:15`) and `ActivityLevel`
(`user.rs:41`), with the same `as_str` / `parse` shape that the
service-layer validators already lean on:

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

`HeightUnit::FtIn → "ft_in"` (not `"ftin"`) mirrors
`ActivityLevel::VeryActive → "very_active"` precedent (`user.rs:57`).

The `User` struct (`user.rs:74`) gains two new required fields:

```rust
pub weight_unit: WeightUnit,
pub height_unit: HeightUnit,
```

Both are non-Option — every row in the DB has a value by construction (the
migration defaults backfill existing rows; new rows get the column default
on `INSERT`).

`ProfilePatch` (`user.rs:90`) gains two optional fields:

```rust
pub weight_unit: Option<WeightUnit>,
pub height_unit: Option<HeightUnit>,
```

`#[derive(Default)]` on `ProfilePatch` continues to work; `Option<T>`'s
default is `None`.

Re-export both new enums from `domain/mod.rs:24` alongside the existing
exports.

### 3.2 Repository changes — `server/crates/loseit-db/src/user_repo.rs`

Three surgical edits:

1. `UserRow` (`user_repo.rs:22`) gains `weight_unit: String,
   height_unit: String,`. They're non-Option because the DB columns are
   NOT NULL.
2. `impl From<UserRow> for User` (`user_repo.rs:37`) maps both fields via
   `WeightUnit::parse(&row.weight_unit).unwrap_or(WeightUnit::Kg)` and
   the equivalent for height. The `unwrap_or` fallback is defence-in-
   depth — the CHECK constraint guarantees the value is one of the enum
   strings, but if a future widening drops a value out of the Rust enum
   ahead of a deploy, the read path still produces a sensible default
   rather than panicking on `unwrap()`. (Matches the
   `row.sex.as_deref().and_then(Sex::parse)` style at `user_repo.rs:47`,
   just non-nullable.)
3. `SELECT_USER_COLUMNS` (`user_repo.rs:57`) appends `weight_unit,
   height_unit` to the column list. The `INSERT … RETURNING` in `create`
   (`user_repo.rs:86`) uses this constant, so the migration's column
   defaults flow through automatically — no insert-side change needed.
4. `update_profile` (`user_repo.rs:103`) gets two new `COALESCE` lines
   in the `SET` clause and two new `bind` calls, parameter positions
   `$8` / `$9`:

   ```rust
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
   ```

   Bindings: `.bind(patch.weight_unit.map(|u| u.as_str()))` and the
   equivalent for height, matching the `Sex` / `ActivityLevel` binding
   style at `user_repo.rs:121`/`124`.

### 3.3 In-memory fake — `server/crates/loseit-testing/src/users.rs`

`InMemoryUserRepository::create` (`users.rs:47`) sets
`weight_unit: WeightUnit::Kg, height_unit: HeightUnit::Cm` on the
constructed `User`, matching the DB-side defaults. `update_profile`
(`users.rs:63`) gains two `if let Some(v) = patch.weight_unit { ... }`
blocks — same shape as the existing fields. No new method on the trait.

### 3.4 Service layer — `server/crates/loseit-core/src/service/user.rs`

No change. `UserService::update_profile` (`service/user.rs:39`) is a
straight delegate to the repo; validation happens at the API boundary
when the wire string is parsed into the domain enum. See §4.

### 3.5 Where validation lives

**Decision: strict service-side enum parse with `CoreError::Validation`
returning 400 BEFORE the DB sees it.** Precedent: `ProfilePatchBody`
already does exactly this for `sex` and `activity_level` at
`routes/profile.rs:65-77` — `Sex::parse(s).ok_or_else(|| ApiError::
bad_request("invalid sex"))`. We extend the same `into_domain` adapter
with two more match arms; no service-layer error variant is added.

The DB-level CHECK constraint stays as a belt-and-suspenders guard.
If a request ever slips past the wire validator (e.g. via a future bulk
import path), Postgres rejects the row with `23514` and the existing
`map_sqlx` translates it to `CoreError::Internal` — visible in logs but
never a 200.

---

## 4. Handler changes — `server/crates/loseit-api/src/routes/profile.rs`

### 4.1 `GET /me`

`UserResponse` (`profile.rs:21`) gains two required fields:

```rust
weight_unit: String,
height_unit: String,
```

Required, not `Option<String>` — the column is NOT NULL. `impl From<User>
for UserResponse` (`profile.rs:36`) maps via `.as_str().to_string()` on
each enum, matching the pattern `sex.map(|s| s.as_str().to_string())`
already used at `profile.rs:44` (without the `Option::map`, since these
are non-nullable). The handler `get_me` (`profile.rs:88`) is unchanged
— it returns `Json(user.into())` and the new fields flow through the
existing `From` impl.

### 4.2 `PATCH /me`

`ProfilePatchBody` (`profile.rs:54`) gains two optional string fields:

```rust
weight_unit: Option<String>,
height_unit: Option<String>,
```

`into_domain` (`profile.rs:65`) gains two parse-or-400 blocks mirroring
the existing `sex` / `activity_level` branches:

```rust
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
```

`patch_me` (`profile.rs:92`) is unchanged structurally — the body
deserialises, `into_domain` validates and lifts to the domain
`ProfilePatch`, the service persists, the response includes the new
fields via the updated `From<User>`.

---

## 5. OpenAPI delta — `server/specs/openapi.yaml`

Three edits to `components.schemas`.

### 5.1 Two new enum schemas (insert after `NutriscoreGrade` at line 856)

```yaml
    WeightUnit:
      type: string
      enum: [kg, lb, st]

    HeightUnit:
      type: string
      enum: [cm, ft_in]
```

### 5.2 `User` schema edit (line 858 onward)

Add `weight_unit` and `height_unit` to `required`, add the two
properties:

```yaml
    User:
      type: object
      required: [id, issuer, external_id, created_at, updated_at, weight_unit, height_unit]
      properties:
        # ... existing properties unchanged ...
        weight_unit: { $ref: "#/components/schemas/WeightUnit" }
        height_unit: { $ref: "#/components/schemas/HeightUnit" }
        created_at: { type: string, format: date-time }
        updated_at: { type: string, format: date-time }
```

### 5.3 `ProfilePatch` schema edit (line 886 onward)

Two optional properties; not required, not nullable (omission = leave
unchanged, per the `ProfilePatch` description at line 888):

```yaml
    ProfilePatch:
      type: object
      description: Any omitted field is left unchanged.
      properties:
        # ... existing properties unchanged ...
        weight_unit: { $ref: "#/components/schemas/WeightUnit" }
        height_unit: { $ref: "#/components/schemas/HeightUnit" }
```

The frontend's `User.fromJson` tolerance for a missing key
(`architect_log_edit_and_units.md` §3.3) and the FE optimistic-write
flow (`architect_qol.md` §10.3) work as-is against this shape.

---

## 6. Answer to the unknown-keys question

**Today's behaviour: the Rust API silently ignores unknown JSON keys on
`PATCH /me`.**

Evidence — `ProfilePatchBody` at
`server/crates/loseit-api/src/routes/profile.rs:54-62` is a plain
`#[derive(Deserialize, Default)] struct` with no
`#[serde(deny_unknown_fields)]` attribute. `serde`'s default for derived
`Deserialize` impls is to skip unknown fields without erroring. A repo-
wide `grep -rn deny_unknown_fields server/` returns zero matches; no
custom `Deserialize` impl or middleware overrides this. The behaviour is
the same for every PATCH/POST body in the API.

**Recommendation: keep the current behaviour (ignore).** It's already
what the FE pre-backend window assumed (`architect_qol.md:1696-1704`,
`architect_log_edit_and_units.md:1216-1231`); both the
`weight_unit`/`height_unit` client sweeps shipped against mock repos
without a feature flag, and that "land BE-001 + BE-004 silently" rollout
plan only works if the server has been ignoring the extra keys all
along.

No code change required by this design — the assertion is "we verified
the architect's expected behaviour matches reality, and we're explicitly
choosing to lock it in." We should add a regression test
(`patch_me_ignores_unrecognised_keys_returns_200`) so a future engineer
adding `#[serde(deny_unknown_fields)]` for "hygiene" reasons hits a red
test instead of a customer outage.

---

## 7. Test plan

Three layers, in the order an engineer should add them.

### 7.1 Core service tests — `server/crates/loseit-core/tests/services.rs`

Sibling to `profile_patch_applies_provided_fields_only`
(`services.rs:37`). All run against `InMemoryUserRepository`:

- `update_profile_persists_weight_unit_roundtrip` — set
  `WeightUnit::Lb`, read back, assert the field round-trips. Then patch
  with `weight_unit: None` and assert the value is preserved (COALESCE
  semantics).
- `update_profile_persists_height_unit_roundtrip` — same shape for
  `HeightUnit::FtIn`.
- `new_user_defaults_to_kg_and_cm` — `ensure_user` on a fresh identity
  returns `weight_unit == WeightUnit::Kg && height_unit == HeightUnit
  ::Cm`. Pins the fake's default in lockstep with the DB default.
- `update_profile_changes_both_units_atomically` — single
  `ProfilePatch` setting both units; both land, single repo call.

### 7.2 In-memory repo unit tests — `server/crates/loseit-testing/tests/in_memory_repos.rs`

The existing file is light on user-repo coverage (most user behaviour
is exercised through the service tests). Add one targeted case:

- `in_memory_user_repo_update_profile_only_overwrites_provided_units` —
  set `weight_unit = Some(Lb)`, leave `height_unit = None`, assert the
  previous height_unit survives. Mirrors the `COALESCE` semantics of the
  Pg repo.

### 7.3 HTTP-level tests — `server/crates/loseit-api/tests/http_profile.rs`

The file currently only covers `DELETE /me` (`http_profile.rs:1-13`).
Extend it — same `build_test_app_alice` harness. Add a small JSON-body
helper `patch_body(body: &str) -> Request` to keep cases readable.

- `get_me_returns_default_units_for_new_user` — provision Alice via
  `GET /me`, assert response body has `"weight_unit":"kg"` and
  `"height_unit":"cm"`.
- `update_me_persists_weight_unit_roundtrip` — `PATCH /me {"weight_unit":
  "lb"}` returns 200 + `"weight_unit":"lb"`. Follow-up `GET /me` still
  returns `"lb"`.
- `update_me_persists_height_unit_roundtrip` — same shape for
  `{"height_unit": "ft_in"}`.
- `update_me_rejects_unknown_weight_unit_value_400` — `PATCH /me
  {"weight_unit": "stones-and-bones"}` returns 400 with body matching
  `ApiError::bad_request("invalid weight_unit")`.
- `update_me_rejects_unknown_height_unit_value_400` — same shape for an
  unknown height unit (e.g. `"meters"`).
- `update_me_ignores_unrecognised_keys_returns_200` — `PATCH /me
  {"weight_unit":"lb","totally_made_up_field":"xyzzy"}` returns 200, and
  the legitimate field persists. **This is the regression guard for
  §6's decision.**
- `update_me_unit_only_patch_preserves_other_fields` — pre-set
  `display_name`, then `PATCH /me {"weight_unit":"lb"}`, assert the
  display_name is still present in the response.

### 7.4 Postgres-level coverage

We do not run Pg in CI today (`v1_finishup_design.md:13` and the
existing `delete_me` test note at `http_profile.rs:11-13` document the
gap). The CHECK constraint is exercised at deploy time by the migration
run itself; no `loseit-db`-level integration test is added. If we
later wire up CI Postgres, the case to add is `pg_user_repo_rejects_
invalid_weight_unit_with_check_violation`.

---

## 8. Sequenced task list

Eight tasks. Each is 1–3 files and well under 300 LOC. Dependencies
mean "must merge before the next can compile"; everything is on the
`be-user-units` branch.

1. **Migration** — Add `server/migrations/0006_user_units.sql` exactly
   per §2. No Rust changes in this task. (1 file, ~15 LOC.) Verify with
   `sqlx migrate run --dry-run` if available; otherwise eyeball + leave
   for the Pg integration step.
2. **Domain enums** — Add `WeightUnit` + `HeightUnit` to
   `server/crates/loseit-core/src/domain/user.rs` per §3.1; add fields
   to `User` and `ProfilePatch`; re-export from `domain/mod.rs`.
   `cargo check -p loseit-core` must pass. Depends on #1 (logically,
   not for compile). (2 files, ~80 LOC.)
3. **In-memory fake** — Update `loseit-testing/src/users.rs` per §3.3:
   default the new fields on `create`, COALESCE-equivalent on
   `update_profile`. Depends on #2. (1 file, ~10 LOC.)
4. **Pg repo** — Update `loseit-db/src/user_repo.rs` per §3.2: `UserRow`
   fields, `From<UserRow>` mapping, `SELECT_USER_COLUMNS`, `update_
   profile` SQL + bindings. Depends on #2. (1 file, ~25 LOC.) After
   this lands the workspace compiles end-to-end.
5. **Handler + body type** — Update `loseit-api/src/routes/profile.rs`
   per §4: `UserResponse` fields, `From<User>` mapping,
   `ProfilePatchBody` fields, `into_domain` validation. Depends on
   #2/#3/#4. (1 file, ~40 LOC.)
6. **OpenAPI delta** — Apply §5 verbatim to
   `server/specs/openapi.yaml`. Depends on #5 (the wire is now real).
   (1 file, ~12 LOC.)
7. **Core service + in-memory tests** — Add cases from §7.1 + §7.2 to
   `loseit-core/tests/services.rs` and `loseit-testing/tests/in_memory_
   repos.rs`. Depends on #3/#5. (2 files, ~80 LOC.) Run `cargo test -p
   loseit-core -p loseit-testing`.
8. **HTTP tests** — Add cases from §7.3 to
   `loseit-api/tests/http_profile.rs`. Depends on #5. (1 file, ~150
   LOC.) Run `cargo test -p loseit-api --test http_profile`.

Final verification: `cargo check --manifest-path
/workplace/fulfilled/server/Cargo.toml --workspace` and `cargo test
--manifest-path /workplace/fulfilled/server/Cargo.toml -p loseit-core
-p loseit-testing` from the task harness.

---

## 9. Risks / open questions

- **None blocking.** The unknown-keys question (§6) was the only carry-
  over open item from the ledger and is resolved by inspection.
- **CHECK enum drift.** If we ever widen `WeightUnit`/`HeightUnit` (e.g.
  add `'g'` for grams or `'in'` standalone), the migration + Rust enum
  + OpenAPI must move together. The named constraints in §2 make the
  migration side a clean DROP+ADD; this is documented in the migration
  header comment.
- **Coolify migration run.** Because `0001`–`0005` are already applied
  to the Coolify Postgres, the deploy that ships this branch will run
  `0006` against a live DB. `ADD COLUMN … NOT NULL DEFAULT` on `users`
  is fast (Postgres rewrites the default into the existing rows in a
  single pass; the table is small — beta-scale). Acceptable; no
  separate ops ask.
