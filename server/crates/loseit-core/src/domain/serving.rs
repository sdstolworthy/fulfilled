use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::unit::Unit;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ServingSource {
    Off,
    Usda,
    User,
    System,
}

impl ServingSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off    => "off",
            Self::Usda   => "usda",
            Self::User   => "user",
            Self::System => "system",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "off"    => Some(Self::Off),
            "usda"   => Some(Self::Usda),
            "user"   => Some(Self::User),
            "system" => Some(Self::System),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Serving {
    pub id: Uuid,
    pub food_id: Uuid,
    pub label: Option<String>,          // nullable; FE/user-supplied descriptor
    pub amount: Decimal,
    pub unit: Unit,
    pub kcal: Decimal,                  // required
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
    pub sugar_g: Option<Decimal>,
    pub sodium_mg: Option<Decimal>,     // mg-native; no g↔mg conversion
    pub saturated_fat_g: Option<Decimal>,
    pub is_default: bool,
    pub source: ServingSource,
    pub sort_order: i32,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct ServingDraft {
    pub label: Option<String>,
    pub amount: Decimal,
    pub unit: Unit,
    pub kcal: Decimal,
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
    pub sugar_g: Option<Decimal>,
    pub sodium_mg: Option<Decimal>,
    pub saturated_fat_g: Option<Decimal>,
    pub is_default: bool,
    pub source: ServingSource,
    pub sort_order: i32,
}

/// Patch shape for servings. `Option<T>` = "set if present, leave alone if
/// `None`". `Option<Option<T>>` = nullable patch: outer `None` means "don't
/// touch", inner `None` means "set to NULL".
#[derive(Debug, Clone, Default)]
pub struct ServingPatch {
    pub label: Option<Option<String>>,          // double-Option = nullable patch
    pub amount: Option<Decimal>,
    pub unit: Option<Unit>,
    pub kcal: Option<Decimal>,
    pub protein_g: Option<Option<Decimal>>,
    pub carbs_g: Option<Option<Decimal>>,
    pub fat_g: Option<Option<Decimal>>,
    pub fiber_g: Option<Option<Decimal>>,
    pub sugar_g: Option<Option<Decimal>>,
    pub sodium_mg: Option<Option<Decimal>>,
    pub saturated_fat_g: Option<Option<Decimal>>,
    pub sort_order: Option<i32>,
}
