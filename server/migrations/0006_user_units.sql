-- Add user-preference unit columns. Same shape for both: text + CHECK
-- against the OpenAPI enum + a documented default so existing rows
-- backfill cleanly. The columns are display preferences only — the
-- canonical storage (height_cm, weight_kg) is unchanged.
--
-- If the enum domain ever widens (e.g. add 'g' to weight_unit), three
-- files move together: this migration's CHECK, the Rust WeightUnit /
-- HeightUnit enums in loseit-core, and the OpenAPI schemas. The named
-- constraints below let a future migration DROP CONSTRAINT cleanly.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS weight_unit TEXT NOT NULL DEFAULT 'kg',
    ADD COLUMN IF NOT EXISTS height_unit TEXT NOT NULL DEFAULT 'cm';

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_weight_unit_check;
ALTER TABLE users ADD CONSTRAINT users_weight_unit_check
    CHECK (weight_unit IN ('kg', 'lb', 'st'));

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_height_unit_check;
ALTER TABLE users ADD CONSTRAINT users_height_unit_check
    CHECK (height_unit IN ('cm', 'ft_in'));
