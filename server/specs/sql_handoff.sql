-- LoseIt re-implementation: initial schema
-- Target: PostgreSQL 14+
--
-- Design notes:
--   * Server is timezone-agnostic. Clients assert absolute dates (DATE columns)
--     for things that happen "on a day." Audit fields use TIMESTAMPTZ.
--   * Foods come from two sources: OpenFoodFacts bulk import ('off') and
--     user-created customs ('user'). A CHECK constraint enforces ownership
--     invariants per source.
--   * Food log entries snapshot nutrition at write time. Reimporting OFF
--     never rewrites a user's history.
--   * Servings are first-class rows, not embedded in foods. Every food has
--     at least one serving; exactly one is the default.

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- trigram similarity for fuzzy search

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- OIDC identity. (issuer, external_id) is the stable handle on a person;
    -- email can change and isn't unique across issuers.
    issuer          TEXT NOT NULL,
    external_id     TEXT NOT NULL,
    email           TEXT,
    display_name    TEXT,

    -- Profile used for TDEE / macro suggestions. All optional; user can log
    -- food without filling these in.
    sex             TEXT CHECK (sex IN ('male', 'female', 'other')),
    birth_date      DATE,
    height_cm       NUMERIC(5,2) CHECK (height_cm IS NULL OR (height_cm > 0 AND height_cm < 300)),
    activity_level  TEXT CHECK (activity_level IN
                        ('sedentary', 'light', 'moderate', 'active', 'very_active')),

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (issuer, external_id)
);

-- ---------------------------------------------------------------------------
-- food_import_batches
--   Tracks each OFF bulk-import run so foods can be traced to their source
--   import and a partial/failed import can be diagnosed.
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
-- foods
--   Unified table for OFF-sourced foods and user customs. UUID id is the
--   real identity; barcode is a property (nullable, unique when present).
-- ---------------------------------------------------------------------------
CREATE TABLE foods (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    source                  TEXT NOT NULL CHECK (source IN ('off', 'user')),
    owner_user_id           UUID REFERENCES users(id) ON DELETE CASCADE,
    barcode                 TEXT,

    name                    TEXT NOT NULL,
    brands                  TEXT,
    categories_tags         TEXT[],

    -- Nutrition per 100g. We normalize OFF's per-100g fields and recompute
    -- per-serving values on demand.
    energy_kcal_100g        NUMERIC(8,2),
    protein_100g            NUMERIC(8,2),
    carbs_100g              NUMERIC(8,2),
    fat_100g                NUMERIC(8,2),
    fiber_100g              NUMERIC(8,2),
    sugar_100g              NUMERIC(8,2),
    sodium_100g             NUMERIC(8,2),       -- grams of sodium per 100g
    saturated_fat_100g      NUMERIC(8,2),

    nutriscore_grade        TEXT CHECK (nutriscore_grade IN ('a','b','c','d','e')),

    -- 0..100. Computed at ingest from data completeness signals. Search
    -- prefers higher-quality matches.
    quality_score           SMALLINT NOT NULL DEFAULT 0
                                CHECK (quality_score BETWEEN 0 AND 100),

    last_import_batch_id    UUID REFERENCES food_import_batches(id) ON DELETE SET NULL,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Source invariants:
    --   off   -> must have barcode, must NOT have owner
    --   user  -> must have owner, barcode optional
    CHECK (
        (source = 'off'  AND barcode IS NOT NULL AND owner_user_id IS NULL)
        OR
        (source = 'user' AND owner_user_id IS NOT NULL)
    )
);

-- Barcode is globally unique when present (across both OFF and user foods).
-- Partial index permits multiple user-custom foods without barcodes.
CREATE UNIQUE INDEX foods_barcode_unique ON foods(barcode) WHERE barcode IS NOT NULL;

-- Trigram index for fuzzy name search.
CREATE INDEX foods_name_trgm_idx ON foods USING gin (name gin_trgm_ops);

-- Full-text search index. Combine name + brands so "fage greek yogurt"
-- matches even when the brand and product name are split.
CREATE INDEX foods_fts_idx ON foods USING gin (
    to_tsvector('simple', coalesce(name, '') || ' ' || coalesce(brands, ''))
);

