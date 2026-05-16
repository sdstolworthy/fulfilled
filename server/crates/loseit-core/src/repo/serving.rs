use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::{Serving, ServingDraft, ServingPatch};
use crate::CoreResult;

#[async_trait]
pub trait ServingRepository: Send + Sync + 'static {
    async fn list_for_food(&self, food_id: Uuid) -> CoreResult<Vec<Serving>>;

    async fn find_by_id(&self, id: Uuid) -> CoreResult<Option<Serving>>;

    async fn create(&self, food_id: Uuid, draft: &ServingDraft) -> CoreResult<Serving>;

    async fn update(&self, id: Uuid, patch: &ServingPatch) -> CoreResult<Serving>;

    /// Atomic default-flip. Clears any existing default for `food_id` and
    /// sets the named serving as the new default in a single transaction.
    /// The schema's partial unique index on `(food_id) WHERE is_default`
    /// requires this ordering.
    async fn set_default(&self, food_id: Uuid, serving_id: Uuid) -> CoreResult<()>;

    /// Refuses to delete the current default with `CoreError::Conflict`.
    async fn delete(&self, id: Uuid) -> CoreResult<()>;
}
