use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::Utc;
use loseit_core::domain::{BatchStatus, FoodImportBatch};
use loseit_core::repo::{BatchRepository, UpsertStats};
use loseit_core::CoreResult;
use uuid::Uuid;

#[derive(Default)]
pub struct InMemoryBatchRepository {
    by_id: Mutex<HashMap<Uuid, FoodImportBatch>>,
}

impl InMemoryBatchRepository {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, id: Uuid) -> Option<FoodImportBatch> {
        self.by_id.lock().unwrap().get(&id).cloned()
    }

    /// Test-only helper: find a batch by its `source_url`. Returns the
    /// first match (batches in the fake are not ordered).
    pub fn find_by_url(&self, url: &str) -> Option<Uuid> {
        self.by_id
            .lock()
            .unwrap()
            .values()
            .find(|b| b.source_url == url)
            .map(|b| b.id)
    }
}

#[async_trait]
impl BatchRepository for InMemoryBatchRepository {
    async fn start(
        &self,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<FoodImportBatch> {
        let batch = FoodImportBatch {
            id: Uuid::new_v4(),
            started_at: Utc::now(),
            completed_at: None,
            source_url: source_url.to_string(),
            source_etag: source_etag.map(|s| s.to_string()),
            records_seen: 0,
            records_upserted: 0,
            records_skipped: 0,
            status: BatchStatus::Running,
            error: None,
        };
        self.by_id.lock().unwrap().insert(batch.id, batch.clone());
        Ok(batch)
    }

    async fn bump_counts(
        &self,
        id: Uuid,
        seen: u64,
        upserted: u64,
        skipped: u64,
    ) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        let batch = store.get_mut(&id).ok_or(loseit_core::CoreError::NotFound)?;
        batch.records_seen += seen as i64;
        batch.records_upserted += upserted as i64;
        batch.records_skipped += skipped as i64;
        Ok(())
    }

    async fn finish(&self, id: Uuid, stats: UpsertStats) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        let batch = store.get_mut(&id).ok_or(loseit_core::CoreError::NotFound)?;
        batch.status = BatchStatus::Completed;
        batch.completed_at = Some(Utc::now());
        batch.records_upserted = (stats.inserted + stats.updated) as i64;
        batch.records_skipped = stats.skipped as i64;
        Ok(())
    }

    async fn fail(&self, id: Uuid, error: &str) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        let batch = store.get_mut(&id).ok_or(loseit_core::CoreError::NotFound)?;
        batch.status = BatchStatus::Failed;
        batch.completed_at = Some(Utc::now());
        batch.error = Some(error.to_string());
        Ok(())
    }
}
