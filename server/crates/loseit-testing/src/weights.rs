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

    async fn list_for_user(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<Vec<Weight>> {
        let store = self.by_id.lock().unwrap();
        let mut out: Vec<Weight> = store
            .values()
            .filter(|w| w.user_id == user_id)
            .filter(|w| from.map_or(true, |d| w.recorded_on >= d))
            .filter(|w| to.map_or(true, |d| w.recorded_on <= d))
            .cloned()
            .collect();
        out.sort_by(|a, b| {
            b.recorded_on
                .cmp(&a.recorded_on)
                .then(b.created_at.cmp(&a.created_at))
        });
        Ok(out)
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
