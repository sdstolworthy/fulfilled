-- Bulk-load OFF foods into the loseit database.
--
-- Run from inside the postgres container:
--   docker exec -i loseit-postgres psql -U loseit -d loseit \
--      -v staging_csv=/data/staging.csv < bulk_load.sql
--
-- The compose file mounts ./data into the container at /data, so
-- staging.csv lives at /data/staging.csv from the container's POV.
--
-- This is the fast path for the initial bulk import: ~10 min for 3M
-- rows vs hours through the Rust binary's per-record upsert loop.
-- The Rust binary stays the production path for delta/idempotent runs.

\set ON_ERROR_STOP on
\timing on

DROP TABLE IF EXISTS staging;
CREATE TEMP TABLE staging (
    code               TEXT,
    product_name       TEXT,
    brands             TEXT,
    categories_tags    TEXT[],
    nutriscore_grade   TEXT,
    energy_kcal_100g   DOUBLE PRECISION,
    protein_100g       DOUBLE PRECISION,
    carbs_100g         DOUBLE PRECISION,
    fat_100g           DOUBLE PRECISION,
    fiber_100g         DOUBLE PRECISION,
    sugar_100g         DOUBLE PRECISION,
    sodium_100g        DOUBLE PRECISION,
    saturated_fat_100g DOUBLE PRECISION,
    completeness       DOUBLE PRECISION,
    serving_quantity_g DOUBLE PRECISION,
    serving_size       TEXT
);

\copy staging FROM '/data/staging.csv' WITH (FORMAT csv, HEADER true)

\echo
\echo '--- staged rows:'
SELECT count(*) AS staged FROM staging;

-- Drop obvious junk + de-dup by barcode (keep highest completeness).
DELETE FROM staging
    WHERE code IS NULL OR code = ''
       OR product_name IS NULL OR product_name = ''
       OR energy_kcal_100g IS NULL;

WITH ranked AS (
    SELECT ctid,
           row_number() OVER (
               PARTITION BY code
               ORDER BY completeness DESC NULLS LAST,
                        energy_kcal_100g DESC NULLS LAST
           ) AS rn
      FROM staging
)
DELETE FROM staging WHERE ctid IN (SELECT ctid FROM ranked WHERE rn > 1);

ALTER TABLE staging ADD COLUMN quality_score smallint;

UPDATE staging SET quality_score = LEAST(100,
      CASE WHEN nutriscore_grade IN ('a','b','c','d','e') THEN 40 ELSE 0 END
    + CASE WHEN brands IS NOT NULL AND length(btrim(brands)) > 0 THEN 15 ELSE 0 END
    + CASE WHEN coalesce(serving_quantity_g, 0) > 0 THEN 15 ELSE 0 END
    + CASE
          WHEN ( (protein_100g       IS NOT NULL)::int
               + (carbs_100g         IS NOT NULL)::int
               + (fat_100g           IS NOT NULL)::int
               + (fiber_100g         IS NOT NULL)::int
               + (sugar_100g         IS NOT NULL)::int
               + (sodium_100g        IS NOT NULL)::int
               + (saturated_fat_100g IS NOT NULL)::int) >= 6 THEN 10
          WHEN ( (protein_100g       IS NOT NULL)::int
               + (carbs_100g         IS NOT NULL)::int
               + (fat_100g           IS NOT NULL)::int
               + (fiber_100g         IS NOT NULL)::int
               + (sugar_100g         IS NOT NULL)::int
               + (sodium_100g        IS NOT NULL)::int
               + (saturated_fat_100g IS NOT NULL)::int) >= 3 THEN 5
          ELSE 0
      END
    + CASE WHEN completeness IS NOT NULL
           THEN GREATEST(0, LEAST(10, (completeness * 10)::int))
           ELSE 0
      END
    + CASE WHEN categories_tags IS NOT NULL
            AND array_length(categories_tags, 1) > 0
           THEN 10 ELSE 0
      END
)::smallint;

\echo
\echo '--- distinct rows ready to load:'
SELECT count(*) AS ready FROM staging;

-- Open the batch row.
INSERT INTO food_import_batches (id, source_url, status, records_seen)
SELECT gen_random_uuid(),
       '/data/openfoodfacts-flat.jsonl (bulk SQL load)',
       'running',
       count(*) FROM staging
RETURNING id \gset batch_

\echo '--- batch id:' :'batch_id'

