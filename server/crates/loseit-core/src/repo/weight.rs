use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::{Weight, WeightDraft};
use crate::CoreResult;

#[async_trait]
pub trait WeightRepository: Send + Sync + 'static {
    async fn create(&self, user_id: Uuid, draft: &WeightDraft) -> CoreResult<Weight>;

    /// Paginated list of weight entries for the given user, optionally filtered
    /// by date range. Results are ordered `recorded_on DESC, created_at DESC,
    /// id DESC` for stable cursor-compatible pagination.
    async fn list_paginated(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<Weight>>;

    /// Total count of weight entries for `user_id` matching the optional date
    /// range. Used alongside [`list_paginated`] to populate `Paginated::total`.
    async fn count_for_user(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<i64>;

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()>;
}
