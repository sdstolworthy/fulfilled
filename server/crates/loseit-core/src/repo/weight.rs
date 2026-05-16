use async_trait::async_trait;
use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::{Weight, WeightDraft};
use crate::CoreResult;

#[async_trait]
pub trait WeightRepository: Send + Sync + 'static {
    async fn create(&self, user_id: Uuid, draft: &WeightDraft) -> CoreResult<Weight>;

    async fn list_for_user(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<Vec<Weight>>;

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()>;
}
