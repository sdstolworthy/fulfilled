use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use loseit_core::domain::{ExportJob, ExportStatus};
use loseit_core::repo::ExportJobRepository;
use loseit_core::CoreResult;
use uuid::Uuid;

/// In-memory fake matching the semantics of [`ExportJobRepository`]. Backed
/// by a `Mutex<Vec<ExportJob>>` and intended for service- and handler-level
/// tests where a live Postgres instance is overkill.
#[derive(Default)]
pub struct InMemoryExportJobRepository {
    jobs: Mutex<Vec<ExportJob>>,
}

impl InMemoryExportJobRepository {
    pub fn new() -> Self {
        Self::default()
    }
}

fn fresh_pending(user_id: Uuid) -> ExportJob {
    let now = Utc::now();
    ExportJob {
        id: Uuid::new_v4(),
        user_id,
        status: ExportStatus::Pending,
        storage_key: None,
        error: None,
        created_at: now,
        updated_at: now,
        expires_at: None,
    }
}

#[async_trait]
impl ExportJobRepository for InMemoryExportJobRepository {
    async fn insert_or_get_pending(&self, user_id: Uuid) -> CoreResult<ExportJob> {
        let mut store = self.jobs.lock().unwrap();
        // Mirror the partial unique index: a pending row blocks a second
        // pending row for the same user. Returning the existing row makes
        // POST /me/export naturally idempotent.
        if let Some(existing) = store
            .iter_mut()
            .find(|j| j.user_id == user_id && j.status == ExportStatus::Pending)
        {
            existing.updated_at = Utc::now();
            return Ok(existing.clone());
        }
        let job = fresh_pending(user_id);
        store.push(job.clone());
        Ok(job)
    }

    async fn create_pending(&self, user_id: Uuid) -> CoreResult<ExportJob> {
        let mut store = self.jobs.lock().unwrap();
        let job = fresh_pending(user_id);
        store.push(job.clone());
        Ok(job)
    }

    async fn find(&self, user_id: Uuid, job_id: Uuid) -> CoreResult<Option<ExportJob>> {
        let store = self.jobs.lock().unwrap();
        Ok(store
            .iter()
            .find(|j| j.id == job_id && j.user_id == user_id)
            .cloned())
    }

    async fn mark_ready(
        &self,
        job_id: Uuid,
        storage_key: String,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<ExportJob> {
        let mut store = self.jobs.lock().unwrap();
        // Mirror the Pg `WHERE id = $1 AND status = 'pending'` guard.
        let job = store
            .iter_mut()
            .find(|j| j.id == job_id && j.status == ExportStatus::Pending)
            .ok_or(loseit_core::CoreError::NotFound)?;
        job.status = ExportStatus::Ready;
        job.storage_key = Some(storage_key);
        job.expires_at = Some(expires_at);
        job.error = None;
        job.updated_at = Utc::now();
        Ok(job.clone())
    }

    async fn mark_failed(&self, job_id: Uuid, error: String) -> CoreResult<ExportJob> {
        let mut store = self.jobs.lock().unwrap();
        // Mirror the Pg `WHERE id = $1 AND status = 'pending'` guard.
        let job = store
            .iter_mut()
            .find(|j| j.id == job_id && j.status == ExportStatus::Pending)
            .ok_or(loseit_core::CoreError::NotFound)?;
        job.status = ExportStatus::Failed;
        job.error = Some(error);
        job.updated_at = Utc::now();
        Ok(job.clone())
    }

    async fn list_pending(&self) -> CoreResult<Vec<ExportJob>> {
        let store = self.jobs.lock().unwrap();
        // Mirror the Pg `ORDER BY created_at ASC` so callers see a
        // deterministic, byte-identical ordering.
        let mut pending: Vec<ExportJob> = store
            .iter()
            .filter(|j| j.status == ExportStatus::Pending)
            .cloned()
            .collect();
        pending.sort_by_key(|j| j.created_at);
        Ok(pending)
    }
}
