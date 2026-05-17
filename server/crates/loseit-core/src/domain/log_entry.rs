use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::meal::Meal;

/// Nutrition values snapshotted onto a single log entry. `calories_kcal`
/// is required (NOT NULL in the schema); everything else is optional. The
/// service computes these from the food's per-100g columns scaled by
/// `grams_total / 100`, and converts sodium from grams (food.sodium_g) to
/// milligrams (snapshot.sodium_mg).
#[derive(Debug, Clone)]
pub struct NutritionSnapshot {
    pub calories_kcal: Decimal,
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
    pub sugar_g: Option<Decimal>,
    pub sodium_mg: Option<Decimal>,
    pub saturated_fat_g: Option<Decimal>,
}

#[derive(Debug, Clone)]
pub struct FoodLogEntry {
    pub id: Uuid,
    pub user_id: Uuid,
    pub food_id: Uuid,
    pub food_name: String,
    pub serving_id: Option<Uuid>,
    pub serving_name: Option<String>,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub quantity: Decimal,
    pub grams_total: Decimal,
    pub snapshot: NutritionSnapshot,
    pub note: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Handler-facing draft. Service computes `grams_total` and the snapshot
/// before persisting.
#[derive(Debug, Clone)]
pub struct LogDraft {
    pub food_id: Uuid,
    pub serving_id: Uuid,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub quantity: Decimal,
    pub note: Option<String>,
}

/// Handler-facing patch. Service decides whether the snapshot needs
/// recomputation (any change to `serving_id` or `quantity` triggers it).
#[derive(Debug, Clone, Default)]
pub struct LogPatch {
    pub serving_id: Option<Uuid>,
    pub consumed_on: Option<NaiveDate>,
    pub meal: Option<Meal>,
    pub quantity: Option<Decimal>,
    pub note: Option<Option<String>>,
}

/// Repo-facing persisted shape — the snapshot has already been computed.
/// Repositories are dumb storage; they trust this struct's values.
#[derive(Debug, Clone)]
pub struct PersistedLogEntry {
    pub food_id: Uuid,
    pub serving_id: Option<Uuid>,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub quantity: Decimal,
    pub grams_total: Decimal,
    pub snapshot: NutritionSnapshot,
    pub note: Option<String>,
}

/// Repo-facing patch. `serving_id`, `consumed_on`, `meal`, `note` are
/// pass-through; `quantity_and_grams_total` and `snapshot` are bundled so
/// repos cannot persist a quantity change without the matching recomputed
/// snapshot — a safety property the type system enforces.
#[derive(Debug, Clone, Default)]
pub struct PersistedLogPatch {
    pub serving_id: Option<Uuid>,
    pub consumed_on: Option<NaiveDate>,
    pub meal: Option<Meal>,
    pub note: Option<Option<String>>,
    pub recompute: Option<RecomputedSnapshot>,
}

#[derive(Debug, Clone)]
pub struct RecomputedSnapshot {
    pub quantity: Decimal,
    pub grams_total: Decimal,
    pub snapshot: NutritionSnapshot,
}