-- Scoped lookup for a user's own customs.
CREATE INDEX foods_owner_idx ON foods(owner_user_id) WHERE owner_user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- servings
--   Named portions per food. Every food gets at least one. Exactly one is
--   flagged is_default via a partial unique index.
-- ---------------------------------------------------------------------------
CREATE TABLE servings (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    food_id     UUID NOT NULL REFERENCES foods(id) ON DELETE CASCADE,

    label       TEXT NOT NULL,                  -- "medium apple", "1 cup sliced", "100 g"
    grams       NUMERIC(8,2) NOT NULL CHECK (grams > 0),
    is_default  BOOLEAN NOT NULL DEFAULT false,

    source      TEXT NOT NULL CHECK (source IN ('off', 'user', 'system')),
    sort_order  INT NOT NULL DEFAULT 0,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX servings_food_idx ON servings(food_id);
CREATE UNIQUE INDEX servings_one_default_per_food
    ON servings(food_id) WHERE is_default;

-- ---------------------------------------------------------------------------
-- weights
--   Wall-clock body weight readings. recorded_on is the client-asserted
--   absolute date; recorded_at_local is purely descriptive (no zone).
-- ---------------------------------------------------------------------------
CREATE TABLE weights (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    recorded_on         DATE NOT NULL,
    recorded_at_local   TIME,                   -- optional, no timezone

    weight_kg           NUMERIC(6,2) NOT NULL CHECK (weight_kg > 0 AND weight_kg < 1000),
    note                TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX weights_user_date_idx ON weights(user_id, recorded_on DESC);

-- ---------------------------------------------------------------------------
-- goals
--   Time-ranged. The "active" goal for a user on a given date is the row
--   whose [starts_on, ends_on] window contains that date (ends_on NULL =
--   open-ended). No is_active flag to keep in sync.
-- ---------------------------------------------------------------------------
CREATE TABLE goals (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    starts_on               DATE NOT NULL,
    ends_on                 DATE,
    CHECK (ends_on IS NULL OR ends_on >= starts_on),

    start_weight_kg         NUMERIC(6,2) CHECK (start_weight_kg IS NULL OR start_weight_kg > 0),
    target_weight_kg        NUMERIC(6,2) CHECK (target_weight_kg IS NULL OR target_weight_kg > 0),
    weekly_rate_kg          NUMERIC(4,2),       -- negative = loss, positive = gain

    daily_calorie_target    INT CHECK (daily_calorie_target IS NULL OR daily_calorie_target > 0),
    protein_g_target        NUMERIC(6,2) CHECK (protein_g_target IS NULL OR protein_g_target >= 0),
    carbs_g_target          NUMERIC(6,2) CHECK (carbs_g_target IS NULL OR carbs_g_target >= 0),
    fat_g_target            NUMERIC(6,2) CHECK (fat_g_target IS NULL OR fat_g_target >= 0),

    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX goals_user_window_idx ON goals(user_id, starts_on DESC);

-- ---------------------------------------------------------------------------
-- food_log_entries
--   The core feature. consumed_on is client-asserted. Nutrition is
--   snapshotted on write so future OFF reimports don't mutate history.
-- ---------------------------------------------------------------------------
CREATE TABLE food_log_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    food_id         UUID NOT NULL REFERENCES foods(id) ON DELETE RESTRICT,
    serving_id      UUID REFERENCES servings(id) ON DELETE SET NULL,

    consumed_on     DATE NOT NULL,
    meal            TEXT NOT NULL CHECK (meal IN ('breakfast', 'lunch', 'dinner', 'snack')),

    -- Quantity is a multiplier on the serving's grams. grams_total is stored
    -- so deleting the serving later doesn't lose the "how much" answer.
    quantity        NUMERIC(8,3) NOT NULL CHECK (quantity > 0),
    grams_total     NUMERIC(10,2) NOT NULL CHECK (grams_total > 0),

    -- Snapshot of nutrition for this exact entry. Computed at write time
    -- from the food's per-100g values and grams_total.
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

CREATE INDEX log_user_date_idx ON food_log_entries(user_id, consumed_on);
CREATE INDEX log_user_date_meal_idx ON food_log_entries(user_id, consumed_on, meal);
CREATE INDEX log_food_idx ON food_log_entries(food_id);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
--   sqlx migrations don't run app code, so do it in the DB.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER foods_set_updated_at
    BEFORE UPDATE ON foods
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER servings_set_updated_at
    BEFORE UPDATE ON servings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER goals_set_updated_at
    BEFORE UPDATE ON goals
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER food_log_entries_set_updated_at
    BEFORE UPDATE ON food_log_entries
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

