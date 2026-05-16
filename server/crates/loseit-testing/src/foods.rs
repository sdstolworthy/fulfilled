use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::Utc;
use loseit_core::domain::{
    Food, FoodDraft, FoodPatch, FoodSearchHit, FoodSource, Serving, ServingPreview,
};
use loseit_core::repo::{
    FoodRepository, LogRepository, OffFoodUpsert, ServingRepository, UpsertStats,
};
use loseit_core::CoreResult;
use uuid::Uuid;

use crate::logs::InMemoryLogRepository;
use crate::servings::InMemoryServingRepository;

/// In-memory implementation of [`FoodRepository`]. Pair with
/// [`InMemoryServingRepository`] to materialize servings when ingesting OFF
/// batches; pair with [`InMemoryLogRepository`] (via
/// [`InMemoryFoodRepository::set_log_repo_for_delete_check`]) to surface
/// the same `Conflict` on `delete_custom` that the SQL FK-restrict produces
/// in production.
#[derive(Default)]
pub struct InMemoryFoodRepository {
    by_id: Mutex<HashMap<Uuid, Food>>,
    servings: Mutex<Option<Arc<InMemoryServingRepository>>>,
    log_repo: Mutex<Option<Arc<InMemoryLogRepository>>>,
}

impl InMemoryFoodRepository {
    pub fn new() -> Self {
        Self::default()
    }

    /// Wire the serving repo so `upsert_off_batch` can also (re)materialize
    /// the per-100g + OFF servings for each food. Optional — leaving this
    /// unset just skips the serving side-effect.
    pub fn set_serving_repo(&self, servings: Arc<InMemoryServingRepository>) {
        *self.servings.lock().unwrap() = Some(servings);
    }

    /// Wire a log repo so `delete_custom` can refuse with `Conflict` when
    /// the food is still referenced by log entries. Optional.
    pub fn set_log_repo_for_delete_check(&self, log: Arc<InMemoryLogRepository>) {
        *self.log_repo.lock().unwrap() = Some(log);
    }
}

fn is_visible(food: &Food, viewer: Uuid) -> bool {
    match food.source {
        FoodSource::Off | FoodSource::Usda => true,
        FoodSource::User => food.owner_user_id == Some(viewer),
    }
}

fn hit_from(food: &Food, default_serving: Option<Serving>) -> FoodSearchHit {
    // The fake doesn't compute `calories_per_serving` — it's only used by
    // tests that exercise pagination / visibility, not nutrition rendering.
    FoodSearchHit {
        id: food.id,
        source: food.source,
        name: food.name.clone(),
        brand: food.brands.clone(),
        barcode: food.barcode.clone(),
        default_serving: default_serving.map(|s| ServingPreview {
            id: s.id,
            label: s.label,
            grams: s.grams,
        }),
        calories_per_serving: None,
    }
}

#[async_trait]
impl FoodRepository for InMemoryFoodRepository {
    async fn find_by_id(&self, viewer: Uuid, id: Uuid) -> CoreResult<Option<Food>> {
        let store = self.by_id.lock().unwrap();
        Ok(store.get(&id).filter(|f| is_visible(f, viewer)).cloned())
    }

    async fn find_by_barcode(&self, viewer: Uuid, barcode: &str) -> CoreResult<Option<Food>> {
        let store = self.by_id.lock().unwrap();
        Ok(store
            .values()
            .find(|f| f.barcode.as_deref() == Some(barcode) && is_visible(f, viewer))
            .cloned())
    }

