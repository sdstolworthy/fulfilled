use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::{Goal, GoalDraft, GoalPatch};
use crate::CoreResult;

#[async_trait]
pub trait GoalRepository: Send + Sync + 'static {
    async fn create(&self, user_id: Uuid, draft: &GoalDraft) -> CoreResult<Goal>;

    /// Close the previously open-ended goal (if any) on `closes_on`, then
    /// insert the new draft. Implemented as a single transaction so we
    /// never end up with two open-ended goals.
    async fn create_succeeding(
        &self,
        user_id: Uuid,
        closes_on: NaiveDate,
        draft: &GoalDraft,
    ) -> CoreResult<Goal>;

    async fn list_for_user(&self, user_id: Uuid) -> CoreResult<Vec<Goal>>;

    async fn find_active_on(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Option<Goal>>;

    async fn update(&self, user_id: Uuid, id: Uuid, patch: &GoalPatch) -> CoreResult<Goal>;

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()>;
}
