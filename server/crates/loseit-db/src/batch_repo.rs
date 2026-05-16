use async_trait::async_trait;
use chrono::{DateTime, Utc};
use loseit_core::domain::{BatchStatus, FoodImportBatch};
use loseit_core::repo::{BatchRepository, UpsertStats};
use loseit_core::CoreResult;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgBatchRepository {
    pool: PgPool,
}

impl PgBatchRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct BatchRow {
    id: Uuid,
    started_at: DateTime<Utc>,
    completed_at: Option<DateTime<Utc>>,
    source_url: String,
    source_etag: Option<String>,
    records_seen: i64,
    records_upserted: i64,
    records_skipped: i64,
    status: String,
    error: Option<String>,
}

impl From<BatchRow> for FoodImportBatch {
    fn from(row: BatchRow) -> Self {
        // `parse` returning None would mean the DB CHECK constraint was
        // bypassed; fall back to Running so we never panic on a row read.
        let status = BatchStatus::parse(&row.status).unwrap_or(BatchStatus::Running);
        FoodImportBatch {
            id: row.id,
            started_at: row.started_at,
            completed_at: row.completed_at,
            source_url: row.source_url,
            source_etag: row.source_etag,
            records_seen: row.records_seen,
            records_upserted: row.records_upserted,
            records_skipped: row.records_skipped,
            status,
            error: row.error,
        }
    }
}

const SELECT_COLS: &str = "id, started_at, completed_at, source_url, source_etag, \
    records_seen, records_upserted, records_skipped, status, error";

#[async_trait]
impl BatchRepository for PgBatchRepository {
    async fn start(
        &self,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<FoodImportBatch> {
        let sql = format!(
            "INSERT INTO food_import_batches \
                (source_url, source_etag, records_seen, records_upserted, records_skipped, status) \
             VALUES ($1, $2, 0, 0, 0, 'running') \
             RETURNING {SELECT_COLS}"
        );
        let row: BatchRow = sqlx::query_as(&sql)
            .bind(source_url)
            .bind(source_etag)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn bump_counts(
        &self,
        id: Uuid,
        seen: u64,
        upserted: u64,
        skipped: u64,
    ) -> CoreResult<()> {
        // Postgres BIGINT is i64; the trait uses u64 because callers count
        // upward. Cast is safe: real import counts are far below i64::MAX.
        let sql = "UPDATE food_import_batches \
                   SET records_seen = records_seen + $2, \
                       records_upserted = records_upserted + $3, \
                       records_skipped = records_skipped + $4 \
                   WHERE id = $1";
        sqlx::query(sql)
            .bind(id)
            .bind(seen as i64)
            .bind(upserted as i64)
            .bind(skipped as i64)
            .execute(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(())
    }

    async fn finish(&self, id: Uuid, _stats: UpsertStats) -> CoreResult<()> {
        // Counters were already kept current by `bump_counts`; we only flip
        // status here. Guard on `status = 'running'` so a double-finish
        // (or a finish-after-fail) is a silent no-op rather than an error.
        let sql = "UPDATE food_import_batches \
                   SET status = 'completed', completed_at = now() \
                   WHERE id = $1 AND status = 'running'";
        sqlx::query(sql)
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(())
    }

    async fn fail(&self, id: Uuid, error: &str) -> CoreResult<()> {
        // Fail is unconditionally idempotent: re-failing just overwrites
        // the error text and completed_at, which is the desired behavior
        // when a retry/cleanup path calls fail() more than once.
        let sql = "UPDATE food_import_batches \
                   SET status = 'failed', completed_at = now(), error = $2 \
                   WHERE id = $1";
        sqlx::query(sql)
            .bind(id)
            .bind(error)
            .execute(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(())
    }
}
