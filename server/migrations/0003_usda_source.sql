-- Extend the foods schema to admit USDA FoodData Central (FDC) records
-- alongside OpenFoodFacts and user-custom rows.
--
-- USDA brings two new bits of identity + a bag of micronutrients:
--   * fdc_id          — USDA's per-record key (BIGINT, ~7-9 digits)
--   * extra_nutrients — JSONB for the long tail of vitamins/minerals we
--                       don't have first-class columns for
--
-- The existing source CHECK ('off' | 'user') is widened to include
-- 'usda'. USDA rows always have an fdc_id; OFF/user rows never do, and
-- a row-level CHECK enforces the invariant per source.

ALTER TABLE foods
    ADD COLUMN IF NOT EXISTS fdc_id BIGINT,
    ADD COLUMN IF NOT EXISTS extra_nutrients JSONB;

-- 0001 named the source-domain CHECK `foods_source_check`. Drop it
-- explicitly and recreate with the wider domain.
ALTER TABLE foods DROP CONSTRAINT IF EXISTS foods_source_check;
ALTER TABLE foods ADD CONSTRAINT foods_source_check
    CHECK (source IN ('off', 'user', 'usda'));

-- The big per-source identity invariant was unnamed in 0001 (it lives on
-- a row-level CHECK). Find it by pg_constraint inspection, drop it, and
-- replace with the three-source variant.
DO $$
DECLARE
    cname text;
BEGIN
    SELECT conname INTO cname
      FROM pg_constraint
     WHERE conrelid = 'foods'::regclass
       AND contype  = 'c'
       AND pg_get_constraintdef(oid) LIKE '%source = ''off''%';
    IF cname IS NOT NULL THEN
        EXECUTE format('ALTER TABLE foods DROP CONSTRAINT %I', cname);
    END IF;
END $$;

ALTER TABLE foods DROP CONSTRAINT IF EXISTS foods_source_identity_check;
ALTER TABLE foods ADD CONSTRAINT foods_source_identity_check
    CHECK (
        (source = 'off'  AND barcode IS NOT NULL AND owner_user_id IS NULL  AND fdc_id IS NULL)
     OR (source = 'user' AND owner_user_id IS NOT NULL                     AND fdc_id IS NULL)
     OR (source = 'usda' AND fdc_id IS NOT NULL AND owner_user_id IS NULL)
    );

-- fdc_id is globally unique when present.
CREATE UNIQUE INDEX IF NOT EXISTS foods_fdc_id_unique
    ON foods (fdc_id) WHERE fdc_id IS NOT NULL;
