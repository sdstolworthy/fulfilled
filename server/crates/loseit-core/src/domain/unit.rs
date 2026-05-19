use std::fmt;
use std::str::FromStr;

use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};

/// Wire form is the canonical short label (`g` / `kg` / `oz` / …).
/// Same rationale as [`crate::Meal`]: `try_from` routes deserialization
/// through [`Unit::from_str`], so handlers stop carrying a `parse_unit`
/// helper that surfaces a bespoke `invalid_unit` error code. Bad
/// strings now fail at the serde layer with a clear "unknown variant"
/// message and HTTP 400, which is what every consumer was already
/// branching on anyway (no client code looks at the structured
/// `invalid_unit` code).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "&str", into = "&'static str")]
pub enum Unit {
    // Mass
    Gram,
    Kilogram,
    Ounce,
    Pound,
    // Volume
    Milliliter,
    Liter,
    Cup,
    FluidOunce,
    Tablespoon,
    Teaspoon,
    // Count
    Serving,
    Piece,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnitFamily {
    Mass,
    Volume,
    Count,
}

impl Unit {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Gram => "g",
            Self::Kilogram => "kg",
            Self::Ounce => "oz",
            Self::Pound => "lb",
            Self::Milliliter => "ml",
            Self::Liter => "l",
            Self::Cup => "cup",
            Self::FluidOunce => "fl_oz",
            Self::Tablespoon => "tbsp",
            Self::Teaspoon => "tsp",
            Self::Serving => "serving",
            Self::Piece => "piece",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "g" => Some(Self::Gram),
            "kg" => Some(Self::Kilogram),
            "oz" => Some(Self::Ounce),
            "lb" => Some(Self::Pound),
            "ml" => Some(Self::Milliliter),
            "l" => Some(Self::Liter),
            "cup" => Some(Self::Cup),
            "fl_oz" => Some(Self::FluidOunce),
            "tbsp" => Some(Self::Tablespoon),
            "tsp" => Some(Self::Teaspoon),
            "serving" => Some(Self::Serving),
            "piece" => Some(Self::Piece),
            _ => None,
        }
    }

    pub fn family(self) -> UnitFamily {
        match self {
            Self::Gram | Self::Kilogram | Self::Ounce | Self::Pound => UnitFamily::Mass,
            Self::Milliliter
            | Self::Liter
            | Self::Cup
            | Self::FluidOunce
            | Self::Tablespoon
            | Self::Teaspoon => UnitFamily::Volume,
            Self::Serving | Self::Piece => UnitFamily::Count,
        }
    }

    /// Ratio to the family canonical (g for Mass, ml for Volume, identity for Count).
    /// Decimal literals are exact per §D3 of the design.
    pub fn ratio_to_canonical(self) -> Decimal {
        match self {
            // Mass — canonical g
            Self::Gram => dec!(1),
            Self::Kilogram => dec!(1000),
            Self::Ounce => dec!(28.349523125),
            Self::Pound => dec!(453.59237),
            // Volume — canonical ml
            Self::Milliliter => dec!(1),
            Self::Liter => dec!(1000),
            Self::Cup => dec!(236.5882365),
            Self::FluidOunce => dec!(29.5735295625),
            Self::Tablespoon => dec!(14.78676478125),
            Self::Teaspoon => dec!(4.92892159375),
            // Count — each is its own canonical (no auto-conversion)
            Self::Serving | Self::Piece => dec!(1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidUnit;

impl fmt::Display for InvalidUnit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("invalid unit")
    }
}

impl std::error::Error for InvalidUnit {}

impl FromStr for Unit {
    type Err = InvalidUnit;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s).ok_or(InvalidUnit)
    }
}

impl TryFrom<&str> for Unit {
    type Error = InvalidUnit;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        value.parse()
    }
}

impl From<Unit> for &'static str {
    fn from(u: Unit) -> Self {
        u.as_str()
    }
}

impl fmt::Display for Unit {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
