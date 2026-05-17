use std::sync::Arc;

use uuid::Uuid;

use crate::domain::{
    Food, FoodDraft, FoodPatch, FoodSearchHit, FoodSource, Serving, ServingDraft,
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
                    return Err(CoreError::Validation("q must be <= 200 bytes".into()));
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

    /// Create a custom food owned by `owner`. Validates the draft (including
    /// that at least one serving is present), then persists the food and
    /// its servings. T08 will add the full per-serving validation pass.
    #[tracing::instrument(skip(self, draft), fields(name = %draft.name))]
    pub async fn create_custom(&self, owner: Uuid, draft: FoodDraft) -> CoreResult<Food> {
        if draft.name.trim().is_empty() {
            return Err(CoreError::Validation("name is required".into()));
        }
        if draft
            .name
            .trim()
            .eq_ignore_ascii_case(QUICK_ADD_SENTINEL_NAME)
        {
            return Err(CoreError::Validation("name is reserved".into()));
        }
        if draft.servings.is_empty() {
            return Err(CoreError::Validation(
                "at least one serving is required".into(),
            ));
        }
        for s in &draft.servings {
            validate_serving_draft(s)?;
        }

        let food = self.foods.create_custom(owner, &draft).await?;

        // Persist servings. T03+ will fold this into create_custom_with_servings.
        for s in &draft.servings {
            self.servings.create(food.id, s).await?;
        }
        Ok(food)
    }

    #[tracing::instrument(skip(self, patch))]
    pub async fn update_custom(&self, owner: Uuid, id: Uuid, patch: FoodPatch) -> CoreResult<Food> {
        let food = self
            .foods
            .find_by_id(owner, id)
            .await?
            .ok_or(CoreError::NotFound)?;
        if food.source == FoodSource::Off {
            return Err(CoreError::Forbidden);
        }
        if food.name == QUICK_ADD_SENTINEL_NAME {
            return Err(CoreError::Forbidden);
        }
        if patch
            .name
            .as_deref()
            .map(str::trim)
            .is_some_and(|n| n.eq_ignore_ascii_case(QUICK_ADD_SENTINEL_NAME))
        {
            return Err(CoreError::Validation("name is reserved".into()));
        }
        if let Some(servings) = &patch.servings {
            if servings.is_empty() {
                return Err(CoreError::Validation(
                    "at least one serving is required".into(),
                ));
            }
            for s in servings {
                validate_serving_draft(s)?;
            }
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
        if food.name == QUICK_ADD_SENTINEL_NAME {
            return Err(CoreError::Forbidden);
        }
        self.foods.delete_custom(owner, id).await
    }
}

fn validate_serving_draft(s: &ServingDraft) -> CoreResult<()> {
    use rust_decimal::Decimal;
    if s.amount <= Decimal::ZERO {
        return Err(CoreError::Validation("serving amount must be positive".into()));
    }
    if s.kcal < Decimal::ZERO {
        return Err(CoreError::Validation("serving kcal must be non-negative".into()));
    }
    let optional_fields: [(Option<Decimal>, &str); 7] = [
        (s.protein_g, "protein_g"),
        (s.carbs_g, "carbs_g"),
        (s.fat_g, "fat_g"),
        (s.fiber_g, "fiber_g"),
        (s.sugar_g, "sugar_g"),
        (s.sodium_mg, "sodium_mg"),
        (s.saturated_fat_g, "saturated_fat_g"),
    ];
    for (val, label) in optional_fields {
        if let Some(v) = val {
            if v < Decimal::ZERO {
                return Err(CoreError::Validation(format!(
                    "{label} must be non-negative"
                )));
            }
        }
    }
    Ok(())
}