-- Upsert into foods. ON CONFLICT (barcode) updates the existing row,
-- preserving the id so log entries referencing it stay valid.
INSERT INTO foods (
    id, source, owner_user_id, barcode, name, brands, categories_tags,
    energy_kcal_100g, protein_100g, carbs_100g, fat_100g,
    fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g,
    nutriscore_grade, quality_score, last_import_batch_id
)
SELECT
    gen_random_uuid(),
    'off',
    NULL,
    code,
    product_name,
    NULLIF(brands, ''),
    categories_tags,
    energy_kcal_100g,
    protein_100g,
    carbs_100g,
    fat_100g,
    fiber_100g,
    sugar_100g,
    sodium_100g,
    saturated_fat_100g,
    NULLIF(nutriscore_grade, ''),
    quality_score,
    :'batch_id'::uuid
  FROM staging
ON CONFLICT (barcode) WHERE barcode IS NOT NULL DO UPDATE SET
    name                 = EXCLUDED.name,
    brands               = EXCLUDED.brands,
    categories_tags      = EXCLUDED.categories_tags,
    energy_kcal_100g     = EXCLUDED.energy_kcal_100g,
    protein_100g         = EXCLUDED.protein_100g,
    carbs_100g           = EXCLUDED.carbs_100g,
    fat_100g             = EXCLUDED.fat_100g,
    fiber_100g           = EXCLUDED.fiber_100g,
    sugar_100g           = EXCLUDED.sugar_100g,
    sodium_100g          = EXCLUDED.sodium_100g,
    saturated_fat_100g   = EXCLUDED.saturated_fat_100g,
    nutriscore_grade     = EXCLUDED.nutriscore_grade,
    quality_score        = EXCLUDED.quality_score,
    last_import_batch_id = EXCLUDED.last_import_batch_id;

\echo
\echo '--- foods loaded:'
SELECT count(*) FROM foods;

-- Now servings. For every food that has no system serving yet, insert
-- one at 100 g. is_default is true unless an OFF-derived serving will
-- be inserted below (we decide that in the next step).
INSERT INTO servings (id, food_id, label, grams, is_default, source, sort_order)
SELECT
    gen_random_uuid(),
    f.id,
    '100 g',
    100,
    false,                 -- defaults are set below in a second pass
    'system',
    100
  FROM foods f
  JOIN staging s ON s.code = f.barcode
 WHERE NOT EXISTS (
    SELECT 1 FROM servings sv
     WHERE sv.food_id = f.id AND sv.source = 'system'
 );

-- OFF-derived serving when serving_quantity_g is sane.
INSERT INTO servings (id, food_id, label, grams, is_default, source, sort_order)
SELECT
    gen_random_uuid(),
    f.id,
    coalesce(NULLIF(s.serving_size, ''), s.serving_quantity_g::text || ' g'),
    s.serving_quantity_g,
    false,
    'off',
    0
  FROM foods f
  JOIN staging s ON s.code = f.barcode
 WHERE s.serving_quantity_g IS NOT NULL
   AND s.serving_quantity_g > 0
   AND s.serving_quantity_g < 100000
   AND NOT EXISTS (
       SELECT 1 FROM servings sv
        WHERE sv.food_id = f.id AND sv.source = 'off'
   );

-- Default-serving pass: for each food, mark the OFF-derived serving as
-- default if it exists, else mark the 100 g one. Doing it in two
-- statements (clear → set) keeps the partial unique index happy.
UPDATE servings SET is_default = false
 WHERE food_id IN (SELECT id FROM foods)
   AND is_default = true;

WITH chosen AS (
    SELECT DISTINCT ON (food_id)
           id, food_id
      FROM servings
     ORDER BY food_id,
              CASE source WHEN 'off' THEN 0 WHEN 'system' THEN 1 ELSE 2 END,
              sort_order ASC
)
UPDATE servings sv
   SET is_default = true
  FROM chosen
 WHERE sv.id = chosen.id;

\echo
\echo '--- servings loaded:'
SELECT count(*) FROM servings;

-- Close the batch.
UPDATE food_import_batches
   SET status = 'completed',
       completed_at = now(),
       records_upserted = (SELECT count(*) FROM staging),
       records_skipped  = 0
 WHERE id = :'batch_id'::uuid;

\echo
\echo '--- batch summary:'
SELECT id, status, records_seen, records_upserted, records_skipped,
       (completed_at - started_at) AS duration
  FROM food_import_batches
 WHERE id = :'batch_id'::uuid;

DROP TABLE staging;
