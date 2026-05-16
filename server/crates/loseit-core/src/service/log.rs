use std::collections::HashMap;
use std::sync::Arc;

use chrono::NaiveDate;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::{
    DaySummary, Food, FoodLogEntry, FoodSearchHit, LogDraft, LogPatch, Meal, MealSubtotal,
    NutritionSnapshot, PersistedLogEntry, PersistedLogPatch, RecomputedSnapshot, ServingPreview,
};
use crate::repo::{FoodRepository, GoalRepository, LogRepository, ServingRepository};
use crate::service::page::{resolve_page_params, Paginated};
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
    goals: Arc<dyn GoalRepository>,
}

impl LogService {
    pub fn new(
        logs: Arc<dyn LogRepository>,
        foods: Arc<dyn FoodRepository>,
        servings: Arc<dyn ServingRepository>,
        goals: Arc<dyn GoalRepository>,
    ) -> Self {
        Self {
            logs,
            foods,
            servings,
            goals,
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

    pub fn goals(&self) -> &Arc<dyn GoalRepository> {
        &self.goals
    }

    /// Scale a food's per-100g nutrition to a concrete number of grams.
    /// Sodium converts grams → mg in the process (snapshot column is mg).
    /// Rounds to the SQL column precision (`NUMERIC(8,2)`) so what the
    /// service computes matches what the database stores byte-for-byte —
    /// otherwise round-trip comparisons in tests would fail.
    pub(crate) fn compute_snapshot(food: &Food, grams_total: Decimal) -> NutritionSnapshot {
        let scale = grams_total / Decimal::from(100);
        // `to_numeric_8_2` is the rounding+rescale helper used everywhere
        // the schema is `NUMERIC(8,2)` — it always returns scale=2, so
        // tests' string assertions ("150.00") match production's Postgres
        // output byte-for-byte. `round_dp(2)` alone won't pad — a Decimal
        // of 150 stays "150" — so we explicitly rescale afterwards.
        let scale_round = |v: Decimal| to_numeric_8_2(v * scale);
        let n = &food.nutrition;
        NutritionSnapshot {
            calories_kcal: n
                .energy_kcal
                .map(scale_round)
                .unwrap_or_else(|| to_numeric_8_2(Decimal::ZERO)),
            protein_g: n.protein_g.map(scale_round),
            carbs_g: n.carbs_g.map(scale_round),
            fat_g: n.fat_g.map(scale_round),
            fiber_g: n.fiber_g.map(scale_round),
            sugar_g: n.sugar_g.map(scale_round),
            // sodium_g → sodium_mg: scale by grams_total/100, then *1000 for
            // g→mg. Composed into a single expression so we round once at the
            // end.
            sodium_mg: n
                .sodium_g
                .map(|grams| to_numeric_8_2(grams * scale * Decimal::from(1000))),
            saturated_fat_g: n.saturated_fat_g.map(scale_round),
        }
    }

    #[tracing::instrument(skip(self, draft), fields(food_id = %draft.food_id, serving_id = %draft.serving_id))]
    pub async fn create(&self, user: Uuid, draft: LogDraft) -> CoreResult<FoodLogEntry> {
        if draft.quantity <= Decimal::ZERO {
            return Err(CoreError::Validation("quantity must be positive".into()));
        }
        let food = self
            .foods
            .find_by_id(user, draft.food_id)
            .await?
            .ok_or(CoreError::NotFound)?;
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
        // `grams_total` lives in `NUMERIC(10,2)` — round + pad at the service
        // so tests and production agree byte-for-byte on the stored value.
        let grams_total = to_numeric_8_2(serving.grams * draft.quantity);
        // Reject overflow at the service boundary so we surface a 400 rather
        // than a Postgres numeric_overflow when grams_total >= 10^8.
        if grams_total >= Decimal::new(100_000_000, 2) {
            return Err(CoreError::Validation(
                "grams_total exceeds maximum allowed value".into(),
            ));
        }
        let snapshot = Self::compute_snapshot(&food, grams_total);
        let persisted = PersistedLogEntry {
            food_id: draft.food_id,
            serving_id: Some(serving.id),
            consumed_on: draft.consumed_on,
            meal: draft.meal,
            quantity: draft.quantity,
            grams_total,
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
        // Validation: must be strictly positive, < 9_999.
        // The upper bound is set below 10_000 so the explicit calories error
        // fires before the grams_total guard (grams_total = calories * 100,
        // so grams_total >= 1_000_000 at calories >= 10_000).
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

        // Provision sentinel (idempotent) → reuse standard create path.
        let (food, serving) = self.foods.find_or_create_quick_add(user).await?;

        // grams_total = calories_kcal * 100  (sentinel has 1 kcal / 100 g,
        // serving.grams = 100, so quantity = calories_kcal). Pad to NUMERIC(8,2).
        let quantity = calories_kcal;
        let grams_total = to_numeric_8_2(serving.grams * quantity);
        if grams_total >= Decimal::new(100_000_000, 2) {
            return Err(CoreError::Validation(
                "grams_total exceeds maximum allowed value".into(),
            ));
        }
        let snapshot = Self::compute_snapshot(&food, grams_total);

        let persisted = PersistedLogEntry {
            food_id: food.id,
            serving_id: Some(serving.id),
            consumed_on,
            meal,
            quantity,
            grams_total,
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

        // Validate the patched quantity if present; the unpatched (existing)
        // quantity was validated at create time and is trusted.
        if let Some(q) = patch.quantity {
            if q <= Decimal::ZERO {
                return Err(CoreError::Validation("quantity must be positive".into()));
            }
        }

        // Did the snapshot inputs change? Only recompute if so.
        let serving_changed = patch
            .serving_id
            .is_some_and(|new| Some(new) != existing.serving_id);
        let quantity_changed = patch.quantity.is_some_and(|new| new != existing.quantity);

        let recompute = if serving_changed || quantity_changed {
            // Resolve the effective serving_id. If neither the patch nor the
            // existing entry has one, we can't recompute the snapshot.
            let serving_id = patch.serving_id.or(existing.serving_id).ok_or_else(|| {
                CoreError::Validation(
                    "cannot edit log entry whose serving was deleted; create a new entry".into(),
                )
            })?;
            let quantity = patch.quantity.unwrap_or(existing.quantity);
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
            // The food never changes on update (food_id is immutable), so
            // re-fetch by the entry's food id, not the serving's food id.
            let food = self
                .foods
                .find_by_id(user, existing.food_id)
                .await?
                .ok_or(CoreError::NotFound)?;
            let grams_total = to_numeric_8_2(serving.grams * quantity);
            if grams_total >= Decimal::new(100_000_000, 2) {
                return Err(CoreError::Validation(
                    "grams_total exceeds maximum allowed value".into(),
                ));
            }
            let snapshot = Self::compute_snapshot(&food, grams_total);
            Some(RecomputedSnapshot {
                quantity,
                grams_total,
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
    /// `to_date`, **re-snapshotting** each from the current food + serving.
    ///
    /// The re-snapshot is the entire reason this is a server endpoint and
    /// not a client loop: if the user edited a custom food between the two
    /// dates, the destination entries reflect the *new* nutrition, not the
    /// source's frozen snapshot.
    ///
    /// Entries whose food is no longer visible to `user`, whose serving was
    /// deleted, or whose computed `grams_total` would overflow the
    /// `NUMERIC(8,2)` column are silently skipped — the response contains
    /// only the entries that were successfully inserted. Skips are logged at
    /// `tracing::info` so production has a paper trail; the wire envelope
    /// (`{ copied: [...] }`) is future-proofed so a `skipped` field can be
    /// added later without breaking existing clients.
    ///
    /// Both `from_date == to_date` (duplicate onto the same day) and
    /// `from_date > to_date` (backward copy) are legitimate. Pre-existing
    /// entries on `to_date` are *not* replaced — the copy coexists with
    /// them.
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
            // Re-resolve food. find_by_id returns None for "deleted or
            // cross-tenant" — both indistinguishable here, both skip.
            let Some(food) = self.foods.find_by_id(user, e.food_id).await? else {
                tracing::info!(
                    entry_id = %e.id,
                    food_id = %e.food_id,
                    "copy_day: skipping entry — food not visible",
                );
                continue;
            };

            // Without a serving id there's no way to recompute grams_total,
            // so we can't construct a fresh snapshot. v1 always populates
            // serving_id, but the column is nullable for forward-compat —
            // skip rather than guess.
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
            if serving.food_id != food.id {
                // Defensive: a serving reparented to a different food would
                // produce a wrong snapshot. Skip rather than 500.
                tracing::info!(
                    entry_id = %e.id,
                    serving_food = %serving.food_id,
                    entry_food = %food.id,
                    "copy_day: skipping entry — serving.food_id mismatch",
                );
                continue;
            }

            let grams_total = to_numeric_8_2(serving.grams * e.quantity);
            // Same overflow guard as `create` — silently skip rather than
            // fail the whole batch.
            if grams_total >= Decimal::new(100_000_000, 2) {
                tracing::info!(
                    entry_id = %e.id,
                    "copy_day: skipping entry — grams_total overflow",
                );
                continue;
            }
            let snapshot = Self::compute_snapshot(&food, grams_total);
            persisted.push(PersistedLogEntry {
                food_id: food.id,
                serving_id: Some(serving.id),
                consumed_on: to_date,
                meal: e.meal,
                quantity: e.quantity,
                grams_total,
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

    /// Paginated log entries for `user`, optionally filtered by date range.
    ///
    /// Returns a [`Paginated`] envelope with `total` set to the full match
    /// count so callers can page through results. Validates that `from <= to`
    /// when both are supplied, and delegates limit/offset defaulting to
    /// [`resolve_page_params`].
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
    pub async fn day_summary(&self, user: Uuid, on: NaiveDate) -> CoreResult<DaySummary> {
        let entries = self.logs.list_for_day(user, on).await?;
        let active_goal = self.goals.find_active_on(user, on).await?;

        // Build a per-meal accumulator for the four meals, then turn into a
        // Vec in canonical display order so the wire shape is stable.
        let mut by_meal_map: HashMap<Meal, MealSubtotal> = HashMap::new();
        for meal in Meal::all() {
            by_meal_map.insert(
                meal,
                MealSubtotal {
                    meal,
                    calories_kcal: Decimal::ZERO,
                    protein_g: Decimal::ZERO,
                    carbs_g: Decimal::ZERO,
                    fat_g: Decimal::ZERO,
                    entry_count: 0,
                },
            );
        }

        // Total accumulators. The required `calories_kcal` always sums to a
        // number; optional macros are "Some(sum) if at least one entry had a
        // value, else None" — `seen_*` tracks the "was anything present?" bit
        // so we can distinguish "no data" from "explicit zero."
        let mut total_calories = Decimal::ZERO;
        let mut total_protein = (Decimal::ZERO, false);
        let mut total_carbs = (Decimal::ZERO, false);
        let mut total_fat = (Decimal::ZERO, false);
        let mut total_fiber = (Decimal::ZERO, false);
        let mut total_sugar = (Decimal::ZERO, false);
        let mut total_sodium = (Decimal::ZERO, false);
        let mut total_satfat = (Decimal::ZERO, false);

        for entry in &entries {
            let subtotal = by_meal_map
                .get_mut(&entry.meal)
                .expect("seeded with all four meals");
            subtotal.calories_kcal += entry.snapshot.calories_kcal;
            if let Some(v) = entry.snapshot.protein_g {
                subtotal.protein_g += v;
            }
            if let Some(v) = entry.snapshot.carbs_g {
                subtotal.carbs_g += v;
            }
            if let Some(v) = entry.snapshot.fat_g {
                subtotal.fat_g += v;
            }
            subtotal.entry_count += 1;

            total_calories += entry.snapshot.calories_kcal;
            accumulate(&mut total_protein, entry.snapshot.protein_g);
            accumulate(&mut total_carbs, entry.snapshot.carbs_g);
            accumulate(&mut total_fat, entry.snapshot.fat_g);
            accumulate(&mut total_fiber, entry.snapshot.fiber_g);
            accumulate(&mut total_sugar, entry.snapshot.sugar_g);
            accumulate(&mut total_sodium, entry.snapshot.sodium_mg);
            accumulate(&mut total_satfat, entry.snapshot.saturated_fat_g);
        }

        let by_meal: Vec<MealSubtotal> = Meal::all()
            .into_iter()
            .map(|m| by_meal_map.remove(&m).expect("seeded above"))
            .collect();

        // The per-entry snapshots are already `NUMERIC(8,2)`, but `Decimal`
        // addition only preserves the *max* operand scale — `0 (scale=0) +
        // 250.00 (scale=2)` collapses trailing zeros on some operand orders.
        // Rescaling here keeps the wire shape stable. For the empty-day case
        // (no entries, no `.then_some(...)` triggered) the optionals stay
        // `None`; `calories_kcal` keeps `Decimal::ZERO`'s default rendering
        // ("0") so the empty-day response matches existing UX expectations.
        let total = if !entries.is_empty() {
            NutritionSnapshot {
                calories_kcal: to_numeric_8_2(total_calories),
                protein_g: total_protein.1.then(|| to_numeric_8_2(total_protein.0)),
                carbs_g: total_carbs.1.then(|| to_numeric_8_2(total_carbs.0)),
                fat_g: total_fat.1.then(|| to_numeric_8_2(total_fat.0)),
                fiber_g: total_fiber.1.then(|| to_numeric_8_2(total_fiber.0)),
                sugar_g: total_sugar.1.then(|| to_numeric_8_2(total_sugar.0)),
                sodium_mg: total_sodium.1.then(|| to_numeric_8_2(total_sodium.0)),
                saturated_fat_g: total_satfat.1.then(|| to_numeric_8_2(total_satfat.0)),
            }
        } else {
            NutritionSnapshot {
                calories_kcal: Decimal::ZERO,
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                sugar_g: None,
                sodium_mg: None,
                saturated_fat_g: None,
            }
        };

        Ok(DaySummary {
            date: on,
            total,
            by_meal,
            active_goal,
        })
    }

    #[tracing::instrument(skip(self))]
    pub async fn recent_foods(&self, user: Uuid, limit: i64) -> CoreResult<Vec<FoodSearchHit>> {
        let limit = clamp_recent_frequent_limit(limit);
        let ids = self.logs.recent_food_ids(user, limit).await?;
        self.hydrate_hits(user, ids).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn frequent_foods(&self, user: Uuid, limit: i64) -> CoreResult<Vec<FoodSearchHit>> {
        let limit = clamp_recent_frequent_limit(limit);
        let pairs = self
            .logs
            .frequent_food_ids(user, FREQUENT_WINDOW_DAYS, limit)
            .await?;
        // v1 is lossy: the repo returns `(food_id, count)` but the wire shape
        // for `FoodSearchHit` has nowhere to express the count. The ordering
        // is preserved (repo returns ranked by count desc), so the client
        // still sees "most frequent first" — only the count itself is dropped.
        let ids: Vec<Uuid> = pairs.into_iter().map(|(id, _count)| id).collect();
        self.hydrate_hits(user, ids).await
    }

    /// Walk a ranked list of food ids and hydrate each into a
    /// `FoodSearchHit`. Skips foods that are no longer visible (deleted or
    /// cross-tenant). Order is preserved.
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
                    grams: s.grams,
                });
            // calories_per_serving = energy_kcal * (grams/100), only if both
            // exist. Matches the search-hit semantics in `repo::food` for
            // production parity.
            let calories_per_serving = match (
                food.nutrition.energy_kcal,
                default_serving.as_ref().map(|s| s.grams),
            ) {
                (Some(kcal), Some(grams)) => Some((kcal * grams / Decimal::from(100)).round()),
                _ => None,
            };
            out.push(FoodSearchHit {
                id: food.id,
                source: food.source,
                name: food.name,
                brand: food.brands,
                barcode: food.barcode,
                default_serving,
                calories_per_serving,
            });
        }
        Ok(out)
    }
}

/// Round + pad a Decimal to exactly two fractional digits. This matches the
/// `NUMERIC(8,2)` columns the snapshot lands in, so the in-memory value
/// always serializes the same way Postgres would render it.
fn to_numeric_8_2(value: Decimal) -> Decimal {
    let mut v = value.round_dp(2);
    v.rescale(2);
    v
}

fn clamp_recent_frequent_limit(limit: i64) -> i64 {
    if limit <= 0 {
        RECENT_FREQUENT_DEFAULT_LIMIT
    } else {
        limit.min(RECENT_FREQUENT_MAX_LIMIT)
    }
}

fn accumulate(acc: &mut (Decimal, bool), value: Option<Decimal>) {
    if let Some(v) = value {
        acc.0 += v;
        acc.1 = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{FoodSource, NutritionPer100g};
    use chrono::Utc;

    fn food_with_nutrition(n: NutritionPer100g) -> Food {
        let now = Utc::now();
        Food {
            id: Uuid::new_v4(),
            source: FoodSource::Off,
            owner_user_id: None,
            barcode: None,
            fdc_id: None,
            data_type: None,
            name: "Test".into(),
            brands: None,
            categories_tags: vec![],
            nutrition: n,
            nutriscore_grade: None,
            quality_score: 0,
            extra_nutrients: None,
            last_import_batch_id: None,
            created_at: now,
            updated_at: now,
        }
    }

    fn dec(n: i64, scale: u32) -> Decimal {
        Decimal::new(n, scale)
    }

    #[test]
    fn test_compute_snapshot_scales_per_100g_to_grams_total() {
        // 200 g of a food with 50 kcal / 5 g protein per 100 g should
        // double the per-100g values.
        let food = food_with_nutrition(NutritionPer100g {
            energy_kcal: Some(dec(50, 0)),
            protein_g: Some(dec(5, 0)),
            carbs_g: Some(dec(10, 0)),
            fat_g: Some(dec(2, 0)),
            ..Default::default()
        });
        let snap = LogService::compute_snapshot(&food, dec(200, 0));
        assert_eq!(snap.calories_kcal, dec(10000, 2)); // 100.00
        assert_eq!(snap.protein_g, Some(dec(1000, 2))); // 10.00
        assert_eq!(snap.carbs_g, Some(dec(2000, 2))); // 20.00
        assert_eq!(snap.fat_g, Some(dec(400, 2))); // 4.00
    }

    #[test]
    fn test_compute_snapshot_converts_sodium_from_grams_to_milligrams() {
        // 1 g sodium per 100 g, scaled to 200 g → 2 g of sodium → 2000 mg.
        let food = food_with_nutrition(NutritionPer100g {
            energy_kcal: Some(dec(0, 0)),
            sodium_g: Some(dec(1, 0)),
            ..Default::default()
        });
        let snap = LogService::compute_snapshot(&food, dec(200, 0));
        assert_eq!(snap.sodium_mg, Some(dec(200000, 2))); // 2000.00 mg
    }

    #[test]
    fn test_compute_snapshot_passes_through_nullable_nutrients() {
        // Only energy_kcal set; all macros should remain None.
        let food = food_with_nutrition(NutritionPer100g {
            energy_kcal: Some(dec(100, 0)),
            ..Default::default()
        });
        let snap = LogService::compute_snapshot(&food, dec(150, 0));
        assert_eq!(snap.calories_kcal, dec(15000, 2)); // 150.00
        assert!(snap.protein_g.is_none());
        assert!(snap.carbs_g.is_none());
        assert!(snap.fat_g.is_none());
        assert!(snap.fiber_g.is_none());
        assert!(snap.sugar_g.is_none());
        assert!(snap.sodium_mg.is_none());
        assert!(snap.saturated_fat_g.is_none());
    }

    #[test]
    fn test_compute_snapshot_zero_calories_when_food_has_no_energy_kcal() {
        // calories_kcal is the snapshot's only required field. A food with
        // no energy_kcal must produce `Decimal::ZERO`, not panic.
        let food = food_with_nutrition(NutritionPer100g {
            energy_kcal: None,
            protein_g: Some(dec(5, 0)),
            ..Default::default()
        });
        let snap = LogService::compute_snapshot(&food, dec(100, 0));
        assert_eq!(snap.calories_kcal, Decimal::ZERO);
        assert_eq!(snap.protein_g, Some(dec(500, 2))); // 5.00
    }
}
