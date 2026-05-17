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
