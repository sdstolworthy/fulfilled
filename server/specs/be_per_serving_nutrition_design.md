# BE-Ask10 — Per-serving nutrition + unit families + flatten migrations + USDA/OFF ingest — Architect Design

Branch: `be-per-serving-nutrition`. Addresses `backend_tasks.md` Ask 10 (also persisted at
`ask_10_per_serving_nutrition.md`).

---

## 1. Overview

Today the LoseIt server anchors every food's nutrition to per-100g columns on `foods` and
forces every serving to be a mass-only `grams: NUMERIC` field on `servings`. The user
directive of 2026-05-17 inverts the model: nutrition moves to the serving row and the
serving carries a structured `{amount, unit}` shape where `unit` belongs to one of three
families (`Mass`, `Volume`, `Count`). Within-family conversions live as a constant table
in `loseit-core`; cross-family conversions never happen — a "1 cup" serving cannot be
re-entered as grams unless the user adds a separate gram serving themselves. The user has
explicitly OK'd dropping all existing data, flattening migrations 0001..0009 into one new
`0001_initial.sql`, and rewriting the OFF + USDA ingest pipeline against the new schema
rather than the schema bending to the source data.

This reshape is sized as multi-week. The scope is: three tables redrawn
(`foods`, `servings`, `food_log_entries`), every other table preserved verbatim, the Rust
domain + repo + service + handler layers rewritten across foods/servings/log, the
OpenAPI spec swapped, the OFF + USDA ingest normalizers replaced, and ~245 workspace tests
ported. This document is the architect's resolution of the design — eight architect
decisions are locked below — and the TPM-ready sequenced task list at §9 carves it into
~16 engineer-sized tasks. T01 (migration) gates every subsequent task; the ingest
rewrite is the trailing three tasks and runs in parallel with the API hardening.

**Explicit non-goals (re-affirmed from the ask):** no refresh tokens, no idempotency keys,
no mobile OIDC, no density-based cross-family conversion ("display cups as grams"),
no multi-unit serving display (that's an FE render-time concern over the in-code ratio
table). The reshape is scoped to `foods` + `servings` + `food_log_entries` and the
ingest pipeline — every other table from the current 0001..0009 chain
(`users`, `users_local_auth`, `local_auth_tokens`, `oidc_handoff_codes`,
`food_import_batches`, `weights`, `goals`) is preserved verbatim by the new
`0001_initial.sql`.

---

## 2. Architect decisions (resolved)

This section locks the eight delegated decisions up front so the rest of the doc can
build on them. Each is paired with a one-line rationale; mechanics live in the relevant
section below.

**D1 — Quick-add sentinel: option (ii).** Quick-add log entries reference the per-user
sentinel food with `{amount: 1, unit: 'serving', kcal: <user-entered>}`. No new `Energy`
unit family. Rationale: principle of least mechanism — the existing `Count` family's
`'serving'` unit fits exactly, and adding a 13th unit that exists only for the sentinel
inflates the conversion table, the CHECK constraint, and the FE's unit-picker for one
edge case. See §4.3 (sentinel provisioning) and §5.2 (quick-add service flow).

**D2 — Within-family conversion ratios: confirmed standard SI/US-customary, stored
in `loseit-core::domain::unit` as a const table.** Mass canonical = `g`; Volume canonical
= `ml`; Count canonical = each unit is its own canonical (no auto-conversion between
`serving` and `piece`). Full ratio table at §3.2.

**D3 — Numeric type for conversions: `Decimal` throughout, with the ratio table stored
as `Decimal` literals.** Rationale: every other nutrient value in this codebase is
`rust_decimal::Decimal`; introducing `f64` for the conversion path would force a
Decimal→f64→Decimal round-trip on every log-entry write, drift the snapshot off the
`NUMERIC(8,2)` column by 1 ULP, and break the existing byte-for-byte
"compute_snapshot matches Postgres output" invariant
(`service/log.rs:71-98`). `cup = 236.5882365` and `fl_oz = 29.5735295625` are exactly
representable as `Decimal`. See §3.2.

**D4 — Migration strategy: flatten 0001..0009 into a single new `0001_initial.sql`.**
Delete the old nine files. Rationale: user OK'd; no production data; no incremental
rollout. **Operator action at deploy time is required** to reset sqlx's
`_sqlx_migrations` tracking table — see §10 R1 for the runbook.

**D5 — `LogEntryCreate` cross-family validation: reject 400 with
`code: "unit_family_mismatch"`.** Within-family entries are allowed and stored verbatim:
`entered_amount` + `entered_unit` preserve the user's typed values, `quantity` is the
multiplier expressed in the serving's unit. See §5.1 for the conversion path.

**D6 — `food_log_entries.grams_total` removal: complete.** The column is dropped from
the schema and from `FoodLogEntry`, `PersistedLogEntry`, `RecomputedSnapshot`, the
wire DTO, the OpenAPI spec, and every test fixture. Cross-codebase read sites are
enumerated in §6.1 — there are none outside the log paths (verified via grep), so the
removal is mechanical.

**D7 — Ingest pipeline strategy: greenfield rewrite of the per-100g normalizer into
the per-serving model.** Current pipeline (`loseit-ingest` + `service::ingest`) is
not connected to live Coolify data yet — there are no production foods to preserve
— so the rewrite is greenfield. OFF + USDA normalizers emit one or more
`{amount, unit, per-serving nutrition}` rows per food directly; no per-100g intermediate
storage. See §7.

**D8 — Test budget: ≥ 245 workspace tests post-reshape.** The reshape rewrites
~all foods/servings/log tests. New tests are listed by layer in §8. Coverage must not
regress.

---

## 3. Schema migration — `migrations/0001_initial.sql`

### 3.1 Strategy

Delete `migrations/0001_initial.sql` through `0009_oidc_handoff_codes.sql` and create
a single new `0001_initial.sql`. The new file is the union of every still-needed table
from the old chain, with `foods` / `servings` / `food_log_entries` redrawn per the ask.
sqlx tracks applied migrations in `_sqlx_migrations`; resetting this is operator
action at deploy time — see §10 R1.

The full SQL block follows. Tables and indexes preserve naming, defaults, and CHECK
domains from their last-applied form in the existing chain (e.g. `foods.kind` from
0008, `users.weight_unit`/`height_unit` from 0006, `users_local_auth` from 0007,
`oidc_handoff_codes` from 0009).

### 3.2 New `0001_initial.sql` (canonical SQL)

