use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::Utc;
use loseit_core::domain::{Serving, ServingDraft, ServingPatch, ServingSource};
use loseit_core::repo::{OffFoodUpsert, ServingRepository};
use loseit_core::CoreResult;
use uuid::Uuid;

#[derive(Default)]
pub struct InMemoryServingRepository {
    by_id: Mutex<HashMap<Uuid, Serving>>,
}

impl InMemoryServingRepository {
    pub fn new() -> Self {
        Self::default()
    }

    /// Atomic find-or-insert of the default 100 g `kcal` serving for a food,
    /// used by [`InMemoryFoodRepository::find_or_create_quick_add`] to mirror
    /// the Pg `INSERT ... ON CONFLICT` against the `servings_one_default_per_food`
    /// partial unique index.
    ///
    /// The full check-and-insert happens under a single lock acquisition so
    /// two concurrent quick-add provisions on the same food converge on one
    /// serving row, matching the Pg guarantee. Without this, the two-step
    /// `list_for_food` → `create` pattern releases the serving-store lock
    /// between steps and races under multi-threaded runtimes.
    pub(crate) fn find_or_create_default_kcal_for_food(&self, food_id: Uuid) -> Serving {
        let mut store = self.by_id.lock().unwrap();
        if let Some(existing) = store
            .values()
            .find(|s| s.food_id == food_id && s.is_default)
        {
            return existing.clone();
        }
        let now = Utc::now();
        let serving = Serving {
            id: Uuid::new_v4(),
            food_id,
            label: "kcal".to_string(),
            grams: rust_decimal::Decimal::from(100),
            is_default: true,
            source: ServingSource::System,
            sort_order: 0,
            created_at: now,
            updated_at: now,
        };
        store.insert(serving.id, serving.clone());
        serving
    }

    /// Clear all servings for a food and replace with the system-100g plus
    /// optional OFF-specific serving derived from an `OffFoodUpsert`. Used
    /// by [`InMemoryFoodRepository::upsert_off_batch`].
    pub(crate) async fn replace_for_food_with_off(
        &self,
        food_id: Uuid,
        rec: &OffFoodUpsert,
    ) -> CoreResult<()> {
        let now = Utc::now();
        let mut store = self.by_id.lock().unwrap();
        store.retain(|_, s| s.food_id != food_id);

        let off_present = rec.off_serving.is_some();
        let mut sort_order = 0i32;

        let system = Serving {
            id: Uuid::new_v4(),
            food_id,
            label: rec.system_100g_serving.label.clone(),
            grams: rec.system_100g_serving.grams,
            // Default to the system 100g serving when there is no OFF serving.
            is_default: !off_present,
            source: ServingSource::System,
            sort_order,
            created_at: now,
            updated_at: now,
        };
        store.insert(system.id, system);
        sort_order += 1;

        if let Some(off) = &rec.off_serving {
            let off_serving = Serving {
                id: Uuid::new_v4(),
                food_id,
                label: off.label.clone(),
                grams: off.grams,
                is_default: true,
                source: ServingSource::Off,
                sort_order,
                created_at: now,
                updated_at: now,
            };
            store.insert(off_serving.id, off_serving);
        }
        Ok(())
    }
}

#[async_trait]
impl ServingRepository for InMemoryServingRepository {
    async fn list_for_food(&self, food_id: Uuid) -> CoreResult<Vec<Serving>> {
        let store = self.by_id.lock().unwrap();
        let mut out: Vec<Serving> = store
            .values()
            .filter(|s| s.food_id == food_id)
            .cloned()
            .collect();
        out.sort_by(|a, b| a.sort_order.cmp(&b.sort_order).then(a.id.cmp(&b.id)));
        Ok(out)
    }

    async fn find_by_id(&self, id: Uuid) -> CoreResult<Option<Serving>> {
        Ok(self.by_id.lock().unwrap().get(&id).cloned())
    }

    async fn create(&self, food_id: Uuid, draft: &ServingDraft) -> CoreResult<Serving> {
        let mut store = self.by_id.lock().unwrap();
        let now = Utc::now();
        // Honor the partial-unique invariant: at most one default per food.
        if draft.is_default {
            for s in store.values_mut() {
                if s.food_id == food_id && s.is_default {
                    s.is_default = false;
                    s.updated_at = now;
                }
            }
        }
        let serving = Serving {
            id: Uuid::new_v4(),
            food_id,
            label: draft.label.clone(),
            grams: draft.grams,
            is_default: draft.is_default,
            source: draft.source,
            sort_order: draft.sort_order,
            created_at: now,
            updated_at: now,
        };
        store.insert(serving.id, serving.clone());
        Ok(serving)
    }

    async fn update(&self, id: Uuid, patch: &ServingPatch) -> CoreResult<Serving> {
        let mut store = self.by_id.lock().unwrap();
        let serving = store.get_mut(&id).ok_or(loseit_core::CoreError::NotFound)?;
        if let Some(v) = &patch.label {
            serving.label = v.clone();
        }
        if let Some(v) = patch.grams {
            serving.grams = v;
        }
        if let Some(v) = patch.sort_order {
            serving.sort_order = v;
        }
        serving.updated_at = Utc::now();
        Ok(serving.clone())
    }

    async fn set_default(&self, food_id: Uuid, serving_id: Uuid) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        // Verify the target serving exists and belongs to this food before
        // mutating anything — otherwise we would leave the food with no
        // default after clearing the existing one.
        match store.get(&serving_id) {
            Some(s) if s.food_id == food_id => {}
            _ => return Err(loseit_core::CoreError::NotFound),
        }
        let now = Utc::now();
        for s in store.values_mut() {
            if s.food_id == food_id {
                let should_be_default = s.id == serving_id;
                if s.is_default != should_be_default {
                    s.is_default = should_be_default;
                    s.updated_at = now;
                }
            }
        }
        Ok(())
    }

    async fn delete(&self, id: Uuid) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        let serving = store.get(&id).ok_or(loseit_core::CoreError::NotFound)?;
        if serving.is_default {
            return Err(loseit_core::CoreError::Conflict(
                "cannot delete the default serving".to_string(),
            ));
        }
        store.remove(&id);
        Ok(())
    }
}
