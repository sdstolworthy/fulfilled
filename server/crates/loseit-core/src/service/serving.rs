use std::sync::Arc;

use uuid::Uuid;

use crate::domain::{Food, FoodSource, Serving, ServingDraft, ServingPatch};
use crate::repo::{FoodRepository, ServingRepository};
use crate::{CoreError, CoreResult};

pub struct ServingService {
    servings: Arc<dyn ServingRepository>,
    foods: Arc<dyn FoodRepository>,
}

impl ServingService {
    pub fn new(servings: Arc<dyn ServingRepository>, foods: Arc<dyn FoodRepository>) -> Self {
        Self { servings, foods }
    }

    #[tracing::instrument(skip(self))]
    pub async fn list_for_food(&self, food_id: Uuid) -> CoreResult<Vec<Serving>> {
        self.servings.list_for_food(food_id).await
    }

    /// Create a serving for a food the viewer owns. Rejects OFF foods with a
    /// 409 carrying the documented clone-hint message; rejects other users'
    /// customs with 404 (consistent with `find_by_id` visibility).
    #[tracing::instrument(skip(self, draft))]
    pub async fn create(
        &self,
        viewer: Uuid,
        food_id: Uuid,
        draft: ServingDraft,
    ) -> CoreResult<Serving> {
        let food = self.load_writable_food(viewer, food_id).await?;
        let serving = self.servings.create(food.id, &draft).await?;
        // Two-step default flip: the in-memory fake's `create` already
        // unsets prior defaults when `draft.is_default`, but production sqlx
        // doesn't. Calling `set_default` afterwards is idempotent and gives
        // the atomic guarantee on both backends.
        if draft.is_default {
            self.servings.set_default(food.id, serving.id).await?;
        }
        Ok(serving)
    }

    #[tracing::instrument(skip(self, patch))]
    pub async fn update(
        &self,
        viewer: Uuid,
        serving_id: Uuid,
        patch: ServingPatch,
    ) -> CoreResult<Serving> {
        let serving = self
            .servings
            .find_by_id(serving_id)
            .await?
            .ok_or(CoreError::NotFound)?;
        let _food = self.load_writable_food(viewer, serving.food_id).await?;
        self.servings.update(serving_id, &patch).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn set_default(
        &self,
        viewer: Uuid,
        food_id: Uuid,
        serving_id: Uuid,
    ) -> CoreResult<()> {
        let _food = self.load_writable_food(viewer, food_id).await?;
        // Verify the serving belongs to the food before mutating anything.
        let serving = self
            .servings
            .find_by_id(serving_id)
            .await?
            .ok_or(CoreError::NotFound)?;
        if serving.food_id != food_id {
            return Err(CoreError::NotFound);
        }
        self.servings.set_default(food_id, serving_id).await
    }

    /// Atomic default-serving flip given only a serving id. The wire
    /// (`POST /servings/:id/default`) doesn't carry a food id, so the
    /// service resolves it internally — the previous handler used to
    /// reach into a public `servings()` getter to look up the food id,
    /// which let writes skip [`load_writable_food`]. Routing the lookup
    /// through this method puts the guard back in one place.
    ///
    /// Returns the post-flip serving so the handler can render the
    /// updated row without a second round-trip.
    #[tracing::instrument(skip(self))]
    pub async fn set_default_by_serving_id(
        &self,
        viewer: Uuid,
        serving_id: Uuid,
    ) -> CoreResult<Serving> {
        let serving = self
            .servings
            .find_by_id(serving_id)
            .await?
            .ok_or(CoreError::NotFound)?;
        let _food = self.load_writable_food(viewer, serving.food_id).await?;
        self.servings
            .set_default(serving.food_id, serving_id)
            .await?;
        // Re-read so the response reflects the post-flip state.
        self.servings
            .find_by_id(serving_id)
            .await?
            .ok_or(CoreError::NotFound)
    }

    #[tracing::instrument(skip(self))]
    pub async fn delete(&self, viewer: Uuid, serving_id: Uuid) -> CoreResult<()> {
        let serving = self
            .servings
            .find_by_id(serving_id)
            .await?
            .ok_or(CoreError::NotFound)?;
        let _food = self.load_writable_food(viewer, serving.food_id).await?;
        // The repo refuses if `is_default` — bubble its `Conflict` (which
        // becomes 409) up to the handler unchanged.
        self.servings.delete(serving_id).await
    }

    /// Load a food the viewer is allowed to mutate the servings of. OFF
    /// foods are read-only; other users' customs are invisible (404).
    async fn load_writable_food(&self, viewer: Uuid, food_id: Uuid) -> CoreResult<Food> {
        let food = self
            .foods
            .find_by_id(viewer, food_id)
            .await?
            .ok_or(CoreError::NotFound)?;
        if food.source == FoodSource::Off {
            return Err(CoreError::Conflict(
                "OFF foods are read-only; clone as a custom food to add servings".into(),
            ));
        }
        Ok(food)
    }
}
