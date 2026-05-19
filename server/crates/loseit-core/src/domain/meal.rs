use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Serialize};

/// Wire form is the kebab-case canonical name (`breakfast` / `lunch` /
/// `dinner` / `snack`). `try_from = "&str"` routes the wire string
/// through [`Meal::from_str`] so the same validation runs whether the
/// value arrives via HTTP, file ingest, or a test fixture — handlers
/// no longer need their own `parse_meal` helper.
///
/// Serialization mirrors deserialization: every Serialize call site
/// (response bodies, structured logs) reads [`Meal::as_str`], so the
/// wire shape stays canonical without callers having to remember.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "&str", into = "&'static str")]
pub enum Meal {
    Breakfast,
    Lunch,
    Dinner,
    Snack,
}

impl Meal {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Breakfast => "breakfast",
            Self::Lunch => "lunch",
            Self::Dinner => "dinner",
            Self::Snack => "snack",
        }
    }

    /// All meal variants, in canonical display order. Used by the day
    /// summary to always emit a slot per meal even when no entries fall
    /// in it.
    pub fn all() -> [Meal; 4] {
        [Meal::Breakfast, Meal::Lunch, Meal::Dinner, Meal::Snack]
    }
}

impl fmt::Display for Meal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidMeal;

impl fmt::Display for InvalidMeal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid meal")
    }
}

impl std::error::Error for InvalidMeal {}

impl FromStr for Meal {
    type Err = InvalidMeal;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "breakfast" => Ok(Self::Breakfast),
            "lunch" => Ok(Self::Lunch),
            "dinner" => Ok(Self::Dinner),
            "snack" => Ok(Self::Snack),
            _ => Err(InvalidMeal),
        }
    }
}

impl TryFrom<&str> for Meal {
    type Error = InvalidMeal;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        value.parse()
    }
}

impl From<Meal> for &'static str {
    fn from(m: Meal) -> Self {
        m.as_str()
    }
}
