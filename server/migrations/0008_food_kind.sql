-- Add `kind` discriminator to foods. Default `'normal'`; the per-user
-- quick-add sentinel rows backfill to `'quick_add'`. The FE uses this
-- to route Edit on quick-add log entries to the quick-add sheet
-- (instead of the canonical food-edit sheet) without UUID coordination.
--
-- Future kinds (e.g. 'recipe', 'meal_template') extend the CHECK domain
-- without a column rename.

ALTER TABLE foods
    ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'normal';

ALTER TABLE foods DROP CONSTRAINT IF EXISTS foods_kind_check;
ALTER TABLE foods ADD CONSTRAINT foods_kind_check
    CHECK (kind IN ('normal', 'quick_add'));

-- Backfill the existing per-user sentinel rows. The
-- `foods_quick_add_singleton` partial unique index
-- (migration 0005) is keyed on exactly the same predicate, so this
-- update touches one row per user and zero rows otherwise.
UPDATE foods
   SET kind = 'quick_add'
 WHERE source = 'user'
   AND name = '__quick_add__'
   AND kind <> 'quick_add';
