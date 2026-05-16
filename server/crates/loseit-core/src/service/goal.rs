use std::sync::Arc;

use chrono::{Duration, NaiveDate};
use uuid::Uuid;

use crate::domain::{Goal, GoalDraft, GoalPatch};
use crate::repo::GoalRepository;
use crate::CoreResult;

pub struct GoalService {
    goals: Arc<dyn GoalRepository>,
}

impl GoalService {
    pub fn new(goals: Arc<dyn GoalRepository>) -> Self {
        Self { goals }
    }

    /// Create a goal. If another open-ended goal exists, it is closed the
    /// day before the new goal starts, preserving an unbroken history.
    #[tracing::instrument(skip(self, draft), fields(starts_on = %draft.starts_on))]
    pub async fn create(&self, user_id: Uuid, draft: GoalDraft) -> CoreResult<Goal> {
        let closes_on = draft.starts_on - Duration::days(1);
        self.goals
            .create_succeeding(user_id, closes_on, &draft)
            .await
    }

    #[tracing::instrument(skip(self))]
    pub async fn list(&self, user_id: Uuid) -> CoreResult<Vec<Goal>> {
        self.goals.list_for_user(user_id).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn active_on(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Goal> {
        self.goals
            .find_active_on(user_id, on)
            .await?
            .ok_or(crate::CoreError::NotFound)
    }

    #[tracing::instrument(skip(self, patch))]
    pub async fn update(&self, user_id: Uuid, id: Uuid, patch: GoalPatch) -> CoreResult<Goal> {
        self.goals.update(user_id, id, &patch).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        self.goals.delete(user_id, id).await
    }
}
