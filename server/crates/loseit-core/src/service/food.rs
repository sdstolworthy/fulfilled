use std::sync::Arc;

use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::{
    Food, FoodDraft, FoodPatch, FoodSearchHit, FoodSource, NutritionPer100g, Serving, ServingDraft,
    ServingSource,
};
use crate::repo::food::QUICK_ADD_SENTINEL_NAME;
use crate::repo::{FoodRepository, ServingRepository};
use crate::service::page::{resolve_page_params, Paginated};
use crate::{CoreError, CoreResult};

/// Business logic for foods and food search. Holds a `FoodRepository` and
/// a `ServingRepository` because both detail lookup and custom-food
/// creation need to compose the two.
pub struct FoodService {
    foods: Arc<dyn FoodRepository>,
    servings: Arc<dyn ServingRepository>,
}

impl FoodService {
    pub fn new(foods: Arc<dyn FoodRepository>, servings: Arc<dyn ServingRepository>) -> Self {
        Self { foods, servings }
    }

    pub fn foods(&self) -> &Arc<dyn FoodRepository> {
        &self.foods
    }

    pub fn servings(&self) -> &Arc<dyn ServingRepository> {
        &self.servings
    }

    #[tracing::instrument(skip(self))]
    pub async fn detail(&self, viewer: Uuid, id: Uuid) -> CoreResult<(Food, Vec<Serving>)> {
        let food = self
            .foods
            .find_by_id(viewer, id)
            .await?
            .ok_or(crate::CoreError::NotFound)?;
        let servings = self.servings.list_for_food(food.id).await?;
        Ok((food, servings))
    }

    #[tracing::instrument(skip(self))]
    pub async fn by_barcode(
        &self,
        viewer: Uuid,
        barcode: &str,
    ) -> CoreResult<(Food, Vec<Serving>)> {
        let food = self
            .foods
            .find_by_barcode(viewer, barcode)
            .await?
            .ok_or(crate::CoreError::NotFound)?;
        let servings = self.servings.list_for_food(food.id).await?;
        Ok((food, servings))
    }

