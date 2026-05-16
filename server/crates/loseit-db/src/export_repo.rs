use async_trait::async_trait;
use chrono::{DateTime, Utc};
use loseit_core::domain::{ExportJob, ExportStatus};
use loseit_core::repo::ExportJobRepository;
use loseit_core::CoreResult;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgExportJobRepository {
    pool: PgPool,
}

impl PgExportJobRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct ExportJobRow {
    id: Uuid,
    user_id: Uuid,
    status: String,
    storage_key: Option<String>,
    error: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    expires_at: Option<DateTime<Utc>>,
}

impl From<ExportJobRow> for ExportJob {
    fn from(row: ExportJobRow) -> Self {
        // Fall back to Pending if the DB CHECK was bypassed; never panic
        // on a row read.
        let status = ExportStatus::parse(&row.status).unwrap_or(ExportStatus::Pending);
        ExportJob {
            id: row.id,
            user_id: row.user_id,
            status,
            storage_key: row.storage_key,
            error: row.error,
            created_at: row.created_at,
            updated_at: row.updated_at,
            expires_at: row.expires_at,
        }
    }
}

const SELECT_COLS: &str =
    "id, user_id, status, storage_key, error, created_at, updated_at, expires_at";

#[async_trait]
impl ExportJobRepository for PgExportJobRepository {
    async fn insert_or_get_pending(&self, user_id: Uuid) -> CoreResult<ExportJob> {
        // The partial unique index `export_jobs_one_pending_per_user` only
        // covers rows with `status = 'pending'`, so ON CONFLICT only fires
        // when an existing pending row would be duplicated. In that case
        // the DO UPDATE bumps updated_at and the RETURNING surfaces the
        // existing row; otherwise we get a brand-new pending row.
        // Use the inference form (column + WHERE predicate) rather than
        // ON CONFLICT ON CONSTRAINT, because the uniqueness is enforced by a
        // `CREATE UNIQUE INDEX` partial index — not a named pg_constraint.
        // The predicate must match the migration's WHERE clause verbatim.
        let sql = format!(
            "INSERT INTO export_jobs (user_id, status) \
             VALUES ($1, 'pending') \
             ON CONFLICT (user_id) WHERE status = 'pending' \
             DO UPDATE SET updated_at = now() \
             RETURNING {SELECT_COLS}"
        );
        let row: ExportJobRow = sqlx::query_as(&sql)
            .bind(user_id)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn create_pending(&self, user_id: Uuid) -> CoreResult<ExportJob> {
        // Plain insert with no conflict resolution — used when callers
        // already know there is no pending row (e.g. after a prior job
        // is ready/failed/expired and the user asks for a re-export).
        let sql = format!(
            "INSERT INTO export_jobs (user_id, status) \
             VALUES ($1, 'pending') \
             RETURNING {SELECT_COLS}"
        );
        let row: ExportJobRow = sqlx::query_as(&sql)
            .bind(user_id)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn find(&self, user_id: Uuid, job_id: Uuid) -> CoreResult<Option<ExportJob>> {
        let sql = format!("SELECT {SELECT_COLS} FROM export_jobs WHERE id = $1 AND user_id = $2");
        let row: Option<ExportJobRow> = sqlx::query_as(&sql)
            .bind(job_id)
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn mark_ready(
        &self,
        job_id: Uuid,
        storage_key: String,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<ExportJob> {
        let sql = format!(
            "UPDATE export_jobs \
                SET status = 'ready', storage_key = $2, expires_at = $3, error = NULL \
                WHERE id = $1 AND status = 'pending' \
                RETURNING {SELECT_COLS}"
        );
        let row: ExportJobRow = sqlx::query_as(&sql)
            .bind(job_id)
            .bind(storage_key)
            .bind(expires_at)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn mark_failed(&self, job_id: Uuid, error: String) -> CoreResult<ExportJob> {
        let sql = format!(
            "UPDATE export_jobs \
                SET status = 'failed', error = $2 \
                WHERE id = $1 AND status = 'pending' \
                RETURNING {SELECT_COLS}"
        );
        let row: ExportJobRow = sqlx::query_as(&sql)
            .bind(job_id)
            .bind(error)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn list_pending(&self) -> CoreResult<Vec<ExportJob>> {
        let sql = format!(
            "SELECT {SELECT_COLS} FROM export_jobs WHERE status = 'pending' \
             ORDER BY created_at ASC"
        );
        let rows: Vec<ExportJobRow> = sqlx::query_as(&sql)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }
}
