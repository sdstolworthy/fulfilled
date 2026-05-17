use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

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

/// Per-100g nutrition. All fields nullable to match the schema. Note that
/// `sodium_g` is grams of sodium per 100 g (OFF convention); the
/// `LogService::compute_snapshot` helper converts to mg when filling a log
/// entry's `sodium_mg` column.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NutritionPer100g {
    pub energy_kcal: Option<Decimal>,
    pub protein_g: Option<Decimal>,
    pub carbs_g: Option<Decimal>,
    pub fat_g: Option<Decimal>,
    pub fiber_g: Option<Decimal>,
    pub sugar_g: Option<Decimal>,
    pub sodium_g: Option<Decimal>,
    pub saturated_fat_g: Option<Decimal>,
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
    /// USDA FoodData Central record class: `foundation_food`, `sr_legacy_food`,
    /// `survey_fndds_food`, or `branded_food`. Populated only when
    /// `source = Usda`; the search rescore in 0004 differentiates rank
    /// caps by class. Not exposed on the wire today.
    pub data_type: Option<String>,
    pub name: String,
    pub brands: Option<String>,
    pub categories_tags: Vec<String>,
    pub nutrition: NutritionPer100g,
    pub nutriscore_grade: Option<NutriscoreGrade>,
    pub quality_score: i16,
    /// Long-tail nutrients (vitamins, minerals, water) not modeled as
    /// first-class columns. Stored as a JSON object keyed by USDA
    /// nutrient name. Currently only populated for `source = Usda`.
    pub extra_nutrients: Option<serde_json::Value>,
    pub last_import_batch_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Draft for creating a user-custom food. The composition of `Food` minus
/// the system-managed fields. Source is implicit `User`.
#[derive(Debug, Clone)]
pub struct FoodDraft {
    pub name: String,
    pub brands: Option<String>,
    pub barcode: Option<String>,
    pub categories_tags: Vec<String>,
    pub nutrition: NutritionPer100g,
    pub nutriscore_grade: Option<NutriscoreGrade>,
}

/// Patch shape for user-custom foods. `Option<T>` means "set if present,
/// leave alone if `None`." We do not support clearing fields back to
/// `NULL` in v1 — out of scope.
#[derive(Debug, Clone, Default)]
pub struct FoodPatch {
    pub name: Option<String>,
    pub brands: Option<String>,
    pub barcode: Option<String>,
    pub categories_tags: Option<Vec<String>>,
    pub nutrition: Option<NutritionPer100g>,
    pub nutriscore_grade: Option<NutriscoreGrade>,
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
    pub calories_per_serving: Option<Decimal>,
}

#[derive(Debug, Clone)]
pub struct ServingPreview {
    pub id: Uuid,
    pub label: String,
    pub grams: Decimal,
}
