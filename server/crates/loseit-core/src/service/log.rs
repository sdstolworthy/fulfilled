use std::sync::Arc;

use chrono::NaiveDate;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::{
    unit::{Unit, UnitFamily},
    FoodLogEntry, FoodSearchHit, FoodSearchHitWithSignals, LogDraft, LogPatch, Meal,
    NutritionSnapshot, PersistedLogEntry, PersistedLogPatch, RecomputedSnapshot, Serving,
    ServingPreview,
};
use crate::repo::{FoodRepository, LogRepository, ServingRepository};
use crate::service::page::{resolve_page_params, Paginated};
use crate::service::user_food_summary::{enrich_hits, wrap_hits, UserFoodSummaryReader};
use crate::{CoreError, CoreResult};

/// Hardcoded "frequent" lookback window for v1. See NEXT_STEPS open
/// questions — could become configurable later.
pub const FREQUENT_WINDOW_DAYS: i64 = 30;

/// Default page size when `?limit=` is omitted on `/foods/recent` and
/// `/foods/frequent`.
pub const RECENT_FREQUENT_DEFAULT_LIMIT: i64 = 10;

/// Hard cap on `?limit=` for recent/frequent endpoints — the UI never needs
/// more than this and a larger value would let one viewer hammer the DB.
pub const RECENT_FREQUENT_MAX_LIMIT: i64 = 50;

pub struct LogService {
    logs: Arc<dyn LogRepository>,
    foods: Arc<dyn FoodRepository>,
    servings: Arc<dyn ServingRepository>,
    summary_reader: Arc<dyn UserFoodSummaryReader>,
}

impl LogService {
    pub fn new(
        logs: Arc<dyn LogRepository>,
        foods: Arc<dyn FoodRepository>,
        servings: Arc<dyn ServingRepository>,
        summary_reader: Arc<dyn UserFoodSummaryReader>,
    ) -> Self {
        Self {
            logs,
            foods,
            servings,
            summary_reader,
        }
    }

    pub fn logs(&self) -> &Arc<dyn LogRepository> {
        &self.logs
    }

    pub fn foods(&self) -> &Arc<dyn FoodRepository> {
        &self.foods
    }

    pub fn servings(&self) -> &Arc<dyn ServingRepository> {
        &self.servings
    }

    /// Compute a nutrition snapshot from a serving and a quantity multiplier.
    /// Snapshot = quantity * serving.<nutrient>. Rounds to NUMERIC(8,2).
    /// T08 replaces the per-100g path with this per-serving path.
    pub(crate) fn compute_snapshot(serving: &Serving, quantity: Decimal) -> NutritionSnapshot {
        let scale_round = |v: Decimal| to_numeric_8_2(v * quantity);
        NutritionSnapshot {
            calories_kcal: to_numeric_8_2(serving.kcal * quantity),
            protein_g: serving.protein_g.map(scale_round),
            carbs_g: serving.carbs_g.map(scale_round),
            fat_g: serving.fat_g.map(scale_round),
            fiber_g: serving.fiber_g.map(scale_round),
            sugar_g: serving.sugar_g.map(scale_round),
            sodium_mg: serving.sodium_mg.map(scale_round),
            saturated_fat_g: serving.saturated_fat_g.map(scale_round),
        }
    }

