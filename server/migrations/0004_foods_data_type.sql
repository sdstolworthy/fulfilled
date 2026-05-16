-- Add USDA FoodData Central `data_type` discriminator to foods.
--
-- USDA exposes four classes of records:
--   * foundation_food   — lab-analyzed reference foods
--   * sr_legacy_food    — Standard Reference Legacy (lab/computed)
--   * survey_fndds_food — composed dishes from the FNDDS survey
--   * branded_food      — manufacturer-submitted branded products
--
-- The search ranker (T11) needs to know which class a USDA row belongs to
-- so the central rescore can prefer Foundation/SR Legacy for generic
-- queries and keep branded scores low. OFF and user rows leave this NULL.
--
-- The source/data_type cross-check is added NOT VALID so it can be flipped
-- to VALID after the backfill in a single transaction; existing USDA rows
-- temporarily violate it until the join from food.csv runs.

ALTER TABLE foods ADD COLUMN IF NOT EXISTS data_type text;

ALTER TABLE foods ADD CONSTRAINT foods_data_type_check
    CHECK (
        data_type IS NULL
     OR data_type IN ('foundation_food', 'sr_legacy_food',
                      'survey_fndds_food', 'branded_food')
    );

ALTER TABLE foods ADD CONSTRAINT foods_data_type_source_check
    CHECK (
        source <> 'usda' OR data_type IS NOT NULL
    ) NOT VALID;
