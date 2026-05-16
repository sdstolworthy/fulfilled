-- Merge staging_usda into foods + servings.
--
-- Conflict resolution: when a USDA branded row's gtin_upc collides with
-- an existing food's barcode (typically an OFF row), we keep whichever
-- source has the higher quality_score. Equal scores are a no-op (the
-- existing row stays).
--
-- USDA rows without a UPC (SR Legacy, Foundation, FNDDS) are identified
-- by fdc_id only.

\set ON_ERROR_STOP on
\timing on

-- 1) Sanity-clamp implausible nutrient values, exactly like the OFF
--    bulk load did. NUMERIC(8,2) tops out at 999999.99.
UPDATE staging_usda SET energy_kcal_100g   = NULL WHERE energy_kcal_100g  IS NOT NULL AND energy_kcal_100g  NOT BETWEEN 0 AND 2000;
UPDATE staging_usda SET protein_100g       = NULL WHERE protein_100g      IS NOT NULL AND protein_100g      NOT BETWEEN 0 AND 200;
UPDATE staging_usda SET carbs_100g         = NULL WHERE carbs_100g        IS NOT NULL AND carbs_100g        NOT BETWEEN 0 AND 200;
UPDATE staging_usda SET fat_100g           = NULL WHERE fat_100g          IS NOT NULL AND fat_100g          NOT BETWEEN 0 AND 200;
UPDATE staging_usda SET fiber_100g         = NULL WHERE fiber_100g        IS NOT NULL AND fiber_100g        NOT BETWEEN 0 AND 200;
UPDATE staging_usda SET sugar_100g         = NULL WHERE sugar_100g        IS NOT NULL AND sugar_100g        NOT BETWEEN 0 AND 200;
UPDATE staging_usda SET sodium_100g        = NULL WHERE sodium_100g       IS NOT NULL AND sodium_100g       NOT BETWEEN 0 AND 50;
UPDATE staging_usda SET saturated_fat_100g = NULL WHERE saturated_fat_100g IS NOT NULL AND saturated_fat_100g NOT BETWEEN 0 AND 200;

-- Drop rows that lost their energy_kcal (we require it).
DELETE FROM staging_usda WHERE energy_kcal_100g IS NULL;

-- 2) Compute quality_score per row. Same shape as the OFF formula —
--    USDA is generally well-populated so most rows land high.
ALTER TABLE staging_usda ADD COLUMN IF NOT EXISTS quality_score smallint;

UPDATE staging_usda SET quality_score = LEAST(100,
      -- USDA doesn't have nutriscore, so we give baseline 25 to USDA
      -- data instead. Foundation/SR Legacy are lab-grade; bonus 15.
      CASE WHEN data_type IN ('foundation_food','sr_legacy_food') THEN 40
           WHEN data_type = 'survey_fndds_food'                   THEN 30
           ELSE 25 END
    + CASE WHEN brand_name IS NOT NULL AND length(btrim(brand_name)) > 0 THEN 15
           WHEN brand_owner IS NOT NULL AND length(btrim(brand_owner)) > 0 THEN 10
           ELSE 0 END
    + CASE WHEN coalesce(serving_size, 0) > 0 THEN 15 ELSE 0 END
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
    + CASE WHEN extra_nutrients IS NOT NULL THEN 10 ELSE 0 END
)::smallint;

-- 3) Open a batch row.
INSERT INTO food_import_batches (id, source_url, status, records_seen)
SELECT gen_random_uuid(),
       '/data/fdc/FoodData_Central_csv_2026-04-30 (USDA bulk load)',
       'running',
       count(*) FROM staging_usda
RETURNING id \gset batch_

\echo '--- USDA batch id:' :'batch_id'

-- 4) Normalize fields for INSERT.
--    * name: prefer "BrandName Description" for branded foods to give
--      search a hook on brand. For non-branded, just the description.
--    * brands: brand_owner if present, else brand_name.
--    * barcode: gtin_upc, but only when non-empty and 8+ chars.
DROP TABLE IF EXISTS staging_usda_clean;
CREATE TEMP TABLE staging_usda_clean AS
SELECT
    fdc_id,
    data_type,
    btrim(description) AS name,
    NULLIF(coalesce(NULLIF(btrim(brand_owner), ''),
                    NULLIF(btrim(brand_name), '')), '') AS brands,
    CASE
        WHEN gtin_upc IS NULL OR length(btrim(gtin_upc)) < 8 THEN NULL
        WHEN btrim(gtin_upc) ~ '^[0-9]+$' THEN btrim(gtin_upc)
        ELSE NULL
    END AS barcode,
    serving_size,
    serving_size_unit,
    household_serving,
    energy_kcal_100g,
    protein_100g,
    carbs_100g,
    fat_100g,
    fiber_100g,
    sugar_100g,
    sodium_100g,
    saturated_fat_100g,
    extra_nutrients,
    quality_score
  FROM staging_usda
 WHERE description IS NOT NULL AND length(btrim(description)) > 0;

\echo
\echo '--- cleaned USDA rows:'
SELECT count(*) AS rows, count(barcode) AS with_barcode FROM staging_usda_clean;

