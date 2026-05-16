use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct Weight {
    pub id: Uuid,
    pub user_id: Uuid,
    pub recorded_on: NaiveDate,
    pub recorded_at_local: Option<NaiveTime>,
    pub weight_kg: Decimal,
    pub note: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct WeightDraft {
    pub recorded_on: NaiveDate,
    pub recorded_at_local: Option<NaiveTime>,
    pub weight_kg: Decimal,
    pub note: Option<String>,
}
