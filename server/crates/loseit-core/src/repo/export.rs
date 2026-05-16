use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::ExportJob;
use crate::CoreResult;

#[async_trait]
pub trait ExportJobRepository: Send + Sync + 'static {
    /// Idempotently obtain the user's pending job. If one exists, return
    /// it; otherwise create a new pending row. Implementations use
    /// `INSERT … ON CONFLICT (user_id) WHERE status='pending' DO UPDATE`
    /// against the `export_jobs_one_pending_per_user` partial unique index.
    async fn insert_or_get_pending(&self, user_id: Uuid) -> CoreResult<ExportJob>;

    /// Create a fresh pending job unconditionally. Used when the caller
    /// has a non-pending (ready/failed/expired) prior job and asks for a
    /// re-export.
    async fn create_pending(&self, user_id: Uuid) -> CoreResult<ExportJob>;

    /// Look up a job scoped to a user. Returns `None` if the job doesn't
    /// exist OR if it belongs to a different user — handlers map both to
    /// 404 to avoid info leaks.
    async fn find(&self, user_id: Uuid, job_id: Uuid) -> CoreResult<Option<ExportJob>>;

    /// Mark a job ready. Sets `storage_key`, `expires_at`, status='ready'.
    async fn mark_ready(
        &self,
        job_id: Uuid,
        storage_key: String,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<ExportJob>;

    /// Mark a job failed. Sets `error`, status='failed'.
    async fn mark_failed(&self, job_id: Uuid, error: String) -> CoreResult<ExportJob>;

    /// Used at startup to re-enqueue any jobs that were in flight when the
    /// server stopped.
    async fn list_pending(&self) -> CoreResult<Vec<ExportJob>>;
}