    /// Search foods visible to `viewer`. Validation:
    ///
    /// * `q` is trimmed and must be non-empty; otherwise `Validation`.
    /// * `limit` / `offset` flow through [`resolve_page_params`], which is
    ///   the single source of truth for the unified pagination contract
    ///   (`DEFAULT_PAGE_LIMIT=100`, silent clamp at `MAX_PAGE_LIMIT=500`,
    ///   400 on negative values).
    ///
    /// The repo performs the actual lookup (`search`) plus a separate
    /// `count(*)` query (`search_count`) so `total` reflects the full match
    /// set independent of pagination.
    #[tracing::instrument(skip(self))]
    pub async fn search(
        &self,
        viewer: Uuid,
        q: &str,
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> CoreResult<Paginated<FoodSearchHit>> {
        let trimmed = q.trim();
        if trimmed.is_empty() {
            return Err(CoreError::Validation("query is required".into()));
        }

        let page = resolve_page_params(limit, offset)?;

        let results = self
            .foods
            .search(viewer, trimmed, page.limit, page.offset)
            .await?;
        let total = self.foods.search_count(viewer, trimmed).await?;

        Ok(Paginated {
            results,
            total,
            limit: page.limit,
            offset: page.offset,
        })
    }

    /// List the caller's own custom foods, optionally filtered by a
    /// case-insensitive substring match. Pagination follows the unified
    /// `DEFAULT_PAGE_LIMIT=100` / `MAX_PAGE_LIMIT=500` policy via
    /// [`resolve_page_params`].
    ///
    /// Validation:
    /// * `q` is trimmed; empty after trim is treated as `None`.
    /// * If `q` is provided and exceeds 200 bytes after trim, returns
    ///   `CoreError::Validation`.
    #[tracing::instrument(skip(self))]
    pub async fn list_mine(
        &self,
        owner: Uuid,
        q: Option<&str>,
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> CoreResult<Paginated<FoodSearchHit>> {
        let q_opt = match q {
            Some(s) => {
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    None
                } else if trimmed.len() > 200 {
                    return Err(CoreError::Validation(
                        "q must be <= 200 bytes".into(),
                    ));
                } else {
                    Some(trimmed)
                }
            }
            None => None,
        };

        let page = resolve_page_params(limit, offset)?;

        let results = self
            .foods
            .list_mine(owner, q_opt, page.limit, page.offset)
            .await?;
        let total = self.foods.count_mine(owner, q_opt).await?;

        Ok(Paginated {
            results,
            total,
            limit: page.limit,
            offset: page.offset,
        })
    }

    /// Create a custom food owned by `owner`. Validates the draft, persists
    /// the food, then synthesizes a default `100 g` system serving so logs
    /// can be recorded immediately without a separate request.
    #[tracing::instrument(skip(self, draft), fields(name = %draft.name))]
    pub async fn create_custom(&self, owner: Uuid, draft: FoodDraft) -> CoreResult<Food> {
        if draft.name.trim().is_empty() {
            return Err(CoreError::Validation("name is required".into()));
        }
        // `__quick_add__` is reserved for the per-user quick-add sentinel food
        // (provisioned via `FoodRepository::find_or_create_quick_add`). User
        // creates that collide with the sentinel are rejected here so the
        // partial unique index `foods_quick_add_singleton` never has to be
        // the line of defense. Case-insensitive on the trimmed value.
        if draft.name.trim().eq_ignore_ascii_case(QUICK_ADD_SENTINEL_NAME) {
            return Err(CoreError::Validation("name is reserved".into()));
        }
        validate_nutrition(&draft.nutrition)?;

        let food = self.foods.create_custom(owner, &draft).await?;

        // Synthesize the default 100 g serving. We deliberately do this in
        // the service rather than the repo so the repo trait stays a thin
        // CRUD surface.
        let serving_draft = ServingDraft {
            label: "100 g".into(),
            grams: Decimal::from(100),
            is_default: true,
            source: ServingSource::System,
            sort_order: 0,
        };
        self.servings.create(food.id, &serving_draft).await?;
        Ok(food)
    }

    #[tracing::instrument(skip(self, patch))]
    pub async fn update_custom(&self, owner: Uuid, id: Uuid, patch: FoodPatch) -> CoreResult<Food> {
        // Visibility check first: `find_by_id` returns None when the food is
        // an OFF row (visible but not owned) or someone else's custom (not
        // visible). To distinguish "not visible at all" (404) from "visible
        // but read-only OFF" (403), we have to look both ways. We use the
        // owner as the viewer so OFF rows still resolve.
        let food = self
            .foods
            .find_by_id(owner, id)
            .await?
            .ok_or(CoreError::NotFound)?;
        if food.source == FoodSource::Off {
            return Err(CoreError::Forbidden);
        }
        // The per-user quick-add sentinel is read-only for the user (it has
        // no meaningful editable fields — name/nutrition are part of its
        // encoding contract). Returning Forbidden is indistinguishable from
        // an OFF-owned food, which is fine.
        if food.name == QUICK_ADD_SENTINEL_NAME {
            return Err(CoreError::Forbidden);
        }
        // Symmetric to `create_custom`: forbid renaming any other custom food
        // *to* the reserved sentinel name. Without this, the partial unique
        // index `foods_quick_add_singleton` would be the line of defense, and
        // a successful rename would shadow the user's actual sentinel for the
        // sentinel-exclusion filters in search/recent/frequent. Case- and
        // whitespace-insensitive on the patched name, matching `create_custom`.
        if patch
            .name
            .as_deref()
            .map(str::trim)
            .is_some_and(|n| n.eq_ignore_ascii_case(QUICK_ADD_SENTINEL_NAME))
        {
            return Err(CoreError::Validation("name is reserved".into()));
        }
        // `find_by_id` with viewer=owner already filters out other users'
        // customs (returns None → NotFound above), so we know owner_user_id
        // matches here. The repo's `update_custom` re-enforces this via
        // `WHERE owner_user_id = $owner`.
        if let Some(n) = &patch.nutrition {
            validate_nutrition(n)?;
        }
        self.foods.update_custom(owner, id, &patch).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn delete_custom(&self, owner: Uuid, id: Uuid) -> CoreResult<()> {
        let food = self
            .foods
            .find_by_id(owner, id)
            .await?
            .ok_or(CoreError::NotFound)?;
        if food.source == FoodSource::Off {
            return Err(CoreError::Forbidden);
        }
        // Same protection as `update_custom`: the quick-add sentinel is the
        // anchor for the user's quick-add log entries and must outlive them.
        if food.name == QUICK_ADD_SENTINEL_NAME {
            return Err(CoreError::Forbidden);
        }
        // Repo refuses with `Conflict` if any log entry still references this
        // food — bubble that straight up so the handler emits a 409.
        self.foods.delete_custom(owner, id).await
    }
}

fn validate_nutrition(n: &NutritionPer100g) -> CoreResult<()> {
    let zero = Decimal::ZERO;
    let fields: [(Option<Decimal>, &str); 8] = [
        (n.energy_kcal, "energy_kcal"),
        (n.protein_g, "protein_g"),
        (n.carbs_g, "carbs_g"),
        (n.fat_g, "fat_g"),
        (n.fiber_g, "fiber_g"),
        (n.sugar_g, "sugar_g"),
        (n.sodium_g, "sodium_g"),
        (n.saturated_fat_g, "saturated_fat_g"),
    ];
    for (val, label) in fields {
        if let Some(v) = val {
            if v < zero {
                return Err(CoreError::Validation(format!(
                    "{label} must be non-negative"
                )));
            }
        }
    }
    Ok(())
}