    async fn search(
        &self,
        viewer: Uuid,
        q: &str,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodSearchHit>> {
        let needle = q.to_lowercase();
        let foods: Vec<Food> = {
            let store = self.by_id.lock().unwrap();
            let mut matches: Vec<Food> = store
                .values()
                .filter(|f| is_visible(f, viewer))
                .filter(|f| {
                    let mut haystack = f.name.to_lowercase();
                    if let Some(b) = &f.brands {
                        haystack.push(' ');
                        haystack.push_str(&b.to_lowercase());
                    }
                    haystack.contains(&needle)
                })
                .cloned()
                .collect();
            matches.sort_by(|a, b| {
                a.name
                    .len()
                    .cmp(&b.name.len())
                    .then(b.quality_score.cmp(&a.quality_score))
                    .then(a.id.cmp(&b.id))
            });
            matches
        };

        let servings_guard = self.servings.lock().unwrap().clone();

        let mut out: Vec<FoodSearchHit> = Vec::new();
        let skip = offset.max(0) as usize;
        let take = limit.max(0) as usize;
        for food in foods.into_iter().skip(skip).take(take) {
            let default_serving = match &servings_guard {
                Some(repo) => repo
                    .list_for_food(food.id)
                    .await?
                    .into_iter()
                    .find(|s| s.is_default),
                None => None,
            };
            out.push(hit_from(&food, default_serving));
        }
        Ok(out)
    }

    async fn search_count(&self, viewer: Uuid, q: &str) -> CoreResult<i64> {
        let needle = q.to_lowercase();
        let store = self.by_id.lock().unwrap();
        let n = store
            .values()
            .filter(|f| is_visible(f, viewer))
            .filter(|f| {
                let mut haystack = f.name.to_lowercase();
                if let Some(b) = &f.brands {
                    haystack.push(' ');
                    haystack.push_str(&b.to_lowercase());
                }
                haystack.contains(&needle)
            })
            .count();
        Ok(n as i64)
    }

    async fn create_custom(&self, owner: Uuid, draft: &FoodDraft) -> CoreResult<Food> {
        let now = Utc::now();
        let food = Food {
            id: Uuid::new_v4(),
            source: FoodSource::User,
            owner_user_id: Some(owner),
            barcode: draft.barcode.clone(),
            fdc_id: None,
            data_type: None,
            name: draft.name.clone(),
            brands: draft.brands.clone(),
            categories_tags: draft.categories_tags.clone(),
            nutrition: draft.nutrition.clone(),
            nutriscore_grade: draft.nutriscore_grade,
            quality_score: 0,
            extra_nutrients: None,
            last_import_batch_id: None,
            created_at: now,
            updated_at: now,
        };
        self.by_id.lock().unwrap().insert(food.id, food.clone());
        Ok(food)
    }

    async fn update_custom(&self, owner: Uuid, id: Uuid, patch: &FoodPatch) -> CoreResult<Food> {
        let mut store = self.by_id.lock().unwrap();
        let food = store.get_mut(&id).ok_or(loseit_core::CoreError::NotFound)?;
        if food.source != FoodSource::User || food.owner_user_id != Some(owner) {
            return Err(loseit_core::CoreError::NotFound);
        }
        if let Some(v) = &patch.name {
            food.name = v.clone();
        }
        if let Some(v) = &patch.brands {
            food.brands = Some(v.clone());
        }
        if let Some(v) = &patch.barcode {
            food.barcode = Some(v.clone());
        }
        if let Some(v) = &patch.categories_tags {
            food.categories_tags = v.clone();
        }
        if let Some(v) = &patch.nutrition {
            food.nutrition = v.clone();
        }
        if let Some(v) = patch.nutriscore_grade {
            food.nutriscore_grade = Some(v);
        }
        food.updated_at = Utc::now();
        Ok(food.clone())
    }

    async fn delete_custom(&self, owner: Uuid, id: Uuid) -> CoreResult<()> {
        let log_repo = self.log_repo.lock().unwrap().clone();
        {
            let store = self.by_id.lock().unwrap();
            let food = store.get(&id).ok_or(loseit_core::CoreError::NotFound)?;
            if food.source != FoodSource::User || food.owner_user_id != Some(owner) {
                return Err(loseit_core::CoreError::NotFound);
            }
        }
        if let Some(log) = log_repo {
            if log.any_entry_references_food(id).await? {
                return Err(loseit_core::CoreError::Conflict(
                    "food is referenced by log entries".to_string(),
                ));
            }
        }
        self.by_id.lock().unwrap().remove(&id);
        Ok(())
    }

    async fn find_ids_by_barcodes(
        &self,
        viewer: Uuid,
        barcodes: &[&str],
    ) -> CoreResult<HashMap<String, Uuid>> {
        let store = self.by_id.lock().unwrap();
        let mut out = HashMap::with_capacity(barcodes.len());
        for bc in barcodes {
            if let Some(food) = store
                .values()
                .find(|f| f.barcode.as_deref() == Some(*bc) && is_visible(f, viewer))
            {
                out.insert((*bc).to_string(), food.id);
            }
        }
        Ok(out)
    }

    async fn upsert_off_batch(
        &self,
        batch_id: Uuid,
        records: &[OffFoodUpsert],
    ) -> CoreResult<UpsertStats> {
        let mut stats = UpsertStats::default();
        let mut materialize: Vec<(Uuid, &OffFoodUpsert)> = Vec::with_capacity(records.len());
        {
            let mut store = self.by_id.lock().unwrap();
            for rec in records {
                let now = Utc::now();
                let existing_id = rec.draft.barcode.as_ref().and_then(|bc| {
                    store
                        .values()
                        .find(|f| f.source == FoodSource::Off && f.barcode.as_deref() == Some(bc))
                        .map(|f| f.id)
                });
                match existing_id {
                    Some(id) => {
                        let food = store.get_mut(&id).expect("existing id missing");
                        food.name = rec.draft.name.clone();
                        food.brands = rec.draft.brands.clone();
                        food.categories_tags = rec.draft.categories_tags.clone();
                        food.nutrition = rec.draft.nutrition.clone();
                        food.nutriscore_grade = rec.draft.nutriscore_grade;
                        food.quality_score = rec.quality_score;
                        food.last_import_batch_id = Some(batch_id);
                        food.updated_at = now;
                        stats.updated += 1;
                        materialize.push((id, rec));
                    }
                    None => {
                        let food = Food {
                            id: Uuid::new_v4(),
                            source: FoodSource::Off,
                            owner_user_id: None,
                            barcode: rec.draft.barcode.clone(),
                            fdc_id: None,
                            data_type: None,
                            name: rec.draft.name.clone(),
                            brands: rec.draft.brands.clone(),
                            categories_tags: rec.draft.categories_tags.clone(),
                            nutrition: rec.draft.nutrition.clone(),
                            nutriscore_grade: rec.draft.nutriscore_grade,
                            quality_score: rec.quality_score,
                            extra_nutrients: None,
                            last_import_batch_id: Some(batch_id),
                            created_at: now,
                            updated_at: now,
                        };
                        let id = food.id;
                        store.insert(id, food);
                        stats.inserted += 1;
                        materialize.push((id, rec));
                    }
                }
            }
        }

        let servings = self.servings.lock().unwrap().clone();
        if let Some(servings) = servings {
            for (food_id, rec) in materialize {
                servings.replace_for_food_with_off(food_id, rec).await?;
            }
        }
        Ok(stats)
    }
}
