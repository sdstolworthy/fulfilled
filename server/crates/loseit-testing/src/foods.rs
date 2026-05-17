use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::Utc;
use loseit_core::domain::{
    Food, FoodDraft, FoodKind, FoodPatch, FoodSearchHit, FoodSource, NutritionPer100g, Serving,
    ServingPreview, ServingSource,
};
use loseit_core::repo::food::QUICK_ADD_SENTINEL_NAME;
use loseit_core::repo::{
    FoodRepository, LogRepository, OffFoodUpsert, ServingRepository, UpsertStats,
};
use loseit_core::CoreResult;
use rust_decimal::Decimal;
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
                .filter(|f| f.name != QUICK_ADD_SENTINEL_NAME)
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
            .filter(|f| f.name != QUICK_ADD_SENTINEL_NAME)
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
            kind: FoodKind::Normal,
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

    async fn list_mine(
        &self,
        owner: Uuid,
        q: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodSearchHit>> {
        let needle = q
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_lowercase());
        let mut matches: Vec<Food> = {
            let store = self.by_id.lock().unwrap();
            store
                .values()
                .filter(|f| {
                    f.source == FoodSource::User
                        && f.owner_user_id == Some(owner)
                        && f.name != QUICK_ADD_SENTINEL_NAME
                })
                .filter(|f| match &needle {
                    None => true,
                    Some(n) => {
                        f.name.to_lowercase().contains(n.as_str())
                            || f.brands
                                .as_deref()
                                .unwrap_or("")
                                .to_lowercase()
                                .contains(n.as_str())
                    }
                })
                .cloned()
                .collect()
        };
        // Sort: created_at DESC, id DESC (stable pagination key).
        matches.sort_by(|a, b| {
            b.created_at
                .cmp(&a.created_at)
                .then_with(|| b.id.cmp(&a.id))
        });

        let servings_guard = self.servings.lock().unwrap().clone();
        let skip = offset.max(0) as usize;
        let take = limit.max(0) as usize;
        let mut out: Vec<FoodSearchHit> = Vec::new();
        for food in matches.into_iter().skip(skip).take(take) {
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

    async fn count_mine(&self, owner: Uuid, q: Option<&str>) -> CoreResult<i64> {
        let needle = q
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_lowercase());
        let store = self.by_id.lock().unwrap();
        let n = store
            .values()
            .filter(|f| {
                f.source == FoodSource::User
                    && f.owner_user_id == Some(owner)
                    && f.name != QUICK_ADD_SENTINEL_NAME
            })
            .filter(|f| match &needle {
                None => true,
                Some(n) => {
                    f.name.to_lowercase().contains(n.as_str())
                        || f.brands
                            .as_deref()
                            .unwrap_or("")
                            .to_lowercase()
                            .contains(n.as_str())
                }
            })
            .count();
        Ok(n as i64)
    }

    async fn find_or_create_quick_add(&self, owner: Uuid) -> CoreResult<(Food, Serving)> {
        // Idempotent: if a sentinel food already exists for `owner`, return
        // the existing pair. Otherwise create both the food and a synthetic
        // 100 g default serving. Mirrors the Pg `INSERT ... ON CONFLICT`
        // behaviour without the partial-unique index, by checking-then-
        // inserting under the food-store lock.
        //
        // The serving side-effect goes through the wired-in serving repo if
        // one is attached (mirroring `upsert_off_batch`'s `set_serving_repo`).
        // If no serving repo is attached, the fake synthesizes a Serving
        // value to return so callers see the same `(Food, Serving)` shape
        // as the Pg impl. Tests that exercise quick-add end-to-end attach
        // a serving repo.
        let now = Utc::now();
        let servings_guard = self.servings.lock().unwrap().clone();

        // Step 1: find-or-insert the sentinel food.
        let food = {
            let mut store = self.by_id.lock().unwrap();
            if let Some(existing) = store.values().find(|f| {
                f.source == FoodSource::User
                    && f.owner_user_id == Some(owner)
                    && f.name == QUICK_ADD_SENTINEL_NAME
            }) {
                existing.clone()
            } else {
                let food = Food {
                    id: Uuid::new_v4(),
                    source: FoodSource::User,
                    kind: FoodKind::QuickAdd,
                    owner_user_id: Some(owner),
                    barcode: None,
                    fdc_id: None,
                    data_type: None,
                    name: QUICK_ADD_SENTINEL_NAME.to_string(),
                    brands: None,
                    categories_tags: Vec::new(),
                    nutrition: NutritionPer100g {
                        energy_kcal: Some(Decimal::from(1)),
                        protein_g: None,
                        carbs_g: None,
                        fat_g: None,
                        fiber_g: None,
                        sugar_g: None,
                        sodium_g: None,
                        saturated_fat_g: None,
                    },
                    nutriscore_grade: None,
                    quality_score: 0,
                    extra_nutrients: None,
                    last_import_batch_id: None,
                    created_at: now,
                    updated_at: now,
                };
                store.insert(food.id, food.clone());
                food
            }
        };

        // Step 2: find-or-insert the default 100 g serving. The
        // `find_or_create_default_kcal_for_food` helper performs the
        // check-and-insert atomically under a single serving-store lock
        // acquisition, mirroring the Pg `ON CONFLICT` against
        // `servings_one_default_per_food`. The previous implementation
        // released the lock between `list_for_food` and `create`, which made
        // concurrent first-uses racy under multi-threaded runtimes.
        let serving = if let Some(servings) = servings_guard {
            servings.find_or_create_default_kcal_for_food(food.id)
        } else {
            // No serving repo wired in — synthesize a Serving so callers can
            // still rely on the `(Food, Serving)` shape. This matches the
            // Pg impl which always returns a real serving row.
            Serving {
                id: Uuid::new_v4(),
                food_id: food.id,
                label: "kcal".to_string(),
                grams: Decimal::from(100),
                is_default: true,
                source: ServingSource::System,
                sort_order: 0,
                created_at: now,
                updated_at: now,
            }
        };

        Ok((food, serving))
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
                            kind: FoodKind::Normal,
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
