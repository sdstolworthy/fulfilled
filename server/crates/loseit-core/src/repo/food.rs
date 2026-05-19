use std::collections::HashMap;

use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::{Food, FoodDraft, FoodPatch, FoodSearchHit, Serving, ServingDraft};
use crate::CoreResult;

/// Sentinel name used to identify the internal "Quick Add" food that is
/// created automatically for each user. This food should never be visible in
/// user-facing food listings.
pub const QUICK_ADD_SENTINEL_NAME: &str = "__quick_add__";

/// Per-batch upsert counters. Returned by `IngestService::run` and consumed
/// by `BatchRepository::finish`. No longer returned by the food repo itself
/// (which returns `()` on upsert). Kept here because `BatchRepository` imports
/// it from this module.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UpsertStats {
    pub inserted: u64,
    pub updated: u64,
    pub skipped: u64,
}

/// Record shape consumed by `upsert_external_food_batch`. This is the
/// *normalized* view ingest hands to the storage layer: a `FoodDraft` that
/// already carries `servings`, plus a `quality_score` that the ingest
/// normalizer computes and the food repo persists on the `foods` row.
#[derive(Debug, Clone)]
pub struct FoodDraftWithServings {
    pub draft: FoodDraft,
    pub quality_score: i16,
    pub servings: Vec<ServingDraft>,
}

/// Per-batch write outcome returned by `upsert_external_food_batch`. The
/// repo skips rows that fail at the SQL layer (foreign key, check
/// constraint, etc.) and surfaces a count of skips so the caller can
/// bump `food_import_batches.records_skipped` for the batch.
///
/// Phase 1.5: per-row failures used to abort the entire chunk via `?`
/// bubble; they now no-op the offending food and the batch carries on.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BatchWriteOutcome {
    /// Foods successfully upserted into the `foods` table together with
    /// their serving rows.
    pub upserted: u64,
    /// Foods that failed mid-write and were skipped. Each gets a
    /// `tracing::warn!` line; we don't surface them individually here
    /// because the batch counts are usually all the caller cares about.
    pub skipped: u64,
}

#[async_trait]
pub trait FoodRepository: Send + Sync + 'static {
    /// Visibility rule: OFF foods are visible to everyone; user-custom
    /// foods are visible only to their owner. Implementations return
    /// `Ok(None)` for the cross-tenant case (handler maps to 404 —
    /// indistinguishable from missing on purpose).
    async fn find_by_id(&self, viewer: Uuid, id: Uuid) -> CoreResult<Option<Food>>;

    async fn find_by_barcode(&self, viewer: Uuid, barcode: &str) -> CoreResult<Option<Food>>;

    async fn search(
        &self,
        viewer: Uuid,
        q: &str,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodSearchHit>>;

    async fn search_count(&self, viewer: Uuid, q: &str) -> CoreResult<i64>;

    /// Create a user-custom food together with its initial servings in a
    /// single transaction. At least one serving is required (service-validated
    /// before this is called).
    async fn create_custom_with_servings(
        &self,
        owner: Uuid,
        draft: &FoodDraft,
        servings: Vec<ServingDraft>,
    ) -> CoreResult<Food>;

    /// Update a user-custom food. When `servings` is `Some`, the existing
    /// serving list is replaced atomically (DELETE + INSERT in one txn).
    /// When `servings` is `None`, only the food metadata is patched.
    async fn update_custom_with_servings(
        &self,
        owner: Uuid,
        id: Uuid,
        patch: &FoodPatch,
        servings: Option<Vec<ServingDraft>>,
    ) -> CoreResult<Food>;

    async fn delete_custom(&self, owner: Uuid, id: Uuid) -> CoreResult<()>;

    /// Upsert a chunk of external (OFF / USDA) records. Per-food: UPSERT the
    /// food row, then atomically replace the serving list (DELETE + INSERT).
    /// Returns a [`BatchWriteOutcome`] with per-batch `(upserted, skipped)`
    /// counts so the caller can plumb them into `food_import_batches`.
    ///
    /// Phase 1.5: per-food failures are logged at WARN and counted as
    /// `skipped`; they no longer abort the whole batch.
    async fn upsert_external_food_batch(
        &self,
        batch_id: Uuid,
        batch: Vec<FoodDraftWithServings>,
    ) -> CoreResult<BatchWriteOutcome>;

    /// Bulk lookup of food ids by barcode for the given viewer. Returns a
    /// map keyed by the barcode; barcodes that don't resolve to a visible
    /// food are simply absent from the result.
    async fn find_ids_by_barcodes(
        &self,
        viewer: Uuid,
        barcodes: &[&str],
    ) -> CoreResult<HashMap<String, Uuid>>;

    /// Paginated list of the caller's user-custom foods. Excludes the
    /// `__quick_add__` sentinel. If `q` is `Some(s)`, filters to foods
    /// whose name or brands contain `s` (case-insensitive). Results are
    /// ordered `created_at DESC, id DESC` for stable pagination.
    async fn list_mine(
        &self,
        owner: Uuid,
        q: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodSearchHit>>;

    /// Count of user-custom foods matching the same predicates as
    /// `list_mine`, irrespective of pagination parameters.
    async fn count_mine(&self, owner: Uuid, q: Option<&str>) -> CoreResult<i64>;

    /// Idempotently provision the per-user quick-add sentinel food. Returns
    /// the food plus its synthetic `{amount: 1, unit: serving, kcal: 1}`
    /// default serving (source `system`). Safe under concurrent first-uses
    /// thanks to the `foods_quick_add_singleton` partial unique index.
    async fn find_or_create_quick_add(&self, owner: Uuid) -> CoreResult<(Food, Serving)>;
}