    #[tracing::instrument(skip(self, draft), fields(food_id = %draft.food_id, serving_id = %draft.serving_id))]
    pub async fn create(&self, user: Uuid, draft: LogDraft) -> CoreResult<FoodLogEntry> {
        let food = self
            .foods
            .find_by_id(user, draft.food_id)
            .await?
            .ok_or(CoreError::NotFound)?;
        let _ = food; // food visibility confirmed; T08 uses it for family check
        let serving = self
            .servings
            .find_by_id(draft.serving_id)
            .await?
            .ok_or(CoreError::NotFound)?;
        if serving.food_id != draft.food_id {
            return Err(CoreError::Validation(
                "serving does not belong to that food".into(),
            ));
        }
        // §5.1 conversion pipeline: cross-family guard → within-family quantity derivation.
        let quantity = derive_quantity(draft.entered_amount, draft.entered_unit, &serving)?;
        let snapshot = Self::compute_snapshot(&serving, quantity);
        let persisted = PersistedLogEntry {
            food_id: draft.food_id,
            serving_id: Some(serving.id),
            consumed_on: draft.consumed_on,
            meal: draft.meal,
            quantity,
            entered_amount: draft.entered_amount,
            entered_unit: draft.entered_unit,
            snapshot,
            note: draft.note,
        };
        self.logs.create(user, &persisted).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn quick_add(
        &self,
        user: Uuid,
        calories_kcal: Decimal,
        meal: Meal,
        consumed_on: NaiveDate,
        note: Option<String>,
    ) -> CoreResult<FoodLogEntry> {
        use crate::domain::Unit;
        if calories_kcal <= Decimal::ZERO {
            return Err(CoreError::Validation(
                "calories_kcal must be positive".into(),
            ));
        }
        if calories_kcal >= Decimal::from(9_999) {
            return Err(CoreError::Validation(
                "calories_kcal must be less than 9999".into(),
            ));
        }

        let (_food, serving) = self.foods.find_or_create_quick_add(user).await?;

        // Sentinel serving has {amount: 1, unit: Serving, kcal: 1.0}.
        // quantity = calories_kcal (each serving unit = 1 kcal).
        let quantity = calories_kcal;
        let snapshot = Self::compute_snapshot(&serving, quantity);

        let persisted = PersistedLogEntry {
            food_id: serving.food_id,
            serving_id: Some(serving.id),
            consumed_on,
            meal,
            quantity,
            entered_amount: calories_kcal,
            entered_unit: Unit::Serving,
            snapshot,
            note,
        };
        self.logs.create(user, &persisted).await
    }

    #[tracing::instrument(skip(self, patch))]
    pub async fn update(&self, user: Uuid, id: Uuid, patch: LogPatch) -> CoreResult<FoodLogEntry> {
        let existing = self
            .logs
            .find_by_id(user, id)
            .await?
            .ok_or(CoreError::NotFound)?;

        let serving_changed = patch
            .serving_id
            .is_some_and(|new| Some(new) != existing.serving_id);
        let amount_changed = patch
            .entered_amount
            .is_some_and(|new| new != existing.entered_amount);
        let unit_changed = patch
            .entered_unit
            .is_some_and(|new| new != existing.entered_unit);

        let recompute = if serving_changed || amount_changed || unit_changed {
            let serving_id = patch.serving_id.or(existing.serving_id).ok_or_else(|| {
                CoreError::Validation(
                    "cannot edit log entry whose serving was deleted; create a new entry".into(),
                )
            })?;
            let entered_amount = patch.entered_amount.unwrap_or(existing.entered_amount);
            let entered_unit = patch.entered_unit.unwrap_or(existing.entered_unit);
            let serving = self
                .servings
                .find_by_id(serving_id)
                .await?
                .ok_or(CoreError::NotFound)?;
            if serving.food_id != existing.food_id {
                return Err(CoreError::Validation(
                    "serving does not belong to that food".into(),
                ));
            }
            // §5.1 conversion pipeline: cross-family guard → within-family quantity derivation.
            let quantity = derive_quantity(entered_amount, entered_unit, &serving)?;
            let snapshot = Self::compute_snapshot(&serving, quantity);
            Some(RecomputedSnapshot {
                quantity,
                entered_amount,
                entered_unit,
                snapshot,
            })
        } else {
            None
        };

        let persisted = PersistedLogPatch {
            serving_id: patch.serving_id,
            consumed_on: patch.consumed_on,
            meal: patch.meal,
            note: patch.note,
            recompute,
        };
        self.logs.update(user, id, &persisted).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn delete(&self, user: Uuid, id: Uuid) -> CoreResult<()> {
        self.logs.delete(user, id).await
    }

    /// Copy every entry on `from_date` (optionally filtered by `meal`) onto
    /// `to_date`, re-snapshotting each from the current serving.
    #[tracing::instrument(skip(self))]
    pub async fn copy_day(
        &self,
        user: Uuid,
        from_date: NaiveDate,
        to_date: NaiveDate,
        meal: Option<Meal>,
    ) -> CoreResult<Vec<FoodLogEntry>> {
        let source = self.logs.list_for_day(user, from_date).await?;

        let mut persisted: Vec<PersistedLogEntry> = Vec::with_capacity(source.len());
        for e in source.iter().filter(|e| meal.map_or(true, |m| e.meal == m)) {
            let Some(_food) = self.foods.find_by_id(user, e.food_id).await? else {
                tracing::info!(
                    entry_id = %e.id,
                    food_id = %e.food_id,
                    "copy_day: skipping entry — food not visible",
                );
                continue;
            };
            let Some(serving_id) = e.serving_id else {
                tracing::info!(
                    entry_id = %e.id,
                    "copy_day: skipping entry — no serving_id on source",
                );
                continue;
            };
            let Some(serving) = self.servings.find_by_id(serving_id).await? else {
                tracing::info!(
                    entry_id = %e.id,
                    serving_id = %serving_id,
                    "copy_day: skipping entry — serving deleted",
                );
                continue;
            };
            if serving.food_id != e.food_id {
                tracing::info!(
                    entry_id = %e.id,
                    serving_food = %serving.food_id,
                    entry_food = %e.food_id,
                    "copy_day: skipping entry — serving.food_id mismatch",
                );
                continue;
            }

            let quantity = e.quantity;
            if quantity >= Decimal::from(10_000) {
                tracing::info!(
                    entry_id = %e.id,
                    "copy_day: skipping entry — quantity overflow",
                );
                continue;
            }
            let snapshot = Self::compute_snapshot(&serving, quantity);
            persisted.push(PersistedLogEntry {
                food_id: e.food_id,
                serving_id: Some(serving.id),
                consumed_on: to_date,
                meal: e.meal,
                quantity,
                entered_amount: e.entered_amount,
                entered_unit: e.entered_unit,
                snapshot,
                note: e.note.clone(),
            });
        }

        self.logs.create_many(user, &persisted).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn list_in_range(
        &self,
        user: Uuid,
        from: NaiveDate,
        to: NaiveDate,
    ) -> CoreResult<Vec<FoodLogEntry>> {
        self.logs.list_in_range(user, from, to).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn list(
        &self,
        user: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> CoreResult<Paginated<FoodLogEntry>> {
        if let (Some(f), Some(t)) = (from, to) {
            if f > t {
                return Err(CoreError::Validation("`from` must be <= `to`".into()));
            }
        }
        let page = resolve_page_params(limit, offset)?;
        let results = self
            .logs
            .list_paginated(user, from, to, page.limit, page.offset)
            .await?;
        let total = self.logs.count_in_range(user, from, to).await?;
        Ok(Paginated {
            results,
            total,
            limit: page.limit,
            offset: page.offset,
        })
    }

    #[tracing::instrument(skip(self))]
    pub async fn recent_foods(
        &self,
        user: Uuid,
        limit: i64,
    ) -> CoreResult<Vec<FoodSearchHitWithSignals>> {
        let limit = clamp_recent_frequent_limit(limit);
        let ids = self.logs.recent_food_ids(user, limit).await?;
        let hits = self.hydrate_hits(user, ids).await?;
        let mut wrapped = wrap_hits(hits);
        enrich_hits(self.summary_reader.as_ref(), user, &mut wrapped).await?;
        Ok(wrapped)
    }

    #[tracing::instrument(skip(self))]
    pub async fn frequent_foods(
        &self,
        user: Uuid,
        limit: i64,
    ) -> CoreResult<Vec<FoodSearchHitWithSignals>> {
        let limit = clamp_recent_frequent_limit(limit);
        let pairs = self
            .logs
            .frequent_food_ids(user, FREQUENT_WINDOW_DAYS, limit)
            .await?;
        let ids: Vec<Uuid> = pairs.into_iter().map(|(id, _count)| id).collect();
        let hits = self.hydrate_hits(user, ids).await?;
        let mut wrapped = wrap_hits(hits);
        enrich_hits(self.summary_reader.as_ref(), user, &mut wrapped).await?;
        Ok(wrapped)
    }

    /// Hydrate a ranked list of food ids into `FoodSearchHit`. Skips foods no
    /// longer visible. Order is preserved.
    async fn hydrate_hits(&self, user: Uuid, ids: Vec<Uuid>) -> CoreResult<Vec<FoodSearchHit>> {
        let mut out = Vec::with_capacity(ids.len());
        for id in ids {
            let Some(food) = self.foods.find_by_id(user, id).await? else {
                continue;
            };
            let servings = self.servings.list_for_food(food.id).await?;
            let default_serving = servings
                .iter()
                .find(|s| s.is_default)
                .map(|s| ServingPreview {
                    id: s.id,
                    label: s.label.clone(),
                    amount: s.amount,
                    unit: s.unit,
                    kcal: s.kcal,
                });
            out.push(FoodSearchHit {
                id: food.id,
                source: food.source,
                name: food.name,
                brand: food.brands,
                barcode: food.barcode,
                default_serving,
            });
        }
        Ok(out)
    }
}

/// Round + pad a Decimal to exactly two fractional digits (NUMERIC(8,2)).
fn to_numeric_8_2(value: Decimal) -> Decimal {
    let mut v = value.round_dp(2);
    v.rescale(2);
    v
}

/// Round + pad a Decimal to exactly three fractional digits (NUMERIC(8,3)).
fn to_numeric_8_3(value: Decimal) -> Decimal {
    let mut v = value.round_dp(3);
    v.rescale(3);
    v
}

fn clamp_recent_frequent_limit(limit: i64) -> i64 {
    if limit <= 0 {
        RECENT_FREQUENT_DEFAULT_LIMIT
    } else {
        limit.min(RECENT_FREQUENT_MAX_LIMIT)
    }
}

/// §5.1 conversion helper.
///
/// Given what the user typed (`entered_amount`, `entered_unit`) and the
/// target serving, derives the dimensionless quantity multiplier (rounded to
/// NUMERIC(8,3)) and validates all guards:
///
/// 1. Cross-family guard: `entered_unit.family() != serving.unit.family()` → Validation.
/// 2. Count strict-unit: both Count but different units (e.g. `piece` vs `serving`) → Validation.
/// 3. Within-family conversion via `ratio_to_canonical`.
/// 4. Quantity guard: must be > 0 and < 10_000.
pub(crate) fn derive_quantity(
    entered_amount: Decimal,
    entered_unit: Unit,
    serving: &Serving,
) -> crate::CoreResult<Decimal> {
    let e_family = entered_unit.family();
    let s_family = serving.unit.family();

    // Guard 1: cross-family
    if e_family != s_family {
        return Err(CoreError::Validation("unit_family_mismatch".into()));
    }

    let quantity = match e_family {
        UnitFamily::Mass | UnitFamily::Volume => {
            // Within-family conversion via canonical ratio.
            let entered_canonical = entered_amount * entered_unit.ratio_to_canonical();
            let serving_canonical = serving.amount * serving.unit.ratio_to_canonical();
            entered_canonical / serving_canonical
        }
        UnitFamily::Count => {
            // Guard 2: Count members are siblings, not interconvertible.
            if entered_unit != serving.unit {
                return Err(CoreError::Validation("unit_family_mismatch".into()));
            }
            entered_amount / serving.amount
        }
    };

    let quantity = to_numeric_8_3(quantity);

    if quantity <= Decimal::ZERO {
        return Err(CoreError::Validation("quantity must be positive".into()));
    }
    if quantity >= Decimal::from(10_000) {
        return Err(CoreError::Validation(
            "quantity exceeds maximum allowed value".into(),
        ));
    }

    Ok(quantity)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{serving::ServingSource, unit::Unit};
    use chrono::Utc;
    use rust_decimal_macros::dec;
    use uuid::Uuid;

    fn make_serving(amount: Decimal, unit: Unit, kcal: Decimal) -> Serving {
        Serving {
            id: Uuid::new_v4(),
            food_id: Uuid::new_v4(),
            label: None,
            amount,
            unit,
            kcal,
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sugar_g: None,
            sodium_mg: None,
            saturated_fat_g: None,
            is_default: true,
            source: ServingSource::User,
            sort_order: 0,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    /// Volume within-family: 4 fl_oz against {1 cup} serving → quantity = 0.5
    /// (4 × 29.5735295625 ml / (1 × 236.5882365 ml) = 118.294… / 236.588… ≈ 0.5 exact).
    #[test]
    fn test_volume_within_family_fl_oz_to_cup() {
        let serving = make_serving(dec!(1), Unit::Cup, dec!(200));
        let q = derive_quantity(dec!(4), Unit::FluidOunce, &serving).unwrap();
        assert_eq!(q, dec!(0.500));
    }

    /// Mass within-family: 100 g against {1 kg} serving → quantity = 0.100.
    #[test]
    fn test_mass_within_family_g_to_kg() {
        let serving = make_serving(dec!(1), Unit::Kilogram, dec!(100));
        let q = derive_quantity(dec!(100), Unit::Gram, &serving).unwrap();
        assert_eq!(q, dec!(0.100));
    }

    /// Cross-family rejection: entered=g, serving.unit=cup → Validation("unit_family_mismatch").
    #[test]
    fn test_cross_family_mass_vs_volume_rejected() {
        let serving = make_serving(dec!(1), Unit::Cup, dec!(150));
        let err = derive_quantity(dec!(100), Unit::Gram, &serving).unwrap_err();
        match err {
            CoreError::Validation(msg) => assert_eq!(msg, "unit_family_mismatch"),
            other => panic!("expected Validation, got {other:?}"),
        }
    }

    /// Count strict-unit: entered=Piece against serving.unit=Serving → Validation.
    #[test]
    fn test_count_strict_unit_piece_vs_serving_rejected() {
        let serving = make_serving(dec!(1), Unit::Serving, dec!(100));
        let err = derive_quantity(dec!(1), Unit::Piece, &serving).unwrap_err();
        match err {
            CoreError::Validation(msg) => assert_eq!(msg, "unit_family_mismatch"),
            other => panic!("expected Validation, got {other:?}"),
        }
    }

    /// Count exact-unit: entered=Serving against {amount:1, unit:Serving} → quantity = entered_amount.
    #[test]
    fn test_count_exact_unit_serving_matches() {
        let serving = make_serving(dec!(1), Unit::Serving, dec!(100));
        let q = derive_quantity(dec!(2), Unit::Serving, &serving).unwrap();
        assert_eq!(q, dec!(2.000));
    }

    /// Quick-add path: quantity = calories_kcal, entered_unit = Serving,
    /// snapshot.calories_kcal = calories_kcal (sentinel has kcal=1).
    #[test]
    fn test_quick_add_quantity_equals_calories() {
        let serving = make_serving(dec!(1), Unit::Serving, dec!(1));
        let q = derive_quantity(dec!(100), Unit::Serving, &serving).unwrap();
        assert_eq!(q, dec!(100.000));
        let snapshot = LogService::compute_snapshot(&serving, q);
        assert_eq!(snapshot.calories_kcal, dec!(100.00));
        assert!(snapshot.protein_g.is_none());
    }
}
