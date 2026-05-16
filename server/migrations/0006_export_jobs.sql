-- Async data-export jobs for `POST /me/export` / `GET /me/export/:job_id`.
-- One row per export attempt. Status flows pending → ready | failed.
-- The fourth status, `expired`, is computed at GET time from
-- `expires_at < now()` — not stored — so we never need a sweeper to flip it.

CREATE TABLE export_jobs (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    status       TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'failed')),
    storage_key  TEXT,
    error        TEXT,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ
);

-- Idempotency: at most one pending job per user. Lets POST /me/export
-- be a `find-or-create-pending` upsert via ON CONFLICT.
CREATE UNIQUE INDEX export_jobs_one_pending_per_user
    ON export_jobs(user_id)
    WHERE status = 'pending';

CREATE INDEX export_jobs_user_id_idx ON export_jobs(user_id);
CREATE INDEX export_jobs_status_idx ON export_jobs(status);

CREATE TRIGGER export_jobs_set_updated_at
    BEFORE UPDATE ON export_jobs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
