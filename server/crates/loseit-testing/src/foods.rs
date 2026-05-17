use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::Utc;
use loseit_core::domain::{
    Food, FoodDraft, FoodKind, FoodPatch, FoodSearchHit, FoodSource, Serving, ServingDraft,
    ServingPreview, ServingSource,
};
use loseit_core::domain::unit::Unit;
use loseit_core::repo::food::{FoodDraftWithServings, QUICK_ADD_SENTINEL_NAME};
use loseit_core::repo::{FoodRepository, LogRepository, ServingRepository};
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::logs::InMemoryLogRepository;
use crate::servings::InMemoryServingRepository;

/// In-memory implementation of [`FoodRepository`]. Pair with
/// [`InMemoryServingRepository`] to materialize servings when ingesting
/// external batches; pair with [`InMemoryLogRepository`] (via
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

    /// Wire the serving repo so `create_custom_with_servings`,
    /// `update_custom_with_servings`, and `upsert_external_food_batch` can
    /// materialize serving rows. Optional — leaving this unset skips the
    /// serving side-effect.
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
            amount: s.amount,
            unit: s.unit,
            kcal: s.kcal,
        }),
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

    /// Create a user-custom food together with its initial servings. Enforces
    /// at least one serving. Mirrors the Pg transactional INSERT + INSERT.
    async fn create_custom_with_servings(
        &self,
        owner: Uuid,
        draft: &FoodDraft,
        servings: Vec<ServingDraft>,
    ) -> CoreResult<Food> {
        if servings.is_empty() {
            return Err(loseit_core::CoreError::Validation(
                "at least one serving required".into(),
            ));
        }
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
            nutriscore_grade: draft.nutriscore_grade,
            quality_score: 0,
            extra_nutrients: None,
            last_import_batch_id: None,
            created_at: now,
            updated_at: now,
        };
        self.by_id.lock().unwrap().insert(food.id, food.clone());

        let servings_guard = self.servings.lock().unwrap().clone();
        if let Some(srv_repo) = servings_guard {
            for s in &servings {
                srv_repo.create(food.id, s).await?;
            }
        }
        Ok(food)
    }

    /// Update a user-custom food. When `servings` is `Some`, performs a
    /// full-list replace (drop-all + re-insert) mirroring the Pg behaviour.
    async fn update_custom_with_servings(
        &self,
        owner: Uuid,
        id: Uuid,
        patch: &FoodPatch,
        servings: Option<Vec<ServingDraft>>,
    ) -> CoreResult<Food> {
        {
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
            if let Some(v) = patch.nutriscore_grade {
                food.nutriscore_grade = Some(v);
            }
            food.updated_at = Utc::now();
        }

        if let Some(new_servings) = servings {
            if new_servings.is_empty() {
                return Err(loseit_core::CoreError::Validation(
                    "at least one serving required".into(),
                ));
            }
            let servings_guard = self.servings.lock().unwrap().clone();
            if let Some(srv_repo) = servings_guard {
                srv_repo.replace_all_for_food(id, &new_servings).await?;
            }
        }

        let food = self
            .by_id
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or(loseit_core::CoreError::NotFound)?;
        Ok(food)
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

    /// Upsert a batch of external (OFF / USDA) food records. Per-food:
    /// upsert the food row (by barcode), then full-list replace servings.
    async fn upsert_external_food_batch(
        &self,
        batch_id: Uuid,
        batch: Vec<FoodDraftWithServings>,
    ) -> CoreResult<()> {
        for rec in &batch {
            let draft = &rec.draft;
            let now = Utc::now();

            // Upsert: find existing by barcode (OFF) or insert new.
            let food_id: Uuid = {
                let mut store = self.by_id.lock().unwrap();
                let existing_id = draft.barcode.as_ref().and_then(|bc| {
                    store
                        .values()
                        .find(|f| {
                            (f.source == FoodSource::Off || f.source == FoodSource::Usda)
                                && f.barcode.as_deref() == Some(bc.as_str())
                        })
                        .map(|f| f.id)
                });
                match existing_id {
                    Some(id) => {
                        let food = store.get_mut(&id).expect("existing id missing");
                        food.name = draft.name.clone();
                        food.brands = draft.brands.clone();
                        food.categories_tags = draft.categories_tags.clone();
                        food.nutriscore_grade = draft.nutriscore_grade;
                        food.quality_score = rec.quality_score;
                        food.last_import_batch_id = Some(batch_id);
                        food.updated_at = now;
                        id
                    }
                    None => {
                        let food = Food {
                            id: Uuid::new_v4(),
                            source: FoodSource::Off,
                            kind: FoodKind::Normal,
                            owner_user_id: None,
                            barcode: draft.barcode.clone(),
                            fdc_id: None,
                            data_type: None,
                            name: draft.name.clone(),
                            brands: draft.brands.clone(),
                            categories_tags: draft.categories_tags.clone(),
                            nutriscore_grade: draft.nutriscore_grade,
                            quality_score: rec.quality_score,
                            extra_nutrients: None,
                            last_import_batch_id: Some(batch_id),
                            created_at: now,
                            updated_at: now,
                        };
                        let id = food.id;
                        store.insert(id, food);
                        id
                    }
                }
            };

            // Full-list serving replace.
            let servings_guard = self.servings.lock().unwrap().clone();
            if let Some(srv_repo) = servings_guard {
                srv_repo.replace_all_for_food(food_id, &rec.servings).await?;
            }
        }
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
        // {amount:1, unit:Serving, kcal:1.0} default serving per §6.3.
        //
        // The serving side-effect goes through the wired-in serving repo if
        // one is attached. If no serving repo is attached, the fake synthesizes
        // a Serving so callers see the same `(Food, Serving)` shape.
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

        // Step 2: find-or-insert the default sentinel serving:
        // {amount: 1, unit: Serving, kcal: 1.0, source: System, is_default: true}.
        let serving = if let Some(servings) = servings_guard {
            servings.find_or_create_sentinel_serving_for_food(food.id)
        } else {
            // No serving repo wired in — synthesize a Serving so callers can
            // still rely on the `(Food, Serving)` shape.
            Serving {
                id: Uuid::new_v4(),
                food_id: food.id,
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
}
