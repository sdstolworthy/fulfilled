use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::FoodImportBatch;
use crate::repo::food::UpsertStats;
use crate::CoreResult;

#[async_trait]
pub trait BatchRepository: Send + Sync + 'static {
    async fn start(
        &self,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<FoodImportBatch>;

    /// Bump the four running counters on a `food_import_batches` row.
    ///
    /// Phase 4.3: `merged` is the cross-source / re-import dedup counter
    /// (the `xmax = 0` UPDATE branch in the Pg writer) and is plumbed
    /// onto `food_import_batches.records_merged` via migration 0003.
    /// Existing callers that don't track merges should pass `0`.
    async fn bump_counts(
        &self,
        id: Uuid,
        seen: u64,
        upserted: u64,
        merged: u64,
        skipped: u64,
    ) -> CoreResult<()>;

    async fn finish(&self, id: Uuid, stats: UpsertStats) -> CoreResult<()>;

    async fn fail(&self, id: Uuid, error: &str) -> CoreResult<()>;

    /// Phase 2.1: look up the most recently-started completed batch with
    /// the given `source_url` AND `source_etag`. Used by `IngestService` to
    /// short-circuit a rerun when the input file (identified by its SHA-256
    /// + size etag) was already imported to completion. `source_etag = None`
    /// always returns `None` — a missing etag isn't safely identifying.
    async fn find_completed_batch(
        &self,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<Option<FoodImportBatch>>;
}
