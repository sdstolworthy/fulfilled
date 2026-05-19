//! Day-summary service.
//!
//! Audit-fix R3: this used to live as `LogService::day_summary`, which forced
//! `LogService` to carry a `GoalRepository` it didn't use anywhere else. The
//! computation is a fan-out across log entries + active-goal lookup that
//! belongs at the orchestration layer above either service.
//!
//! Composing both repositories here (instead of in either single-domain
//! service) keeps each domain service narrow — `LogService` no longer needs
//! to know that goals exist, and `GoalService` doesn't grow a summarisation
//! responsibility.

use std::collections::HashMap;
use std::sync::Arc;

use chrono::NaiveDate;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::{DaySummary, Meal, MealSubtotal, NutritionSnapshot};
use crate::repo::{GoalRepository, LogRepository};
use crate::CoreResult;

pub struct DaySummaryService {
    logs: Arc<dyn LogRepository>,
    goals: Arc<dyn GoalRepository>,
}

impl DaySummaryService {
    pub fn new(logs: Arc<dyn LogRepository>, goals: Arc<dyn GoalRepository>) -> Self {
        Self { logs, goals }
    }

    /// Build the summary the FE renders on the home screen — per-meal
    /// subtotals + grand-total nutrition + the active goal (if any).
    #[tracing::instrument(skip(self))]
    pub async fn for_day(&self, user: Uuid, on: NaiveDate) -> CoreResult<DaySummary> {
        let entries = self.logs.list_for_day(user, on).await?;
        let active_goal = self.goals.find_active_on(user, on).await?;

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
}

fn accumulate(acc: &mut (Decimal, bool), value: Option<Decimal>) {
    if let Some(v) = value {
        acc.0 += v;
        acc.1 = true;
    }
}

fn to_numeric_8_2(value: Decimal) -> Decimal {
    let mut v = value.round_dp(2);
    v.rescale(2);
    v
}
