-- DuckDB pipeline: flatten the USDA FDC CSV bundle into the PG
-- `staging_usda` table.
--
-- Run with:
--   duckdb < scripts/load_usda.duckdb.sql
--
-- Drops null bytes (Postgres rejects them) and only keeps the food
-- data_types that represent consumer-facing products.

INSTALL postgres; LOAD postgres;
ATTACH 'host=localhost port=5432 dbname=loseit user=loseit password=loseit' AS pg (TYPE postgres);
SET pg_null_byte_replacement = '';

SET VARIABLE fdc_dir = '/workplace/fulfilled/server/data/fdc/FoodData_Central_csv_2026-04-30';

-- Pre-load lookup tables into duckdb's memory.
CREATE TEMP TABLE food AS
    SELECT fdc_id, data_type, description
      FROM read_csv(getvariable('fdc_dir') || '/food.csv',
           AUTO_DETECT=true, ignore_errors=true,
           columns={'fdc_id':'BIGINT','data_type':'VARCHAR','description':'VARCHAR','food_category_id':'VARCHAR','publication_date':'VARCHAR'})
     WHERE data_type IN ('branded_food','sr_legacy_food','survey_fndds_food',
                         'foundation_food');

CREATE TEMP TABLE nutrient AS
    SELECT id, name FROM read_csv(
        getvariable('fdc_dir') || '/nutrient.csv',
        AUTO_DETECT=true, ignore_errors=true);

CREATE TEMP TABLE branded AS
    SELECT fdc_id, brand_owner, brand_name, subbrand_name, gtin_upc,
           ingredients, serving_size, serving_size_unit, household_serving_fulltext
      FROM read_csv(getvariable('fdc_dir') || '/branded_food.csv',
           AUTO_DETECT=true,
           ignore_errors=true);

-- food_nutrient is huge; only project what we need and only for the
-- food rows that survived the data_type filter.
CREATE TEMP TABLE fn AS
    SELECT fn.fdc_id, fn.nutrient_id, fn.amount
      FROM read_csv(getvariable('fdc_dir') || '/food_nutrient.csv',
           AUTO_DETECT=true, ignore_errors=true) fn
      JOIN food f USING (fdc_id);

-- Pivot the macros we care about. USDA values are already per-100 g.
CREATE TEMP TABLE macros AS
    SELECT
        fdc_id,
        MAX(CASE WHEN nutrient_id IN (1008, 2047, 2048) THEN amount END) AS energy_kcal_100g,
        MAX(CASE WHEN nutrient_id = 1003 THEN amount END)                AS protein_100g,
        MAX(CASE WHEN nutrient_id = 1005 THEN amount END)                AS carbs_100g,
        MAX(CASE WHEN nutrient_id = 1004 THEN amount END)                AS fat_100g,
        MAX(CASE WHEN nutrient_id = 1079 THEN amount END)                AS fiber_100g,
        MAX(CASE WHEN nutrient_id IN (2000, 1063) THEN amount END)       AS sugar_100g,
        -- sodium: USDA stores mg/100g; convert to g/100g for our schema.
        MAX(CASE WHEN nutrient_id = 1093 THEN amount / 1000.0 END)       AS sodium_100g,
        MAX(CASE WHEN nutrient_id = 1258 THEN amount END)                AS saturated_fat_100g
      FROM fn
     GROUP BY fdc_id;

-- Build the JSONB extras: the long-tail nutrients we don't promote to
-- first-class columns. Keyed by nutrient name, valued as the per-100 g
-- amount. We exclude the 8 macros that already have dedicated columns
-- to avoid duplicating data.
CREATE TEMP TABLE extras AS
    SELECT fn.fdc_id,
           json_group_object(n.name, fn.amount) AS extra_nutrients
      FROM fn
      JOIN nutrient n ON n.id = fn.nutrient_id
     WHERE fn.amount IS NOT NULL
       AND fn.nutrient_id NOT IN (
            1008, 2047, 2048,
            1003, 1005, 1004,
            1079, 2000, 1063,
            1093, 1258
       )
     GROUP BY fn.fdc_id;

-- Final flat shape pushed to PG.
INSERT INTO pg.staging_usda
SELECT
    f.fdc_id,
    f.data_type,
    replace(f.description, chr(0), ''),
    NULL                                 AS food_category,
    replace(b.gtin_upc, chr(0), '')      AS gtin_upc,
    replace(b.brand_owner, chr(0), '')   AS brand_owner,
    replace(b.brand_name, chr(0), '')    AS brand_name,
    replace(b.subbrand_name, chr(0), '') AS subbrand_name,
    NULL                                 AS ingredients,   -- skip: large + not used today
    b.serving_size,
    b.serving_size_unit,
    replace(b.household_serving_fulltext, chr(0), '') AS household_serving,
    macros.energy_kcal_100g,
    macros.protein_100g,
    macros.carbs_100g,
    macros.fat_100g,
    macros.fiber_100g,
    macros.sugar_100g,
    macros.sodium_100g,
    macros.saturated_fat_100g,
    extras.extra_nutrients::JSON
  FROM food f
  LEFT JOIN branded b USING (fdc_id)
  LEFT JOIN macros USING (fdc_id)
  LEFT JOIN extras USING (fdc_id)
 WHERE macros.energy_kcal_100g IS NOT NULL;
