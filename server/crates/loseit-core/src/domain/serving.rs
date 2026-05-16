use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServingSource {
    Off,
    User,
    System,
}

impl ServingSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::User => "user",
            Self::System => "system",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "off" => Some(Self::Off),
            "user" => Some(Self::User),
            "system" => Some(Self::System),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Serving {
    pub id: Uuid,
    pub food_id: Uuid,
    pub label: String,
    pub grams: Decimal,
    pub is_default: bool,
    pub source: ServingSource,
    pub sort_order: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct ServingDraft {
    pub label: String,
    pub grams: Decimal,
    pub is_default: bool,
    pub source: ServingSource,
    pub sort_order: i32,
}

/// Patch shape for servings. There is intentionally no `is_default` here —
/// flipping the default uses the atomic `ServingRepository::set_default`
/// method so the partial unique index invariant always holds.
#[derive(Debug, Clone, Default)]
pub struct ServingPatch {
    pub label: Option<String>,
    pub grams: Option<Decimal>,
    pub sort_order: Option<i32>,
}
