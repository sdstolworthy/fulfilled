use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
