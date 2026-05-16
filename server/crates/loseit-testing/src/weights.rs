use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{NaiveDate, Utc};
use loseit_core::domain::{Weight, WeightDraft};
use loseit_core::repo::WeightRepository;
use loseit_core::CoreResult;
use uuid::Uuid;

#[derive(Default)]
pub struct InMemoryWeightRepository {
    by_id: Mutex<HashMap<Uuid, Weight>>,
}

impl InMemoryWeightRepository {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl WeightRepository for InMemoryWeightRepository {
    async fn create(&self, user_id: Uuid, draft: &WeightDraft) -> CoreResult<Weight> {
        let weight = Weight {
            id: Uuid::new_v4(),
            user_id,
            recorded_on: draft.recorded_on,
            recorded_at_local: draft.recorded_at_local,
            weight_kg: draft.weight_kg,
            note: draft.note.clone(),
            created_at: Utc::now(),
        };
        self.by_id.lock().unwrap().insert(weight.id, weight.clone());
        Ok(weight)
    }

    async fn list_paginated(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<Weight>> {
        let store = self.by_id.lock().unwrap();
        let mut out: Vec<Weight> = store
            .values()
            .filter(|w| {
                w.user_id == user_id
                    && from.map_or(true, |d| w.recorded_on >= d)
                    && to.map_or(true, |d| w.recorded_on <= d)
            })
            .cloned()
            .collect();
        // Mirror the Postgres ORDER BY recorded_on DESC, created_at DESC, id DESC.
        out.sort_by(|a, b| {
            b.recorded_on
                .cmp(&a.recorded_on)
                .then(b.created_at.cmp(&a.created_at))
                .then(b.id.cmp(&a.id))
        });
        let skip = (offset as usize).min(out.len());
        let take = (limit as usize).min(out.len().saturating_sub(skip));
        Ok(out[skip..skip + take].to_vec())
    }

    async fn count_for_user(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<i64> {
        let store = self.by_id.lock().unwrap();
        let count = store
            .values()
            .filter(|w| {
                w.user_id == user_id
                    && from.map_or(true, |d| w.recorded_on >= d)
                    && to.map_or(true, |d| w.recorded_on <= d)
            })
            .count();
        Ok(count as i64)
    }

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        match store.get(&id) {
            Some(w) if w.user_id == user_id => {
                store.remove(&id);
                Ok(())
            }
            _ => Err(loseit_core::CoreError::NotFound),
        }
    }
}