```sql
-- LoseIt re-implementation: initial schema (Ask 10 reshape, 2026-05-17)
-- Target: PostgreSQL 14+
--
-- This single migration replaces the old 0001..0009 chain. Tables touched by
-- the Ask 10 reshape: foods (drops *_100g), servings ({amount, unit} +
-- per-serving nutrition), food_log_entries (drops grams_total, adds
-- entered_amount + entered_unit). Every other table preserves its last-applied
-- shape from the old chain verbatim.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------------
-- users (preserved from 0001 + 0006)
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    issuer          TEXT NOT NULL,
    external_id     TEXT NOT NULL,
    email           TEXT,
    display_name    TEXT,
    sex             TEXT CHECK (sex IN ('male', 'female', 'other')),
    birth_date      DATE,
    height_cm       NUMERIC(5,2) CHECK (height_cm IS NULL OR (height_cm > 0 AND height_cm < 300)),
    activity_level  TEXT CHECK (activity_level IN
                        ('sedentary', 'light', 'moderate', 'active', 'very_active')),
    weight_unit     TEXT NOT NULL DEFAULT 'kg'
                       CHECK (weight_unit IN ('kg', 'lb', 'st')),
    height_unit     TEXT NOT NULL DEFAULT 'cm'
                       CHECK (height_unit IN ('cm', 'ft_in')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (issuer, external_id)
);

-- ---------------------------------------------------------------------------
-- users_local_auth + local_auth_tokens (preserved from 0007)
-- ---------------------------------------------------------------------------
CREATE TABLE users_local_auth (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    username        TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT users_local_auth_username_lower_check
        CHECK (username = lower(username))
);
CREATE UNIQUE INDEX users_local_auth_username_unique
    ON users_local_auth(username);

CREATE TABLE local_auth_tokens (
    token_hash      TEXT PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL
);
CREATE INDEX local_auth_tokens_user_idx ON local_auth_tokens(user_id);
CREATE INDEX local_auth_tokens_expires_idx ON local_auth_tokens(expires_at);

-- ---------------------------------------------------------------------------
-- oidc_handoff_codes (preserved from 0009)
-- ---------------------------------------------------------------------------
CREATE TABLE oidc_handoff_codes (
    code_hash         TEXT PRIMARY KEY,
    user_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    raw_token         TEXT NOT NULL,
    token_expires_at  TIMESTAMPTZ NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX oidc_handoff_codes_expires_idx ON oidc_handoff_codes(expires_at);

-- ---------------------------------------------------------------------------
-- food_import_batches (preserved from 0001)
-- ---------------------------------------------------------------------------
CREATE TABLE food_import_batches (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at        TIMESTAMPTZ,
    source_url          TEXT NOT NULL,
    source_etag         TEXT,
    records_seen        BIGINT NOT NULL DEFAULT 0,
    records_upserted    BIGINT NOT NULL DEFAULT 0,
    records_skipped     BIGINT NOT NULL DEFAULT 0,
    status              TEXT NOT NULL CHECK (status IN ('running', 'completed', 'failed')),
    error               TEXT
);

-- ---------------------------------------------------------------------------
-- foods (reshaped — drops all *_100g columns; keeps identity + metadata only)
-- ---------------------------------------------------------------------------
CREATE TABLE foods (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    source                  TEXT NOT NULL CHECK (source IN ('off', 'user', 'usda')),
    kind                    TEXT NOT NULL DEFAULT 'normal'
                                CHECK (kind IN ('normal', 'quick_add')),
    owner_user_id           UUID REFERENCES users(id) ON DELETE CASCADE,
    barcode                 TEXT,
    fdc_id                  BIGINT,
    data_type               TEXT CHECK (
        data_type IS NULL
        OR data_type IN ('foundation_food', 'sr_legacy_food',
                         'survey_fndds_food', 'branded_food')
    ),

    name                    TEXT NOT NULL,
    brands                  TEXT,
    categories_tags         TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],

    nutriscore_grade        TEXT CHECK (nutriscore_grade IN ('a','b','c','d','e')),
    quality_score           SMALLINT NOT NULL DEFAULT 0
                                CHECK (quality_score BETWEEN 0 AND 100),
    extra_nutrients         JSONB,
    last_import_batch_id    UUID REFERENCES food_import_batches(id) ON DELETE SET NULL,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Per-source identity invariant (carried forward from 0003).
    CONSTRAINT foods_source_identity_check CHECK (
        (source = 'off'  AND barcode IS NOT NULL AND owner_user_id IS NULL  AND fdc_id IS NULL)
     OR (source = 'user' AND owner_user_id IS NOT NULL                     AND fdc_id IS NULL)
     OR (source = 'usda' AND fdc_id IS NOT NULL AND owner_user_id IS NULL)
    ),
    -- USDA rows must declare a data_type (from 0004).
    CONSTRAINT foods_data_type_source_check CHECK (
        source <> 'usda' OR data_type IS NOT NULL
    )
);

CREATE UNIQUE INDEX foods_barcode_unique ON foods(barcode) WHERE barcode IS NOT NULL;
CREATE UNIQUE INDEX foods_fdc_id_unique  ON foods(fdc_id)  WHERE fdc_id IS NOT NULL;
CREATE INDEX foods_name_trgm_idx     ON foods USING gin (name gin_trgm_ops);
CREATE INDEX foods_brands_trgm_idx   ON foods USING gin (coalesce(brands, '') gin_trgm_ops);
CREATE INDEX foods_fts_idx           ON foods USING gin (
    to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(brands, ''))
);
CREATE INDEX foods_owner_idx         ON foods(owner_user_id) WHERE owner_user_id IS NOT NULL;

-- Per-user quick-add sentinel singleton (from 0005). The kind='quick_add' guard
-- replaces the old name='__quick_add__' check now that kind is the discriminator.
CREATE UNIQUE INDEX foods_quick_add_singleton
    ON foods(owner_user_id) WHERE source = 'user' AND kind = 'quick_add';

-- ---------------------------------------------------------------------------
-- servings (RESHAPED — {amount, unit} + per-serving nutrition)
-- ---------------------------------------------------------------------------
CREATE TABLE servings (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    food_id         UUID NOT NULL REFERENCES foods(id) ON DELETE CASCADE,

    label           TEXT,                  -- nullable; FE/user-supplied descriptor

    amount          NUMERIC(10,3) NOT NULL CHECK (amount > 0),
    unit            TEXT NOT NULL CHECK (unit IN (
                        'g', 'kg', 'oz', 'lb',
                        'ml', 'l', 'cup', 'fl_oz', 'tbsp', 'tsp',
                        'serving', 'piece'
                    )),

    -- Per-serving nutrition. Only kcal is required; the FE renders missing
    -- macros as "—" rather than forcing a zero.
    kcal            NUMERIC(8,2) NOT NULL CHECK (kcal >= 0),
    protein_g       NUMERIC(8,2)         CHECK (protein_g IS NULL OR protein_g >= 0),
    carbs_g         NUMERIC(8,2)         CHECK (carbs_g   IS NULL OR carbs_g   >= 0),
    fat_g           NUMERIC(8,2)         CHECK (fat_g     IS NULL OR fat_g     >= 0),
    fiber_g         NUMERIC(8,2)         CHECK (fiber_g   IS NULL OR fiber_g   >= 0),
    sugar_g         NUMERIC(8,2)         CHECK (sugar_g   IS NULL OR sugar_g   >= 0),
    sodium_mg       NUMERIC(8,2)         CHECK (sodium_mg IS NULL OR sodium_mg >= 0),
    saturated_fat_g NUMERIC(8,2)         CHECK (saturated_fat_g IS NULL OR saturated_fat_g >= 0),

    is_default      BOOLEAN NOT NULL DEFAULT false,
    source          TEXT    NOT NULL CHECK (source IN ('off','usda','user','system')),
    sort_order      INT     NOT NULL DEFAULT 0,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX servings_food_idx ON servings(food_id);
CREATE UNIQUE INDEX servings_one_default_per_food
    ON servings(food_id) WHERE is_default;

-- ---------------------------------------------------------------------------
-- weights (preserved from 0001)
-- ---------------------------------------------------------------------------
CREATE TABLE weights (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recorded_on         DATE NOT NULL,
    recorded_at_local   TIME,
    weight_kg           NUMERIC(6,2) NOT NULL CHECK (weight_kg > 0 AND weight_kg < 1000),
    note                TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX weights_user_date_idx ON weights(user_id, recorded_on DESC);

-- ---------------------------------------------------------------------------
-- goals (preserved from 0001)
-- ---------------------------------------------------------------------------
CREATE TABLE goals (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    starts_on               DATE NOT NULL,
    ends_on                 DATE,
    CHECK (ends_on IS NULL OR ends_on >= starts_on),
    start_weight_kg         NUMERIC(6,2) CHECK (start_weight_kg IS NULL OR start_weight_kg > 0),
    target_weight_kg        NUMERIC(6,2) CHECK (target_weight_kg IS NULL OR target_weight_kg > 0),
    weekly_rate_kg          NUMERIC(4,2),
    daily_calorie_target    INT CHECK (daily_calorie_target IS NULL OR daily_calorie_target > 0),
    protein_g_target        NUMERIC(6,2) CHECK (protein_g_target IS NULL OR protein_g_target >= 0),
    carbs_g_target          NUMERIC(6,2) CHECK (carbs_g_target IS NULL OR carbs_g_target >= 0),
    fat_g_target            NUMERIC(6,2) CHECK (fat_g_target IS NULL OR fat_g_target >= 0),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX goals_user_window_idx ON goals(user_id, starts_on DESC);

-- ---------------------------------------------------------------------------
-- food_log_entries (RESHAPED — drops grams_total; adds entered_amount +
--                   entered_unit; snapshot semantics = quantity × serving.<n>)
-- ---------------------------------------------------------------------------
CREATE TABLE food_log_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    food_id         UUID NOT NULL REFERENCES foods(id) ON DELETE RESTRICT,
    serving_id      UUID REFERENCES servings(id) ON DELETE SET NULL,

    consumed_on     DATE NOT NULL,
    meal            TEXT NOT NULL CHECK (meal IN ('breakfast', 'lunch', 'dinner', 'snack')),

    -- Multiplier expressed in the serving's unit (e.g. 0.5 means "half a serving
    -- of size {amount, unit}"). NOT a grams scale anymore.
    quantity        NUMERIC(8,3) NOT NULL CHECK (quantity > 0),

    -- Denormalized "what the user actually typed at entry time." Survives
    -- serving edits/deletes so the edit-sheet can reconstruct the input.
    entered_amount  NUMERIC(10,3) NOT NULL CHECK (entered_amount > 0),
    entered_unit    TEXT NOT NULL CHECK (entered_unit IN (
                        'g', 'kg', 'oz', 'lb',
                        'ml', 'l', 'cup', 'fl_oz', 'tbsp', 'tsp',
                        'serving', 'piece'
                    )),

    -- Snapshot of nutrition at write time. Computed as quantity * serving.<n>;
    -- no gram-anchor math, no per-100g intermediate.
    calories_kcal   NUMERIC(8,2) NOT NULL,
    protein_g       NUMERIC(8,2),
    carbs_g         NUMERIC(8,2),
    fat_g           NUMERIC(8,2),
    fiber_g         NUMERIC(8,2),
    sugar_g         NUMERIC(8,2),
    sodium_mg       NUMERIC(8,2),
    saturated_fat_g NUMERIC(8,2),

    note            TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX log_user_date_idx       ON food_log_entries(user_id, consumed_on);
CREATE INDEX log_user_date_meal_idx  ON food_log_entries(user_id, consumed_on, meal);
CREATE INDEX log_food_idx            ON food_log_entries(food_id);

-- ---------------------------------------------------------------------------
-- updated_at trigger function + triggers (preserved from 0001/0007)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER users_local_auth_set_updated_at
    BEFORE UPDATE ON users_local_auth FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER foods_set_updated_at
    BEFORE UPDATE ON foods FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER servings_set_updated_at
    BEFORE UPDATE ON servings FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER goals_set_updated_at
    BEFORE UPDATE ON goals FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER food_log_entries_set_updated_at
    BEFORE UPDATE ON food_log_entries FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

### 3.3 Notes on the rewrite

- The `quick_add_singleton` partial index is re-keyed on `kind = 'quick_add'` instead of
  `name = '__quick_add__'`. The sentinel-name convention from 0005 is preserved in the
  Rust code (`loseit-core::repo::food::QUICK_ADD_SENTINEL_NAME`) but the DB no longer
  treats it as the discriminator — `kind` does that since 0008.
- The `data_type` source-check from 0004 is recreated `VALID` (not `NOT VALID`) — there
  are no pre-existing USDA rows to grandfather.
- The old `0001` shipped `servings.label TEXT NOT NULL`; the new schema relaxes this to
  nullable per the ask (the FE owns the human-readable descriptor; the
  `{amount, unit}` pair is the structured truth). Existing callers that always pass a
  label continue to work.

---

## 4. Domain types — `loseit-core::domain::*`

### 4.1 New `domain/unit.rs`

```rust
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Unit {
    // Mass
    Gram, Kilogram, Ounce, Pound,
    // Volume
    Milliliter, Liter, Cup, FluidOunce, Tablespoon, Teaspoon,
    // Count
    Serving, Piece,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnitFamily { Mass, Volume, Count }

impl Unit {
    pub fn as_str(self) -> &'static str { /* "g", "kg", "oz", … */ }
    pub fn parse(s: &str) -> Option<Self>     { /* mirror of as_str */ }

    pub fn family(self) -> UnitFamily {
        match self {
            Self::Gram | Self::Kilogram | Self::Ounce | Self::Pound => UnitFamily::Mass,
            Self::Milliliter | Self::Liter | Self::Cup | Self::FluidOunce
                | Self::Tablespoon | Self::Teaspoon => UnitFamily::Volume,
            Self::Serving | Self::Piece => UnitFamily::Count,
        }
    }

    /// Ratio to the family canonical (g for Mass, ml for Volume, identity for Count).
    /// See §3.2 for the locked values. Decimal storage; literals are exact.
    pub fn ratio_to_canonical(self) -> Decimal {
        match self {
            // Mass — canonical g
            Self::Gram      => dec!(1),
            Self::Kilogram  => dec!(1000),
            Self::Ounce     => dec!(28.349523125),
            Self::Pound     => dec!(453.59237),
            // Volume — canonical ml
            Self::Milliliter => dec!(1),
            Self::Liter      => dec!(1000),
            Self::Cup        => dec!(236.5882365),
            Self::FluidOunce => dec!(29.5735295625),
            Self::Tablespoon => dec!(14.78676478125),
            Self::Teaspoon   => dec!(4.92892159375),
            // Count — each is its own canonical (no auto-conversion)
            Self::Serving | Self::Piece => dec!(1),
        }
    }
}
```

The `Count` family stores `ratio_to_canonical = 1` for both `Serving` and `Piece` but
the service rejects cross-unit conversion within Count: the only same-family pair is
itself (i.e. `serving → serving` and `piece → piece`). See §5.1 conversion helper.

### 4.2 Reshaped `domain/food.rs`

```rust
pub struct Food {
    pub id: Uuid,
    pub source: FoodSource,
    pub kind: FoodKind,
    pub owner_user_id: Option<Uuid>,
    pub barcode: Option<String>,
    pub fdc_id: Option<i64>,
    pub data_type: Option<String>,
    pub name: String,
    pub brands: Option<String>,
    pub categories_tags: Vec<String>,
    pub nutriscore_grade: Option<NutriscoreGrade>,
    pub quality_score: i16,
    pub extra_nutrients: Option<serde_json::Value>,
    pub last_import_batch_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub struct FoodDraft {
    pub name: String,
    pub brands: Option<String>,
    pub barcode: Option<String>,
    pub categories_tags: Vec<String>,
    pub nutriscore_grade: Option<NutriscoreGrade>,
    pub servings: Vec<ServingDraft>,   // at least one required (service-validated)
}

pub struct FoodPatch { /* same minus nutrition; servings still full-list replace */ }
```

`NutritionPer100g` is **deleted** from the crate. `Food.nutrition` is gone.

`FoodSearchHit` and `ServingPreview` (`food.rs:160-175`) lose `calories_per_serving` /
`grams` and gain `kcal: Decimal` + `amount: Decimal` + `unit: Unit`. The
`calories_per_serving` field was a derived view of per-100g × grams; now it's just
`serving.kcal` and no derivation is needed.

### 4.3 Reshaped `domain/serving.rs`

```rust
pub struct Serving {
    pub id: Uuid,
    pub food_id: Uuid,
    pub label: Option<String>,        // now nullable
    pub amount: Decimal,
    pub unit: Unit,
    pub kcal: Decimal,                // required
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
    pub sugar_g: Option<Decimal>,
    pub sodium_mg: Option<Decimal>,   // mg, not g — schema column is sodium_mg
    pub saturated_fat_g: Option<Decimal>,
    pub is_default: bool,
    pub source: ServingSource,
    pub sort_order: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

pub struct ServingDraft {
    pub label: Option<String>,
    pub amount: Decimal,
    pub unit: Unit,
    pub kcal: Decimal,
    pub protein_g: Option<Decimal>,   // … (same as Serving minus id/timestamps)
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
    pub sugar_g: Option<Decimal>,
    pub sodium_mg: Option<Decimal>,
    pub saturated_fat_g: Option<Decimal>,
    pub is_default: bool,
    pub source: ServingSource,
    pub sort_order: i32,
}

pub struct ServingPatch {
    pub label: Option<Option<String>>,  // double-Option = nullable patch
    pub amount: Option<Decimal>,
    pub unit: Option<Unit>,
    pub kcal: Option<Decimal>,
    pub protein_g: Option<Option<Decimal>>,  // double-Option per nutrient
    /* … same for carbs/fat/fiber/sugar/sodium/saturated_fat */
    pub sort_order: Option<i32>,
}
```

Note `sodium_mg` lives on the serving in **milligrams** now, matching the schema column
and matching the snapshot column. The previous "g on serving / mg on snapshot" mismatch
that `service/log.rs:90-95` papered over is gone — no more g→mg conversion in
`compute_snapshot`. The OFF + USDA ingest must produce mg-native values (see §7).

### 4.4 Reshaped `domain/log_entry.rs`

```rust
pub struct NutritionSnapshot {
    pub calories_kcal: Decimal,
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
    pub sugar_g: Option<Decimal>,
    pub sodium_mg: Option<Decimal>,
    pub saturated_fat_g: Option<Decimal>,
}  // unchanged

pub struct FoodLogEntry {
    pub id: Uuid,
    pub user_id: Uuid,
    pub food_id: Uuid,
    pub food_name: String,
    pub serving_id: Option<Uuid>,
    pub serving_name: Option<String>,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub quantity: Decimal,
    pub entered_amount: Decimal,       // NEW
    pub entered_unit: Unit,            // NEW
    pub snapshot: NutritionSnapshot,
    pub note: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}  // grams_total removed

pub struct LogDraft {
    pub food_id: Uuid,
    pub serving_id: Uuid,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub entered_amount: Decimal,       // NEW — required from the wire
    pub entered_unit: Unit,            // NEW — required from the wire
    pub note: Option<String>,
}  // quantity removed from draft; service derives it from entered_{amount,unit} + serving

pub struct LogPatch {
    pub serving_id: Option<Uuid>,
    pub consumed_on: Option<NaiveDate>,
    pub meal: Option<Meal>,
    pub entered_amount: Option<Decimal>,
    pub entered_unit: Option<Unit>,
    pub note: Option<Option<String>>,
}

pub struct PersistedLogEntry {
    pub food_id: Uuid,
    pub serving_id: Option<Uuid>,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub quantity: Decimal,
    pub entered_amount: Decimal,
    pub entered_unit: Unit,
    pub snapshot: NutritionSnapshot,
    pub note: Option<String>,
}

pub struct RecomputedSnapshot {
    pub quantity: Decimal,
    pub entered_amount: Decimal,
    pub entered_unit: Unit,
    pub snapshot: NutritionSnapshot,
}
```

The `LogDraft` wire shape uses `entered_amount` + `entered_unit` as the source of truth.
`quantity` is a **derived** field — see §5.1 — so it's not in the draft, but it
still lives on the persisted row and on the wire response so clients have direct access
to the multiplier (the FE uses it for "+ / −" steppers in the log-edit sheet).

---

## 5. Service layer — `loseit-core::service::{food, log}`

### 5.1 `LogService::create` — conversion + validation flow

The single hot path. Pseudocode (Rust-shaped, prose-precise):

```text
1. Look up the food (visibility check) and the serving (must belong to that food).
   Reject with NotFound if either fails.
2. Let s = serving;  e_amt = draft.entered_amount;  e_unit = draft.entered_unit.
3. Cross-family guard:
        if e_unit.family() != s.unit.family() →
            Err(Validation("unit_family_mismatch"))
4. Within-family conversion to derive the quantity multiplier in serving's unit:
        Mass / Volume:  q = (e_amt * e_unit.ratio_to_canonical())
                          / (s.amount * s.unit.ratio_to_canonical())
        Count:          if e_unit == s.unit →
                            q = e_amt / s.amount
                        else  // both Count but different units (serving vs piece)
                            Err(Validation("unit_family_mismatch"))
                            // intentional: Count members are siblings, not convertible
5. Quantity guard: q > 0; q < 10_000 (sanity cap). Round q to NUMERIC(8,3).
6. Snapshot = compute_snapshot(serving, q):
        calories_kcal = round_8_2(q * s.kcal)
        protein_g     = s.protein_g.map(|v| round_8_2(q * v))   // None passthrough
        … same for carbs, fat, fiber, sugar, sodium_mg, saturated_fat_g
7. Persist PersistedLogEntry { quantity: q, entered_amount: e_amt,
       entered_unit: e_unit, snapshot, … }.
```

The conversion in step 4 is **lossless** for Mass and Volume — both ratios are exact
Decimals. The `Count` branch enforces the architect's "no auto-conversion between
serving and piece" rule from D2.

The new `compute_snapshot` body replaces today's `service/log.rs:71-98`. It is shorter:
the per-100g → grams scaling is gone, the sodium g→mg dance is gone, the only math is
`q * <field>`.

### 5.2 `LogService::quick_add` (D1 mechanics)

```text
1. Validate calories_kcal > 0 && < 9_999 (unchanged guard).
2. food, serving = foods.find_or_create_quick_add(user).
   The provisioned serving has {amount: 1, unit: Serving, kcal: 1.0,
   all-other-nutrients = NULL, source: System, is_default: true}.
3. quantity        = calories_kcal              // serving has 1 kcal/serving
   entered_amount  = calories_kcal              // user typed N kcal; we store N "serving"
   entered_unit    = Unit::Serving
   snapshot.calories_kcal = round_8_2(quantity * serving.kcal)
                          = calories_kcal       // protein/carbs/etc stay NULL
4. Persist PersistedLogEntry { … }.
```

The wire shape change for `POST /log/quick_add` is invisible — the FE still posts
`{calories_kcal, meal, consumed_on, note?}`. The new `entered_amount` /
`entered_unit` show up on the **returned** entry (`{entered_amount: <N>, entered_unit:
"serving"}`) but the request body is unchanged.

### 5.3 `LogService::update` and `copy_day`

`update`: if `entered_amount` or `entered_unit` changes (or `serving_id`), re-run the
conversion + snapshot pipeline from §5.1 and stamp the recomputed
`RecomputedSnapshot { quantity, entered_amount, entered_unit, snapshot }`. The
`grams_total` overflow guard at `service/log.rs:243` is replaced by a `quantity > 0 &&
quantity < 10_000` guard.

`copy_day`: re-snapshot each entry against the current food + serving, same as today.
The `quantity` is preserved across the copy; the new `entered_amount` / `entered_unit`
are preserved verbatim. Cross-family rejection cannot fire on copy (the entry was
already accepted at create time) — the conversion logic is unchanged.

### 5.4 `FoodService::create_custom` validation flow

```text
1. Validate draft.name is non-empty, not the quick-add sentinel.
2. Validate draft.servings.len() >= 1.
3. For each serving draft:
     - amount > 0
     - kcal >= 0; protein_g/carbs_g/fat_g/etc all >= 0 when present
     - unit parses
4. Validate at most one serving has is_default = true. If none, mark the first.
5. INSERT food, then INSERT each serving in a transaction (repo trait grows
   `create_custom_with_servings`).
```

The synthesized-default-`100 g`-serving that today's `service/food.rs:175-184` injects
is **gone**. The user supplies servings explicitly now — there's no default mass-anchor
serving to fall back to.

### 5.5 `FoodService::update_custom` — patch shape

`FoodPatch.servings: Option<Vec<ServingDraft>>` performs full-list replace when present
(matches what the ask calls out). The service:
1. Validates the new list (same rules as create_custom).
2. Wipes existing servings (`DELETE FROM servings WHERE food_id = $1`).
3. Inserts the new list.

Both DELETEs and INSERTs go in one transaction so the food never has zero servings mid-
update. The FK from `food_log_entries.serving_id` is `ON DELETE SET NULL`, so this is
safe — existing log entries lose their serving pointer but keep the denormalized
`serving_name` (Ask 9 footing) and the frozen snapshot.

---

## 6. Repos + in-memory fake

### 6.1 `grams_total` removal — full audit

Grepping the codebase, every read of `grams_total` is confined to log paths:

- `loseit-core/src/domain/log_entry.rs:35,74,95` — three fields on three structs.
- `loseit-core/src/service/log.rs:71-98,120-130,170-180,243-249,348-358,617-705` — every
  occurrence is a snapshot-compute or test fixture.
- `loseit-db/src/log_repo.rs:40,71,91-92,109,122,182,428,445,472,500,565,593` — SQL
  columns, struct fields, UNNEST bindings.
- `loseit-testing/src/logs.rs:111,148` — fake-repo passthroughs.
- `loseit-api/src/routes/log.rs:146,173` — wire DTO field + mapping.
- `loseit-api/tests/http_log.rs` — 14 test sites (see grep at design-time).

**No reads outside these files exist.** `recent_food_ids` / `frequent_food_ids` /
`day_summary` / `count_in_range` / `any_entry_references_food` (`log_repo.rs:285-345`)
do not project `grams_total`. The removal is a clean delete across the seven
files above. There is no `entries_by_food_id_total_grams` or similar straggler — the
12-hour-ago commit referenced in the ask's decision E is not present in this tree.

### 6.2 Pg repos — key SQL strings

`PgFoodRepository` (`food_repo.rs`):
- `SELECT_FOOD_COLS` shrinks: drop `energy_kcal_100g, protein_100g, carbs_100g,
  fat_100g, fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g`.
- `create_custom` becomes parameterless on nutrition; the new
  `create_custom_with_servings(owner, draft, servings)` runs an INSERT + N serving
  INSERTs in a transaction.
- `upsert_off_batch` and `update_custom` lose every `*_100g` column and every
  corresponding bind.
- The trait `FoodRepository::find_or_create_quick_add` provisions
  `{amount: 1, unit: 'serving', kcal: 1}` instead of `{label: 'kcal', grams: 100}`.

`PgServingRepository` (`serving_repo.rs`):
- `SELECT_COLS` expands to include every per-serving nutrition column + `amount` +
  `unit`. `grams` is gone.
- `create` and `update` rewrite their column lists.
- `set_default` is unchanged (works against the partial unique index).

`PgLogRepository` (`log_repo.rs`):
- Drop `grams_total` from every column list. Add `entered_amount` + `entered_unit`.
- `create`, `update`, `create_many`'s UNNEST signature updates: drop one `numeric[]`,
  add one `numeric[]` (entered_amount) + one `text[]` (entered_unit).
- The denormalization JOIN from Ask 9 stays:
  ```sql
  SELECT_COLS = "le.id, le.user_id, le.food_id, le.serving_id, le.consumed_on, le.meal,
      le.quantity, le.entered_amount, le.entered_unit,
      le.calories_kcal, le.protein_g, le.carbs_g, le.fat_g,
      le.fiber_g, le.sugar_g, le.sodium_mg, le.saturated_fat_g, le.note,
      le.created_at, le.updated_at,
      COALESCE(f.name, '') AS food_name,
      s.label AS serving_name"
  ```

### 6.3 In-memory fakes (`loseit-testing/src/{foods,servings,logs}.rs`)

Mechanical mirror of the Pg side. Same drop-list + same add-list. The
`resolve_names` helper from Ask 9 stays put. The `set_food_repo_for_sentinel_filter`
test wiring also stays put.

---

## 7. Ingest pipeline — `loseit-ingest` + `loseit-core::service::ingest`

Greenfield rewrite (D7). The trait `FoodRecordSource` + the JSONL/Parquet sources stay;
the **normalizer** changes shape: `accept_and_normalize` now emits a `FoodDraft` plus a
`Vec<ServingDraft>` rather than a per-100g `FoodDraft` + an `OffServing` /
`SystemServing` pair.

### 7.1 OFF normalizer rules

For each `OffFoodRecord`:

1. Drop the row if `code.is_empty() || product_name.is_empty()`.
2. Parse `serving_size` (string like `"30 g"`, `"100 ml"`, `"1 cup (240 ml)"`) into
   `{amount, unit}`. Parser table:

   | Pattern (case-insensitive, trailing `\b`) | `Unit`        |
   |---|---|
   | `g`, `gr`, `gram`, `grams` | `Gram` |
   | `kg`, `kilogram`, `kilograms` | `Kilogram` |
   | `oz`, `ounce`, `ounces` (with no "fl") | `Ounce` |
   | `lb`, `lbs`, `pound`, `pounds` | `Pound` |
   | `ml`, `milliliter`, `millilitre`, `milliliters`, `millilitres` | `Milliliter` |
   | `l`, `liter`, `litre`, `liters`, `litres` | `Liter` |
   | `cup`, `cups` | `Cup` |
   | `fl oz`, `fl. oz`, `fluid ounce`, `fluid ounces` | `FluidOunce` |
   | `tbsp`, `tablespoon`, `tablespoons` | `Tablespoon` |
   | `tsp`, `teaspoon`, `teaspoons` | `Teaspoon` |
   | `piece`, `pieces`, `pcs` | `Piece` |
   | `serving`, `servings` | `Serving` |

   The `"1 cup (240 ml)"` case parses to `{amount: 1, unit: Cup}` — the parenthetical
   ml is informational, not authoritative, and the in-code conversion table will let
   the FE display both.
3. If `serving_size` parses → compute per-serving nutrition. For Mass units, scale
   per-100g × serving-grams-equivalent. For Volume units, **store only the OFF
   per-serving nutrition** when OFF provides one; if OFF gives only per-100g and the
   serving is volumetric, drop the row (no density assumption).
4. Always emit a companion `{amount: 100, unit: Gram}` serving when OFF provides any
   per-100g nutrition. This is the "by weight" entry point even when the labeled
   serving is volumetric. Marked `is_default = false`.
5. If `serving_size` parsed → that serving is `is_default = true`. The 100g companion
   is non-default.
6. If `serving_size` did **not** parse AND per-100g nutrition is present → emit only
   the `{100, g}` serving, `is_default = true`.
7. Drop the row entirely if per-100g nutrition AND serving-level nutrition are both
   unavailable.

Sodium conversion: OFF stores sodium in g/100g. The new schema stores sodium in mg on
servings, so the normalizer multiplies by 1000 when filling `serving.sodium_mg`. The
sanity threshold check (`SODIUM_GRAMS_SANITY_THRESHOLD = 50.0` at
`service/ingest.rs:57`) runs **before** the g→mg conversion (still in g/100g space).

### 7.2 USDA normalizer rules

For each USDA Foundation Food (or SR Legacy / FNDDS / Branded):

1. Iterate `foodPortions[]`. Each portion has `gramWeight` + `measureUnit.name`.
2. Map `measureUnit.name` to `Unit` (table mirrors OFF's, plus USDA's
   `"tablespoon"` / `"teaspoon"` / `"piece"` / etc.). Fallback if no match:
   emit a `{gramWeight, Gram}` serving.
3. Compute per-serving nutrition: `nutrient_per_100g * gramWeight / 100`.
4. Emit one serving row per portion. Sort by `sequenceNumber`; mark the lowest as
   `is_default`.
5. Drop the food entirely if `foodPortions[]` is empty AND `foodNutrients[]` does not
   include `energy-kcal`.

### 7.3 Shared invariant

Both pipelines respect the FK invariant: **every food has ≥ 1 serving**. A food with
zero parseable portions is dropped at normalize time (not stored with an empty
serving list, which the DB would accept but the FE can't render).

### 7.4 Trait + service plumbing

- `core::service::FoodRecordSource` is renamed `OffSource` (USDA gets its own
  `UsdaSource`). Both emit shape-specific records; the shared `IngestService` takes a
  generic trait param and exposes `run_off` / `run_usda`.
- `OffFoodUpsert` is **deleted**; replaced by `FoodDraftWithServings { draft:
  FoodDraft, quality_score: i16, servings: Vec<ServingDraft> }`.
- `FoodRepository::upsert_off_batch` becomes
  `upsert_external_food_batch` (source-agnostic) and takes the new
  `FoodDraftWithServings` shape. Per-food it runs an UPSERT on the food row, then
  REPLACES the servings list (atomically per food: `DELETE FROM servings WHERE
  food_id = $1; INSERT ... `). This is a tighter contract than today's add-only
  ingest — re-importing an OFF row with a different serving shape overwrites the old
  servings rather than leaving stale rows. Acceptable for an ingest pipeline; **not**
  used for `source = 'user'` foods (those go through the live API).
- `materialize_servings` at `service/ingest.rs:198-239` is **deleted** entirely — the
  new repo contract handles serving creation in one shot.

---

## 8. Test plan per layer

Workspace today: 245 passing tests (per Ask 8). Budget (D8): ≥ 245 post-reshape.
Net change is expected to be +30 to +50 tests; few existing tests survive verbatim.

**`loseit-core` (unit):**
- `unit.rs`: `family()` classification for every variant; `parse` / `as_str`
  round-trip; `ratio_to_canonical` exact-value assertions for all 12 units;
  cross-family pairs reject in the `LogService` conversion helper.
- `service::log` tests:
  - within-family Volume conversion: `4 fl_oz` against a `1 cup` serving → `quantity =
    0.5`, snapshot scales accordingly.
  - within-family Mass conversion: `200 g` against `1 lb` serving → `quantity ≈ 0.441`.
  - cross-family rejection: `g` against `cup` serving → `Validation`.
  - `Count` strict-unit: `piece` against `serving` serving → `Validation`.
  - `Count` exact: `2 servings` against `{amount: 1, unit: serving}` → `quantity = 2`.
  - quick-add path: returns `entered_amount = calories_kcal`, `entered_unit = serving`.
- `service::food` tests:
  - empty `servings` list rejected.
  - multiple `is_default = true` rejected.
  - `validate_nutrition` covers each per-serving column.

**`loseit-db` + `loseit-testing` (integration / in-memory):**
- Round-trip `Food` + serving list against the in-memory repo (no nutrition on food).
- Round-trip `FoodLogEntry` with `entered_amount` / `entered_unit` survives create +
  find_by_id + list.
- `update_custom` full-list serving replace preserves `food_id`.
- `delete_custom` is still RESTRICTed by the FK.

**`loseit-api` (HTTP):**
- `POST /foods` with `{name, servings: [{amount: 1, unit: 'cup', kcal: 200}]}` →
  201 with the serving echoed.
- `POST /foods` with empty servings → 400.
- `POST /log` referencing a volumetric serving with `entered_unit='fl_oz'` and
  `entered_amount='4'` against a `1 cup` serving → 201, `quantity ≈ 0.5`,
  `calories_kcal = 100` (if serving has 200 kcal).
- `POST /log` with `entered_unit='g'` against a volumetric serving → 400 with
  `code: "unit_family_mismatch"`.
- `GET /log?from=…&to=…` → results include `entered_amount` + `entered_unit`; **does
  NOT include `grams_total`**.
- `GET /foods/{id}` → no `nutrition_per_100g` key; `servings[0]` has `amount` + `unit`
  + `kcal`.
- `POST /log/quick_add` → response shows `entered_amount = <kcal>`, `entered_unit =
  "serving"`.

**`loseit-ingest`:**
- OFF normalizer fixtures: `"30 g"` → `Gram`; `"1 cup (240 ml)"` → `Cup` with
  amount=1; pure-volume serving with per-100g-only nutrition → row dropped;
  per-100g present → both `{amount, unit}` and `{100, g}` emitted.
- USDA fixtures: `foodPortions` with `measureUnit.name="tablespoon"` → `Tablespoon`
  serving; unmapped measureUnit → fallback `{gramWeight, Gram}`.
- Sanity: sodium > 50 g/100g still nulls only the field, not the row.

---

## 9. Sequenced task list

16 tasks. T01 (migration) is the gate; T02–T08 are sequential on the API path; T09–T13
are parallelizable; T14–T16 are the ingest rewrite and can run in parallel with the
later API tasks once T01 + T02 are merged.

**T01 — Migration: flatten 0001..0009 into new `0001_initial.sql`** *(gates everything)*
- Delete `server/migrations/0001..0009`.
- Create new `0001_initial.sql` per §3.2.
- Update `compose.coolify.yaml` deploy runbook with the `_sqlx_migrations` reset
  (§10 R1).
- No code changes; `cargo check --workspace` passes.

**T02 — Core domain: new `unit.rs` + reshape `food.rs`/`serving.rs`/`log_entry.rs`**
- Add `crates/loseit-core/src/domain/unit.rs` per §4.1.
- Reshape `Food`, `FoodDraft`, `FoodPatch`, `Serving`, `ServingDraft`,
  `ServingPatch`, `FoodLogEntry`, `LogDraft`, `LogPatch`,
  `PersistedLogEntry`, `RecomputedSnapshot` per §4.2–§4.4.
- Delete `NutritionPer100g`, `OffFoodUpsert`, `OffServing`, `SystemServing`.
- Workspace will fail to compile after this. Subsequent tasks fix it layer by layer.

**T03 — Repo trait: `FoodRepository` / `ServingRepository` / `LogRepository` signatures**
- `FoodRepository::create_custom` → `create_custom_with_servings(owner, draft,
  servings)`.
- `FoodRepository::update_custom_with_servings(owner, id, patch, Option<Vec<ServingDraft>>)`.
- `FoodRepository::upsert_off_batch` renamed → `upsert_external_food_batch` taking
  `FoodDraftWithServings`.
- `FoodRepository::find_or_create_quick_add` returns the new `Serving` shape.
- `ServingRepository::create` / `update` adapt to the new draft/patch.
- `LogRepository` signatures unchanged at the trait level; only the persisted shape
  changes.

**T04 — Pg repos: `PgFoodRepository` rewrite**
- New `SELECT_FOOD_COLS`, new INSERT/UPDATE column lists.
- `create_custom_with_servings`: transaction wrapping food INSERT + N serving INSERTs.
- `update_custom_with_servings`: optional full-list serving replace inside the txn.
- `find_or_create_quick_add`: provisions `{amount: 1, unit: 'serving', kcal: 1}` system
  serving.

**T05 — Pg repos: `PgServingRepository` rewrite**
- New `SELECT_COLS` adding `amount`, `unit`, `kcal`, `protein_g`, … `saturated_fat_g`.
- `create` / `update` rewrite.
- `set_default` unchanged.

**T06 — Pg repos: `PgLogRepository` rewrite**
- Drop `grams_total` from every column list; add `entered_amount` + `entered_unit`.
- `create` / `update` / `create_many` adapt; `create_many`'s UNNEST signature updates.
- `create_many_sql_has_no_inline_comments` regression test stays.

**T07 — In-memory fakes: `loseit-testing/src/{foods,servings,logs}.rs`**
- Mirror Pg. `entered_amount` / `entered_unit` round-trip. Quick-add provisioning
  matches new shape.

**T08 — Service layer: `FoodService` + `LogService` rewrite**
- `LogService::create` conversion + cross-family rejection per §5.1.
- `LogService::quick_add` per §5.2.
- `LogService::update` recompute pipeline.
- `FoodService::create_custom` no synthesized default serving; servings come from the
  draft.
- `FoodService::update_custom` full-list serving replace.

**T09 — HTTP handlers: `routes/foods.rs` DTOs + handlers**
- `CreateFoodBody.servings: Vec<ServingBody>` required, ≥1.
- `ServingBody` per §4.3.
- Drop `nutrition` from `CreateFoodBody` / `PatchFoodBody`.
- `FoodDetailResponse` carries no `nutrition`; servings include `amount` + `unit` +
  `kcal` + per-nutrient.
- `POST /foods/{food_id}/servings` body shape updates.

**T10 — HTTP handlers: `routes/log.rs` DTOs + handlers**
- `CreateLogBody`: drop `quantity`; add `entered_amount`, `entered_unit`.
- `PatchLogBody`: same.
- `LogEntryResponse`: drop `grams_total`; add `entered_amount`, `entered_unit`,
  `quantity` (still on the wire).
- 400 emits `code: "unit_family_mismatch"` for cross-family rejection (new
  `ApiError` variant or reuse the structured 400 envelope).

**T11 — OpenAPI: `server/specs/openapi.yaml` delta**
- Delete `NutritionPer100g` schema.
- New `Unit` enum schema (12 string values).
- `Serving`: drop `grams`, add `amount`/`unit`/`kcal`/`protein_g`/`carbs_g`/`fat_g`/
  `fiber_g`/`sugar_g`/`sodium_mg`/`saturated_fat_g`; `label` becomes nullable;
  required becomes `[id, amount, unit, kcal, is_default, source, sort_order]`.
- `ServingCreate` + `ServingPatch`: mirror.
- `FoodDetail`: drop `nutrition`; `servings` required and `minItems: 1`.
- `FoodCreate`: drop `nutrition`; add `servings: [ServingCreate]` required minItems 1.
- `FoodPatch`: drop `nutrition`; add optional `servings`.
- `LogEntry`: drop `grams_total`; add `entered_amount` (required), `entered_unit`
  (required → `Unit`).
- `LogCreate`: drop `quantity`; add `entered_amount` + `entered_unit` (both required).
- `LogPatch`: drop `quantity`; add optional `entered_amount` + `entered_unit`.
- `Errors`: document `unit_family_mismatch` code.

**T12 — HTTP tests: `loseit-api/tests/http_foods.rs` rewrite**
- Drop every `nutrition`-on-food test.
- Add `servings` round-trip tests; `[]` → 400.
- Add `kcal` is required + macros nullable tests.

**T13 — HTTP tests: `loseit-api/tests/http_log.rs` rewrite**
- Every `grams_total` assertion deleted.
- New `entered_amount` / `entered_unit` round-trip tests.
- New cross-family 400 test.
- New within-family Volume conversion test (4 fl_oz against 1 cup).
- Quick-add returns `entered_unit = "serving"`.

**T14 — Ingest core: new `OffSource` / `UsdaSource` traits + normalizers**
- `core/src/service/ingest.rs`: new `accept_and_normalize_off` emits
  `FoodDraftWithServings`.
- New `accept_and_normalize_usda` for USDA Foundation Foods.
- Parser table per §7.1 + §7.2.
- Unit tests on the normalizers with fixture rows.

**T15 — Ingest binary: `loseit-ingest::JsonlSource` + `ParquetSource` adapt to new
record shape**
- `OffRaw` keeps the per-100g + serving_size fields (it's still parsing OFF).
- `into_record` now also exposes the raw serving fields needed by the normalizer.
- `ParquetSource` updates to match.
- `loseit-ingest` binary's `--limit` smoke harness works end-to-end against the new
  Pg repo.

**T16 — Ingest tests + workspace test count gate**
- Fixture-based tests for OFF + USDA normalizers.
- Run `cargo test --workspace`; assert count ≥ 245.

---

## 10. Risks / open questions

**R1 — sqlx `_sqlx_migrations` reset required at deploy time.** Flattening the
migration history means existing dev / staging / Coolify databases will reject the new
`0001_initial.sql` as "already applied with a different checksum." Operator runbook for
the Coolify deploy:
```bash
# Option A — brand-new DB (recommended on Coolify since there's no data):
#   drop and recreate the database.
psql $DATABASE_URL -c "DROP DATABASE loseit; CREATE DATABASE loseit;"

# Option B — preserve the DB, clear sqlx's tracking:
psql $DATABASE_URL -c "DROP TABLE IF EXISTS _sqlx_migrations;"
# Then on next boot the server's `sqlx migrate run` reapplies 0001_initial.sql from scratch.
```
Document this in `COOLIFY.md` as part of T01.

**R2 — `compute_snapshot` rounding parity.** Today's snapshot computation rounds at
`NUMERIC(8,2)` (`to_numeric_8_2` at `service/log.rs:590-594`). The new code path
multiplies `q * s.<nutrient>` where `q` is a derived ratio with potentially long
fractional tails (e.g. 4 fl_oz / 1 cup → q=0.5 exactly, fine; but 200 g / 1 lb →
q=0.4409245243697551... — not exact at 3 dp). The persisted `quantity` column is
`NUMERIC(8,3)`, so the round-trip will be `round(q, 3)` before storage and
`round(q_stored * nutrient, 2)` for the snapshot. Engineer must add a test pinning
this: 200 g against 1 lb produces `quantity = 0.441`, snapshot uses the rounded q.

**R3 — `entered_unit` cross-family on PATCH after serving swap.** If a user PATCHes
`serving_id` from a Volume serving to a Mass serving without also patching
`entered_unit`, the previously-typed `entered_unit` may no longer be in the new
serving's family. T08's update path runs the cross-family validation on the effective
post-patch `(entered_unit, serving.unit)` pair, not the pre-patch one. Engineer must
add a regression test for this.

**R4 — `FoodPatch.servings` full-list replace is lossy.** Replacing the servings list
invalidates any log entry's `serving_id` (FK → SET NULL). Existing entries lose their
serving pointer but keep the denormalized `serving_name` (from Ask 9) and the frozen
snapshot. This is acceptable v1 behavior — the snapshot is the source of truth for
historical calorie math — but it is worth surfacing in the OpenAPI prose under
`PATCH /foods/{id}`. Document in T09.

**R5 — Ingest re-run replaces servings.** The new `upsert_external_food_batch` contract
(§7.4) atomically replaces an OFF/USDA food's servings on each re-import. If we
re-import OFF with a slightly different `serving_size` parse, every existing log entry
referencing the old serving is `SET NULL` on `serving_id`. Same R4 footing — the
snapshot survives, the pointer is lost. Document; do not block.

**R6 — `Decimal::dec!()` macro requires `rust_decimal_macros`.** The ratio table at
§4.1 uses `dec!(236.5882365)`. Confirm `rust_decimal_macros` is a workspace dep; if
not, T02 adds it.

**R7 — FE coordination (out of scope, but on the critical path).** This reshape
breaks every food/serving/log wire shape. FE's Ask 10 deliverables (lines 322-341 of
the source ask) cover the client-side mirror; expect ~3-5 days of FE rewrites once
T11 lands. The notify hook in the ask body (lines 343-355) governs the handoff.

**Open question I'd most like the user to confirm in the morning:** §5.4 deletes
`FoodService::create_custom`'s synthesized default `100 g` system serving. The FE's
custom-food flow today relies on always having at least one serving on a freshly
created food. The new contract requires the user to supply ≥ 1 serving in
`POST /foods`. If the FE wants to keep a "user creates the food, system pins a
default 100 g serving" affordance, we'd preserve the synthesizer; if the user wants
the user-typed servings to be the only authoritative source, we delete it. I've
defaulted to **delete** per the user directive's "stop anchoring nutrition to
per-100g mass," but worth a one-line confirm.
