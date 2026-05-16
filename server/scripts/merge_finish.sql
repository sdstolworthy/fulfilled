-- Finish the merge after the staging table has been dedup'd and scored.
-- Re-runnable: every INSERT uses ON CONFLICT / WHERE NOT EXISTS guards.

\set ON_ERROR_STOP on
\timing on

INSERT INTO food_import_batches (id, source_url, status, records_seen)
SELECT gen_random_uuid(),
       '/data/openfoodfacts-flat.jsonl (bulk SQL load)',
       'running',
       count(*) FROM staging_bulk
RETURNING id \gset batch_

\echo '--- batch id:' :'batch_id'

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
    CASE WHEN nutriscore_grade IN ('a','b','c','d','e')
         THEN nutriscore_grade ELSE NULL END,
    quality_score,
    :'batch_id'::uuid
  FROM staging_bulk
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
\echo '--- foods now in DB:'
SELECT count(*) FROM foods;

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
  JOIN staging_bulk s ON s.code = f.barcode
 WHERE NOT EXISTS (
    SELECT 1 FROM servings sv
     WHERE sv.food_id = f.id AND sv.source = 'system'
 );

INSERT INTO servings (id, food_id, label, grams, is_default, source, sort_order)
SELECT
    gen_random_uuid(),
    f.id,
    coalesce(NULLIF(s.serving_size, ''), s.serving_quantity_g::text || ' g'),
    s.serving_quantity_g::numeric(8,2),
    false,
    'off',
    0
  FROM foods f
  JOIN staging_bulk s ON s.code = f.barcode
 WHERE s.serving_quantity_g IS NOT NULL
   AND s.serving_quantity_g > 0
   AND s.serving_quantity_g < 100000
   AND NOT EXISTS (
       SELECT 1 FROM servings sv
        WHERE sv.food_id = f.id AND sv.source = 'off'
   );

UPDATE servings SET is_default = false WHERE is_default = true;

WITH chosen AS (
    SELECT DISTINCT ON (food_id)
           id
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
\echo '--- servings now in DB:'
SELECT count(*) AS total, count(*) FILTER (WHERE is_default) AS defaults FROM servings;

UPDATE food_import_batches
   SET status = 'completed',
       completed_at = now(),
       records_upserted = (SELECT count(*) FROM staging_bulk),
       records_skipped  = 0
 WHERE id = :'batch_id'::uuid;

\echo
\echo '--- batch summary:'
SELECT id, status, records_seen, records_upserted,
       (completed_at - started_at) AS duration
  FROM food_import_batches
 WHERE id = :'batch_id'::uuid;

DROP TABLE staging_bulk;
