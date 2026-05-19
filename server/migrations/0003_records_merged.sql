-- Phase 4.3 — cross-source / re-import dedup counter on import batches.
--
-- `records_merged` counts how many rows the per-food UPSERT updated via
-- ON CONFLICT (vs. how many were freshly inserted, which stays on
-- `records_upserted`). The motivating case is Phase 4.1: USDA Branded
-- imports now stamp `foods.barcode` from `gtinUpc`, so any product that
-- exists in both OFF and USDA collapses to a single `foods` row on the
-- second import — and we want operators to see how many of those
-- cross-source merges happened so the import ratios in §6.1 of
-- `import_plan.md` make sense.
--
-- Default 0 so older batches (started before this migration ran) read
-- back cleanly. Bigint to match the other `records_*` columns.

-- IF NOT EXISTS: ingest binaries (which run migrations) and the API binary
-- (which validates `_sqlx_migrations`) can be on different release cycles —
-- the API refuses to start if it sees a "future" migration row it doesn't
-- know about. Making this idempotent lets us re-apply or hand-roll the
-- ADD COLUMN out of sequence without trapping a stale API binary on prod.
ALTER TABLE food_import_batches
    ADD COLUMN IF NOT EXISTS records_merged BIGINT NOT NULL DEFAULT 0;
