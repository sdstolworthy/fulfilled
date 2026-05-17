use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::Utc;
use loseit_core::domain::{Serving, ServingDraft, ServingPatch, ServingSource};
use loseit_core::domain::unit::Unit;
use loseit_core::repo::ServingRepository;
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Default)]
pub struct InMemoryServingRepository {
    by_id: Mutex<HashMap<Uuid, Serving>>,
}

impl InMemoryServingRepository {
    pub fn new() -> Self {
        Self::default()
    }

    /// Atomic find-or-insert of the sentinel serving for a quick-add food:
    /// `{amount: 1, unit: Serving, kcal: 1.0, source: System, is_default: true}`.
    /// Used by [`InMemoryFoodRepository::find_or_create_quick_add`] to mirror
    /// the Pg `INSERT ... ON CONFLICT` against `servings_one_default_per_food`.
    ///
    /// The full check-and-insert happens under a single lock acquisition so
    /// two concurrent quick-add provisions on the same food converge on one
    /// serving row.
    pub(crate) fn find_or_create_sentinel_serving_for_food(&self, food_id: Uuid) -> Serving {
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
            label: None,
            amount: Decimal::from(1),
            unit: Unit::Serving,
            kcal: Decimal::from(1),
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sugar_g: None,
            sodium_mg: None,
            saturated_fat_g: None,
            is_default: true,
            source: ServingSource::System,
            sort_order: 0,
            created_at: now,
            updated_at: now,
        };
        store.insert(serving.id, serving.clone());
        serving
    }

    /// Drop all existing servings for `food_id` and insert the provided list.
    /// Used by `update_custom_with_servings` and `upsert_external_food_batch`
    /// to perform the full-list-replace operation.
    pub(crate) async fn replace_all_for_food(
        &self,
        food_id: Uuid,
        new_servings: &[ServingDraft],
    ) -> CoreResult<()> {
        let now = Utc::now();
        let mut store = self.by_id.lock().unwrap();
        // Drop all existing servings for this food.
        store.retain(|_, s| s.food_id != food_id);
        // Insert the new list.
        for s in new_servings {
            let serving = Serving {
                id: Uuid::new_v4(),
                food_id,
                label: s.label.clone(),
                amount: s.amount,
                unit: s.unit,
                kcal: s.kcal,
                protein_g: s.protein_g,
                carbs_g: s.carbs_g,
                fat_g: s.fat_g,
                fiber_g: s.fiber_g,
                sugar_g: s.sugar_g,
                sodium_mg: s.sodium_mg,
                saturated_fat_g: s.saturated_fat_g,
                is_default: s.is_default,
                source: s.source,
                sort_order: s.sort_order,
                created_at: now,
                updated_at: now,
            };
            store.insert(serving.id, serving);
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
            amount: draft.amount,
            unit: draft.unit,
            kcal: draft.kcal,
            protein_g: draft.protein_g,
            carbs_g: draft.carbs_g,
            fat_g: draft.fat_g,
            fiber_g: draft.fiber_g,
            sugar_g: draft.sugar_g,
            sodium_mg: draft.sodium_mg,
            saturated_fat_g: draft.saturated_fat_g,
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
        if let Some(v) = patch.amount {
            serving.amount = v;
        }
        if let Some(v) = patch.unit {
            serving.unit = v;
        }
        if let Some(v) = patch.kcal {
            serving.kcal = v;
        }
        if let Some(v) = &patch.protein_g {
            serving.protein_g = *v;
        }
        if let Some(v) = &patch.carbs_g {
            serving.carbs_g = *v;
        }
        if let Some(v) = &patch.fat_g {
            serving.fat_g = *v;
        }
        if let Some(v) = &patch.fiber_g {
            serving.fiber_g = *v;
        }
        if let Some(v) = &patch.sugar_g {
            serving.sugar_g = *v;
        }
        if let Some(v) = &patch.sodium_mg {
            serving.sodium_mg = *v;
        }
        if let Some(v) = &patch.saturated_fat_g {
            serving.saturated_fat_g = *v;
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
