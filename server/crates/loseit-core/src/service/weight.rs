use std::sync::Arc;

use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::{Weight, WeightDraft};
use crate::repo::WeightRepository;
use crate::CoreResult;

pub struct WeightService {
    weights: Arc<dyn WeightRepository>,
}

impl WeightService {
    pub fn new(weights: Arc<dyn WeightRepository>) -> Self {
        Self { weights }
    }

    #[tracing::instrument(skip(self, draft))]
    pub async fn record(&self, user_id: Uuid, draft: WeightDraft) -> CoreResult<Weight> {
        self.weights.create(user_id, &draft).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn list(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<Vec<Weight>> {
        self.weights.list_for_user(user_id, from, to).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        self.weights.delete(user_id, id).await
    }
}
