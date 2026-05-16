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

    async fn bump_counts(&self, id: Uuid, seen: u64, upserted: u64, skipped: u64)
        -> CoreResult<()>;

    async fn finish(&self, id: Uuid, stats: UpsertStats) -> CoreResult<()>;

    async fn fail(&self, id: Uuid, error: &str) -> CoreResult<()>;
}
