use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::meal::Meal;
use crate::domain::unit::Unit;

/// Nutrition values snapshotted onto a single log entry. `calories_kcal`
/// is required (NOT NULL in the schema); everything else is optional.
/// Computed as `quantity * serving.<nutrient>`. No per-100g math; no g↔mg
/// conversion — `sodium_mg` is mg-native on the serving row.
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
    pub entered_amount: Decimal, // what the user typed at entry time
    pub entered_unit: Unit,      // what the user typed at entry time
    pub snapshot: NutritionSnapshot,
    pub note: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Handler-facing draft. Service derives `quantity` from
/// `entered_amount` / `entered_unit` + the serving's `{amount, unit}`.
#[derive(Debug, Clone)]
pub struct LogDraft {
    pub food_id: Uuid,
    pub serving_id: Uuid,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub entered_amount: Decimal, // required from the wire
    pub entered_unit: Unit,      // required from the wire
    pub note: Option<String>,
}

/// Handler-facing patch. Service re-runs the conversion pipeline when
/// `entered_amount`, `entered_unit`, or `serving_id` changes.
#[derive(Debug, Clone, Default)]
pub struct LogPatch {
    pub serving_id: Option<Uuid>,
    pub consumed_on: Option<NaiveDate>,
    pub meal: Option<Meal>,
    pub entered_amount: Option<Decimal>,
    pub entered_unit: Option<Unit>,
    pub note: Option<Option<String>>,
}

/// Repo-facing persisted shape — snapshot has already been computed.
/// Repositories are dumb storage; they trust this struct's values.
#[derive(Debug, Clone)]
pub struct PersistedLogEntry {
    pub food_id: Uuid,
    pub serving_id: Option<Uuid>,
    pub consumed_on: NaiveDate,
    pub meal: Meal,
    pub quantity: Decimal,
    pub entered_amount: Decimal,
    pub entered_unit: Unit,
    pub snapshot: NutritionSnapshot,
    pub note: Option<String>,
}

/// Repo-facing patch. `serving_id`, `consumed_on`, `meal`, `note` are
/// pass-through; `recompute` bundles `quantity` + `entered_amount` +
/// `entered_unit` + `snapshot` atomically so repos cannot persist a
/// quantity change without the matching recomputed snapshot.
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
    pub entered_amount: Decimal,
    pub entered_unit: Unit,
    pub snapshot: NutritionSnapshot,
}
