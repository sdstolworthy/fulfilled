use std::collections::HashMap;

use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::{Food, FoodDraft, FoodPatch, FoodSearchHit};
use crate::CoreResult;

/// Sentinel name used to identify the internal "Quick Add" food that is
/// created automatically for each user. This food should never be visible in
/// user-facing food listings.
pub const QUICK_ADD_SENTINEL_NAME: &str = "__quick_add__";

/// Per-batch upsert counters returned by `upsert_off_batch`. Inserted vs.
/// updated are distinguished by the repo via the `(xmax = 0)` Postgres
/// trick or via `RETURNING (xmax = 0)` — the trait just receives the
/// counts.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UpsertStats {
    pub inserted: u64,
    pub updated: u64,
    pub skipped: u64,
}

/// Record shape consumed by `upsert_off_batch`. This is the *normalized*
/// view ingest hands to the storage layer: per-100g nutrition,
/// quality-score, plus the two intended servings to materialize. We keep
/// this in core (rather than the ingest binary) because the repo trait
/// signature needs to refer to it, and core has no I/O dependencies.
#[derive(Debug, Clone)]
pub struct OffFoodUpsert {
    pub draft: FoodDraft,
    pub quality_score: i16,
    pub off_serving: Option<OffServing>,
    pub system_100g_serving: SystemServing,
}

#[derive(Debug, Clone)]
pub struct OffServing {
    pub label: String,
    pub grams: rust_decimal::Decimal,
}

#[derive(Debug, Clone)]
pub struct SystemServing {
    pub label: String,
    pub grams: rust_decimal::Decimal,
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

    async fn create_custom(&self, owner: Uuid, draft: &FoodDraft) -> CoreResult<Food>;

    async fn update_custom(&self, owner: Uuid, id: Uuid, patch: &FoodPatch) -> CoreResult<Food>;

    async fn delete_custom(&self, owner: Uuid, id: Uuid) -> CoreResult<()>;

    /// Upsert a chunk of OFF records under the given batch. The trait does
    /// not specify whether this is one SQL round-trip or many — the sqlx
    /// implementation uses `UNNEST` for a single statement; in-memory
    /// fakes loop.
    async fn upsert_off_batch(
        &self,
        batch_id: Uuid,
        records: &[OffFoodUpsert],
    ) -> CoreResult<UpsertStats>;

    /// Bulk lookup of food ids by barcode for the given viewer. Returns a
    /// map keyed by the barcode; barcodes that don't resolve to a visible
    /// food are simply absent from the result. Used by the ingest service
    /// to wire up servings after `upsert_off_batch` without paying N
    /// round-trips per chunk.
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
}