-- 5) Step A: insert USDA rows whose barcode does NOT collide with an
--    existing food. fdc_id is also unique, so we let that protect us
--    against re-runs.
INSERT INTO foods (
    id, source, owner_user_id, fdc_id, barcode, name, brands,
    energy_kcal_100g, protein_100g, carbs_100g, fat_100g,
    fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g,
    quality_score, extra_nutrients, last_import_batch_id
)
SELECT
    gen_random_uuid(),
    'usda',
    NULL,
    s.fdc_id,
    s.barcode,
    s.name,
    s.brands,
    s.energy_kcal_100g,
    s.protein_100g,
    s.carbs_100g,
    s.fat_100g,
    s.fiber_100g,
    s.sugar_100g,
    s.sodium_100g,
    s.saturated_fat_100g,
    s.quality_score,
    s.extra_nutrients,
    :'batch_id'::uuid
  FROM staging_usda_clean s
 WHERE NOT EXISTS (
        SELECT 1 FROM foods f WHERE f.fdc_id = s.fdc_id
    )
   AND (
        s.barcode IS NULL
     OR NOT EXISTS (SELECT 1 FROM foods f WHERE f.barcode = s.barcode)
   )
ON CONFLICT DO NOTHING;

\echo
\echo '--- foods after USDA step A:'
SELECT count(*) FILTER (WHERE source = 'usda') AS usda, count(*) FILTER (WHERE source = 'off') AS off_, count(*) AS total FROM foods;

-- 6) Step B: barcode-collision rows. If USDA's quality_score is higher,
--    REPLACE the existing food (preserving id so log entries stay
--    valid). If equal-or-lower, skip.
UPDATE foods f
   SET source           = 'usda',
       fdc_id           = s.fdc_id,
       owner_user_id    = NULL,
       name             = s.name,
       brands           = coalesce(s.brands, f.brands),
       energy_kcal_100g = s.energy_kcal_100g,
       protein_100g     = s.protein_100g,
       carbs_100g       = s.carbs_100g,
       fat_100g         = s.fat_100g,
       fiber_100g       = s.fiber_100g,
       sugar_100g       = s.sugar_100g,
       sodium_100g      = s.sodium_100g,
       saturated_fat_100g = s.saturated_fat_100g,
       quality_score    = s.quality_score,
       extra_nutrients  = s.extra_nutrients,
       last_import_batch_id = :'batch_id'::uuid
  FROM staging_usda_clean s
 WHERE f.barcode = s.barcode
   AND s.barcode IS NOT NULL
   AND s.quality_score > f.quality_score
   AND f.source <> 'usda';        -- don't churn USDA rows on re-run

\echo
\echo '--- foods after USDA step B (collisions):'
SELECT count(*) FILTER (WHERE source = 'usda') AS usda, count(*) FILTER (WHERE source = 'off') AS off_, count(*) AS total FROM foods;

-- 7) Synthesize the 100 g serving for every freshly-inserted USDA food.
INSERT INTO servings (id, food_id, label, grams, is_default, source, sort_order)
SELECT
    gen_random_uuid(),
    f.id,
    '100 g',
    100,
    false,
    'system',
    100
  FROM foods f
 WHERE f.source = 'usda'
   AND NOT EXISTS (
       SELECT 1 FROM servings sv
        WHERE sv.food_id = f.id AND sv.source = 'system'
   );

-- 8) USDA-derived serving when serving_size is sane and unit is grams.
--    USDA uses 'g' (grams) or 'ml' (milliliters). We only ingest grams
--    in v1 — ml needs density info to compute true grams.
INSERT INTO servings (id, food_id, label, grams, is_default, source, sort_order)
SELECT
    gen_random_uuid(),
    f.id,
    coalesce(NULLIF(btrim(s.household_serving), ''),
             s.serving_size::text || ' g'),
    s.serving_size::numeric(8,2),
    false,
    'off',                    -- reuse the 'off' source slot for any
                              -- non-system serving; future v2 may add
                              -- a distinct 'usda' source
    0
  FROM foods f
  JOIN staging_usda_clean s ON s.fdc_id = f.fdc_id
 WHERE f.source = 'usda'
   AND s.serving_size IS NOT NULL
   AND s.serving_size >= 0.01
   AND s.serving_size < 100000
   AND lower(coalesce(s.serving_size_unit, '')) IN ('g','gram','grams','gm')
   AND NOT EXISTS (
       SELECT 1 FROM servings sv
        WHERE sv.food_id = f.id AND sv.source = 'off'
   );

-- 9) Re-pick the default serving for USDA foods only.
WITH usda_foods AS (
    SELECT id FROM foods WHERE source = 'usda'
)
UPDATE servings sv SET is_default = false
 WHERE sv.food_id IN (SELECT id FROM usda_foods)
   AND sv.is_default;

WITH chosen AS (
    SELECT DISTINCT ON (sv.food_id) sv.id
      FROM servings sv
      JOIN foods f ON f.id = sv.food_id AND f.source = 'usda'
     ORDER BY sv.food_id,
              CASE sv.source WHEN 'off' THEN 0 WHEN 'system' THEN 1 ELSE 2 END,
              sv.sort_order ASC
)
UPDATE servings sv SET is_default = true
  FROM chosen WHERE sv.id = chosen.id;

\echo
\echo '--- servings after USDA load:'
SELECT count(*) AS total, count(*) FILTER (WHERE is_default) AS defaults FROM servings;

-- 10) Close the batch.
UPDATE food_import_batches
   SET status = 'completed',
       completed_at = now(),
       records_upserted = (SELECT count(*) FROM staging_usda_clean),
       records_skipped  = 0
 WHERE id = :'batch_id'::uuid;

\echo
\echo '--- batch summary:'
SELECT id, status, records_seen, records_upserted,
       (completed_at - started_at) AS duration
  FROM food_import_batches
 WHERE id = :'batch_id'::uuid;

DROP TABLE staging_usda;
DROP TABLE staging_usda_clean;
