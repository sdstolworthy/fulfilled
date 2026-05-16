use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

/// External-provider identity. `(issuer, external_id)` is the stable handle
/// on a person — the same shape we persist on the `users` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserIdentity {
    pub issuer: String,
    pub external_id: String,
    pub email: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sex {
    Male,
    Female,
    Other,
}

impl Sex {
    pub fn as_str(self) -> &'static str {
        match self {
            Sex::Male => "male",
            Sex::Female => "female",
            Sex::Other => "other",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "male" => Some(Self::Male),
            "female" => Some(Self::Female),
            "other" => Some(Self::Other),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityLevel {
    Sedentary,
    Light,
    Moderate,
    Active,
    VeryActive,
}

impl ActivityLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            ActivityLevel::Sedentary => "sedentary",
            ActivityLevel::Light => "light",
            ActivityLevel::Moderate => "moderate",
            ActivityLevel::Active => "active",
            ActivityLevel::VeryActive => "very_active",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "sedentary" => Some(Self::Sedentary),
            "light" => Some(Self::Light),
            "moderate" => Some(Self::Moderate),
            "active" => Some(Self::Active),
            "very_active" => Some(Self::VeryActive),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct User {
    pub id: Uuid,
    pub identity: UserIdentity,
    pub sex: Option<Sex>,
    pub birth_date: Option<NaiveDate>,
    pub height_cm: Option<Decimal>,
    pub activity_level: Option<ActivityLevel>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// Fields a client can change on its own profile. Each option that is `None`
/// means "leave alone." To clear a value, the API layer should translate it
/// into an explicit `Some(None)` — but for now we keep this simple and treat
/// every field as set-or-leave.
#[derive(Debug, Clone, Default)]
pub struct ProfilePatch {
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub sex: Option<Sex>,
    pub birth_date: Option<NaiveDate>,
    pub height_cm: Option<Decimal>,
    pub activity_level: Option<ActivityLevel>,
}
