use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct Goal {
    pub id: Uuid,
    pub user_id: Uuid,
    pub starts_on: NaiveDate,
    pub ends_on: Option<NaiveDate>,
    pub start_weight_kg: Option<Decimal>,
    pub target_weight_kg: Option<Decimal>,
    pub weekly_rate_kg: Option<Decimal>,
    pub daily_calorie_target: Option<i32>,
    pub protein_g_target: Option<Decimal>,
    pub carbs_g_target: Option<Decimal>,
    pub fat_g_target: Option<Decimal>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct GoalDraft {
    pub starts_on: NaiveDate,
    pub ends_on: Option<NaiveDate>,
    pub start_weight_kg: Option<Decimal>,
    pub target_weight_kg: Option<Decimal>,
    pub weekly_rate_kg: Option<Decimal>,
    pub daily_calorie_target: Option<i32>,
    pub protein_g_target: Option<Decimal>,
    pub carbs_g_target: Option<Decimal>,
    pub fat_g_target: Option<Decimal>,
}

#[derive(Debug, Clone, Default)]
pub struct GoalPatch {
    pub starts_on: Option<NaiveDate>,
    pub ends_on: Option<NaiveDate>,
    pub start_weight_kg: Option<Decimal>,
    pub target_weight_kg: Option<Decimal>,
    pub weekly_rate_kg: Option<Decimal>,
    pub daily_calorie_target: Option<i32>,
    pub protein_g_target: Option<Decimal>,
    pub carbs_g_target: Option<Decimal>,
    pub fat_g_target: Option<Decimal>,
}
