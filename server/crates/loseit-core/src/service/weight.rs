use std::sync::Arc;

use chrono::NaiveDate;
use uuid::Uuid;

use crate::domain::{Weight, WeightDraft};
use crate::repo::WeightRepository;
use crate::service::page::{resolve_page_params, Paginated};
use crate::{CoreError, CoreResult};

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
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> CoreResult<Paginated<Weight>> {
        if let (Some(f), Some(t)) = (from, to) {
            if f > t {
                return Err(CoreError::Validation("`from` must be <= `to`".into()));
            }
        }
        let page = resolve_page_params(limit, offset)?;
        let results = self
            .weights
            .list_paginated(user_id, from, to, page.limit, page.offset)
            .await?;
        let total = self.weights.count_for_user(user_id, from, to).await?;
        Ok(Paginated {
            results,
            total,
            limit: page.limit,
            offset: page.offset,
        })
    }

    #[tracing::instrument(skip(self))]
    pub async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        self.weights.delete(user_id, id).await
    }
}
