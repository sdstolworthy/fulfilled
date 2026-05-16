use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::{FoodLogEntry, PersistedLogEntry, PersistedLogPatch};
use crate::CoreResult;

#[async_trait]
pub trait LogRepository: Send + Sync + 'static {
    async fn create(&self, user_id: Uuid, entry: &PersistedLogEntry) -> CoreResult<FoodLogEntry>;

    async fn update(
        &self,
        user_id: Uuid,
        id: Uuid,
        patch: &PersistedLogPatch,
    ) -> CoreResult<FoodLogEntry>;

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()>;

    async fn find_by_id(&self, user_id: Uuid, id: Uuid) -> CoreResult<Option<FoodLogEntry>>;

    async fn list_in_range(
        &self,
        user_id: Uuid,
        from: NaiveDate,
        to: NaiveDate,
    ) -> CoreResult<Vec<FoodLogEntry>>;

    async fn list_for_day(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Vec<FoodLogEntry>>;

    /// Distinct food_ids the user has logged, most recent first.
    async fn recent_food_ids(&self, user_id: Uuid, limit: i64) -> CoreResult<Vec<Uuid>>;

    /// `(food_id, count)` for entries with `consumed_on >= today - window_days`,
    /// ordered by count desc.
    async fn frequent_food_ids(
        &self,
        user_id: Uuid,
        window_days: i64,
        limit: i64,
    ) -> CoreResult<Vec<(Uuid, i64)>>;

    /// True iff any entry references the given food. Used by the food
    /// service to surface a clean conflict before attempting a delete.
    async fn any_entry_references_food(&self, food_id: Uuid) -> CoreResult<bool>;

    /// Paginated list of log entries for the given user, optionally filtered
    /// by date range. Results are ordered `consumed_on DESC, created_at DESC,
    /// id DESC` for stable cursor-compatible pagination.
    async fn list_paginated(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodLogEntry>>;

    /// Total count of log entries for `user_id` matching the optional date
    /// range. Used alongside [`list_paginated`] to populate `Paginated::total`.
    async fn count_in_range(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<i64>;
}
