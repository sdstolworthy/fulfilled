use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::serving::ServingDraft;
use crate::domain::unit::Unit;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoodSource {
    Off,
    User,
    Usda,
}

impl FoodSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::User => "user",
            Self::Usda => "usda",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "off" => Some(Self::Off),
            "user" => Some(Self::User),
            "usda" => Some(Self::Usda),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FoodKind {
    Normal,
    QuickAdd,
}

impl FoodKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Normal   => "normal",
            Self::QuickAdd => "quick_add",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "normal"    => Some(Self::Normal),
            "quick_add" => Some(Self::QuickAdd),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NutriscoreGrade {
    A,
    B,
    C,
    D,
    E,
}

impl NutriscoreGrade {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::A => "a",
            Self::B => "b",
            Self::C => "c",
            Self::D => "d",
            Self::E => "e",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "a" => Some(Self::A),
            "b" => Some(Self::B),
            "c" => Some(Self::C),
            "d" => Some(Self::D),
            "e" => Some(Self::E),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Food {
    pub id: Uuid,
    pub source: FoodSource,
    pub kind: FoodKind,
    pub owner_user_id: Option<Uuid>,
    pub barcode: Option<String>,
    /// USDA FoodData Central per-record key. Set only when `source = Usda`.
    pub fdc_id: Option<i64>,
    /// USDA FoodData Central record class. Populated only when `source = Usda`.
    pub data_type: Option<String>,
    pub name: String,
    pub brands: Option<String>,
    pub categories_tags: Vec<String>,
    pub nutriscore_grade: Option<NutriscoreGrade>,
    pub quality_score: i16,
    /// Long-tail nutrients stored as a JSON object keyed by USDA nutrient name.
    pub extra_nutrients: Option<serde_json::Value>,
    pub last_import_batch_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Draft for creating a user-custom food. Source is implicit `User`.
/// `servings` must contain at least one element (service-validated).
#[derive(Debug, Clone)]
pub struct FoodDraft {
    pub name: String,
    pub brands: Option<String>,
    pub barcode: Option<String>,
    pub categories_tags: Vec<String>,
    pub nutriscore_grade: Option<NutriscoreGrade>,
    pub servings: Vec<ServingDraft>, // at least one required (service-validated)
}

/// Patch shape for user-custom foods.
#[derive(Debug, Clone, Default)]
pub struct FoodPatch {
    pub name: Option<String>,
    pub brands: Option<String>,
    pub barcode: Option<String>,
    pub categories_tags: Option<Vec<String>>,
    pub nutriscore_grade: Option<NutriscoreGrade>,
    pub servings: Option<Vec<ServingDraft>>, // full-list replace when present
}

/// Lean projection used by `/foods/search`, `/foods/recent`, and
/// `/foods/frequent`. The default serving is included so clients can
/// render "X calories per serving" without a second request.
#[derive(Debug, Clone)]
pub struct FoodSearchHit {
    pub id: Uuid,
    pub source: FoodSource,
    pub name: String,
    pub brand: Option<String>,
    pub barcode: Option<String>,
    pub default_serving: Option<ServingPreview>,
}

#[derive(Debug, Clone)]
pub struct ServingPreview {
    pub id: Uuid,
    pub label: Option<String>,
    pub amount: Decimal,
    pub unit: Unit,
    pub kcal: Decimal,
}
