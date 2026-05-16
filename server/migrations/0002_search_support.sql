-- Trigram index on brands for combined name+brand fuzzy search. The
-- existing 0001_initial.sql created the trigram index on `name` only;
-- adding `brands` here lets brand-only typo queries hit an index too.
CREATE INDEX IF NOT EXISTS foods_brands_trgm_idx
    ON foods USING gin (coalesce(brands, '') gin_trgm_ops);
