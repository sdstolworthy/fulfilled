//! USDA FoodData Central JSONL source.
//!
//! The USDA bulk download (`FoodData_Central_*.json`) is a single large JSON
//! object with a top-level `"FoundationFoods"` / `"SRLegacyFoods"` / etc.
//! array. For the streaming ingest pipeline we expect the caller to have
//! already split the download into a newline-delimited file where each line is
//! one food object (matching the shape of an element from those arrays).
//!
//! Alternatively, the FDC "all foods" JSONL export (one JSON object per line)
//! can be fed directly. Each line must be a self-contained food object.
//!
//! Nutrient numbers used to identify per-100g values:
//! - 1008 → Energy (kcal)
//! - 1003 → Protein
//! - 1005 → Carbohydrate, by difference
//! - 1004 → Total lipid (fat)
//! - 1079 → Fiber, total dietary
//! - 2000 → Sugars, total including NLEA
//! - 1093 → Sodium, Na (reported in mg/100g by USDA)
//! - 1258 → Fatty acids, total saturated

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use loseit_core::service::{UsdaFoodPortion, UsdaFoodRecord, UsdaSource};
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use serde::Deserialize;
use tokio::fs::File;
use tokio::io::{AsyncBufReadExt, BufReader, Lines};

/// Newline-delimited USDA food source. Each line must be a single food object
/// from the FDC bulk export.
pub struct UsdaJsonlSource {
    lines: Lines<BufReader<File>>,
    path: PathBuf,
}

impl UsdaJsonlSource {
    /// Open a JSONL file at `path` and prepare it for line-by-line reads.
    pub async fn open<P: AsRef<Path>>(path: P) -> anyhow::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let file = File::open(&path).await?;
        // 1 MiB buffer — USDA records are large (many nutrient rows).
        let reader = BufReader::with_capacity(1024 * 1024, file);
        Ok(Self {
            lines: reader.lines(),
            path,
        })
    }
}

#[async_trait]
impl UsdaSource for UsdaJsonlSource {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<UsdaFoodRecord>>> {
        let mut out: Vec<UsdaFoodRecord> = Vec::with_capacity(n);
        let mut produced = 0usize;
        let mut hit_eof = true;
        while produced < n {
            match self.lines.next_line().await.map_err(|e| {
                loseit_core::CoreError::internal(format!("read {:?}: {e}", self.path))
            })? {
                Some(line) => {
                    hit_eof = false;
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                    match serde_json::from_str::<UsdaRaw>(trimmed) {
                        Ok(raw) => {
                            if let Some(record) = raw.into_record() {
                                out.push(record);
                                produced += 1;
                            }
                        }
                        Err(err) => {
                            tracing::warn!(
                                file = %self.path.display(),
                                error = %err,
                                "skipping unparseable USDA JSONL line"
                            );
                        }
                    }
                }
                None => break,
            }
        }
        if out.is_empty() && hit_eof {
            return Ok(None);
        }
        Ok(Some(out))
    }
}

// ---------------------------------------------------------------------------
// Raw deserialization structs
// ---------------------------------------------------------------------------

/// Permissive raw shape for a single USDA food. `#[serde(default)]` at the
/// struct level so missing fields become `None` / empty vec.
#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct UsdaRaw {
    fdc_id: Option<i64>,
    data_type: Option<String>,
    description: Option<String>,
    brand_owner: Option<String>,
    food_portions: Vec<RawFoodPortion>,
    food_nutrients: Vec<RawNutrient>,
    /// Branded foods carry serving info. `foodNutrients[]` itself is
    /// already per-100g (verified 2026-05-19 against live API + CSV
    /// bundle) — these fields aren't used for rescaling, just for
    /// future per-serving label emission.
    serving_size: Option<f64>,
    serving_size_unit: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct RawFoodPortion {
    gram_weight: Option<f64>,
    sequence_number: Option<i32>,
    measure_unit: Option<RawMeasureUnit>,
    /// Some FDC exports inline the measure unit name directly. In the
    /// Foundation Foods subset this is almost always empty (382/383
    /// portions); the human-readable label has to be composed from
    /// `value + measureUnit.name [+ modifier]`. When it IS present
    /// (the `Cheese, cheddar` row, for example) we take it verbatim.
    #[serde(rename = "portionDescription")]
    portion_description: Option<String>,
    /// FDC `modifier` — e.g. `"drained"`, `"whole"`, `"shredded"`.
    /// Appended to the composed label after `", "` when non-empty.
    modifier: Option<String>,
    /// FDC `value` — numeric quantity for the portion (e.g. `2.0`
    /// for "2 tablespoon"). Trailing zeros are trimmed in the label.
    value: Option<f64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct RawMeasureUnit {
    name: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct RawNutrient {
    nutrient: Option<RawNutrientMeta>,
    amount: Option<f64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct RawNutrientMeta {
    id: Option<i32>,
    number: Option<String>,
    name: Option<String>,
}

// USDA FDC nutrient IDs for the fields we care about.
const NUTRIENT_ENERGY_KCAL: i32 = 1008;
const NUTRIENT_PROTEIN: i32 = 1003;
const NUTRIENT_CARBS: i32 = 1005;
const NUTRIENT_FAT: i32 = 1004;
const NUTRIENT_FIBER: i32 = 1079;
const NUTRIENT_SUGAR: i32 = 2000;
const NUTRIENT_SODIUM_MG: i32 = 1093;
const NUTRIENT_SATURATED_FAT: i32 = 1258;

fn f64_to_decimal(v: f64) -> Option<Decimal> {
    if !v.is_finite() {
        return None;
    }
    Decimal::try_from(v).ok()
}

/// Render an FDC `value` (a float, almost always integer-valued) for inclusion
/// in a human label. Strips trailing zeros so `2.0` → `"2"`, `1.5` → `"1.5"`,
/// `0.5` → `"0.5"`. Non-finite or non-positive values are rejected upstream.
fn format_value_for_label(v: f64) -> String {
    // `{:.4}` is enough precision for FDC's typical 0.5 / 0.25 / 0.125 values
    // without exposing FP noise. We then strip trailing zeros and any
    // dangling decimal point.
    let mut s = format!("{:.4}", v);
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
    }
    s
}

/// Compose a human-readable serving label from a raw FDC portion.
///
/// Precedence:
/// 1. If `portionDescription` is set and is not empty / not the literal
///    string `"Quantity not specified"`, return it verbatim (trimmed).
/// 2. If the measureUnit name is `RACC` or `Undetermined`, return `None`.
///    (These portions are dropped upstream too; this guard is belt-and-braces
///    for cases where the unit name is *only* visible to the composer.)
/// 3. Otherwise compose `"{value} {measureUnit}[, {modifier}]"`, with
///    `value` rendered by [`format_value_for_label`]. Returns `None` if
///    `value` or the measureUnit name is missing — the caller falls back
///    to `formatAmountUnit` on the FE.
fn compose_label(p: &RawFoodPortion, measure_unit_name: Option<&str>) -> Option<String> {
    // 1. portionDescription wins when present.
    if let Some(pd) = p.portion_description.as_deref() {
        let t = pd.trim();
        if !t.is_empty() && !t.eq_ignore_ascii_case("quantity not specified") {
            return Some(t.to_string());
        }
    }
    // 2. RACC / Undetermined are not user-facing labels.
    let unit_name = measure_unit_name?.trim();
    if unit_name.is_empty()
        || unit_name.eq_ignore_ascii_case("racc")
        || unit_name.eq_ignore_ascii_case("undetermined")
    {
        return None;
    }
    // 3. Compose from value + unit + modifier.
    let value = p.value?;
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    let value_str = format_value_for_label(value);
    let mut s = format!("{} {}", value_str, unit_name);
    if let Some(m) = p.modifier.as_deref() {
        let m = m.trim();
        if !m.is_empty() {
            s.push_str(", ");
            s.push_str(m);
        }
    }
    Some(s)
}

impl UsdaRaw {
    fn into_record(self) -> Option<UsdaFoodRecord> {
        let fdc_id = self.fdc_id?;
        let description = self.description.unwrap_or_default();
        if description.trim().is_empty() {
            return None;
        }

        // Extract per-100g nutrient values by nutrient ID.
        let mut energy_kcal_100g: Option<Decimal> = None;
        let mut protein_100g: Option<Decimal> = None;
        let mut carbs_100g: Option<Decimal> = None;
        let mut fat_100g: Option<Decimal> = None;
        let mut fiber_100g: Option<Decimal> = None;
        let mut sugar_100g: Option<Decimal> = None;
        let mut sodium_mg_100g: Option<Decimal> = None;
        let mut saturated_fat_100g: Option<Decimal> = None;

        for n in &self.food_nutrients {
            let id = n.nutrient.as_ref().and_then(|m| m.id).unwrap_or_else(|| {
                // Fall back to parsing the string number field.
                n.nutrient
                    .as_ref()
                    .and_then(|m| m.number.as_deref())
                    .and_then(|s| s.trim().parse::<i32>().ok())
                    .unwrap_or(-1)
            });
            let amount = match n.amount.and_then(f64_to_decimal) {
                Some(v) => v,
                None => continue,
            };
            match id {
                NUTRIENT_ENERGY_KCAL => energy_kcal_100g = Some(amount),
                NUTRIENT_PROTEIN => protein_100g = Some(amount),
                NUTRIENT_CARBS => carbs_100g = Some(amount),
                NUTRIENT_FAT => fat_100g = Some(amount),
                NUTRIENT_FIBER => fiber_100g = Some(amount),
                NUTRIENT_SUGAR => sugar_100g = Some(amount),
                NUTRIENT_SODIUM_MG => sodium_mg_100g = Some(amount),
                NUTRIENT_SATURATED_FAT => saturated_fat_100g = Some(amount),
                _ => {}
            }
        }

        // Build food portions. F4-T1: compose a human-readable `label` from
        // the FDC pieces (portionDescription / value+measureUnit+modifier),
        // and drop any portion whose measureUnit.name is `RACC` (Reference
        // Amount Customarily Consumed — an FDA regulatory mass, not a
        // user-facing serving) or `Undetermined`.
        let food_portions: Vec<UsdaFoodPortion> = self
            .food_portions
            .into_iter()
            .filter_map(|p| {
                let gram_weight = p.gram_weight.and_then(f64_to_decimal)?;
                if gram_weight <= Decimal::ZERO {
                    return None;
                }
                // Extract the raw measureUnit name once — the composer needs
                // to inspect it for RACC drops, and we need it for the
                // remaining UsdaFoodPortion fields.
                let raw_unit_name: Option<String> = p
                    .measure_unit
                    .as_ref()
                    .and_then(|u| u.name.clone())
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty());
                // F4-T1: drop RACC / Undetermined portions entirely — they
                // duplicate the 100 g system serving in semantics.
                if let Some(ref name) = raw_unit_name {
                    if name.eq_ignore_ascii_case("racc")
                        || name.eq_ignore_ascii_case("undetermined")
                    {
                        return None;
                    }
                }
                let measure_unit_name = raw_unit_name
                    .clone()
                    .or_else(|| {
                        // Last-ditch: borrow portionDescription as the unit
                        // name only if we have nothing else.
                        p.portion_description
                            .as_deref()
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                    })
                    .unwrap_or_else(|| "gram".to_string());
                let label = compose_label(&p, raw_unit_name.as_deref());
                let sequence_number = p.sequence_number.unwrap_or(i32::MAX);
                Some(UsdaFoodPortion {
                    gram_weight,
                    measure_unit_name,
                    sequence_number,
                    label,
                })
            })
            .collect();

        Some(UsdaFoodRecord {
            fdc_id,
            data_type: self.data_type.unwrap_or_default(),
            description,
            brand_owner: self.brand_owner.filter(|s| !s.trim().is_empty()),
            food_portions,
            energy_kcal_100g,
            protein_100g,
            carbs_100g,
            fat_100g,
            fiber_100g,
            sugar_100g,
            sodium_mg_100g,
            saturated_fat_100g,
            serving_size: self.serving_size.and_then(f64_to_decimal),
            serving_size_unit: self
                .serving_size_unit
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        })
    }
}

// ---------------------------------------------------------------------------
// Tests (F4-T1: label composer)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a `RawFoodPortion` from a JSON snippet so the test inputs read
    /// like real FDC data. Returns the parsed portion.
    fn parse_portion(json: &str) -> RawFoodPortion {
        serde_json::from_str(json).expect("portion must parse")
    }

    /// Convenience: run `UsdaRaw::into_record` against a single-portion
    /// food and return the resulting `UsdaFoodPortion` list.
    fn portions_from_food(json: &str) -> Vec<UsdaFoodPortion> {
        let raw: UsdaRaw = serde_json::from_str(json).expect("food must parse");
        raw.into_record().expect("record must accept").food_portions
    }

    // ---- compose_label() composer cases (F4-BE §6b) ----

    /// `portionDescription` takes precedence over `value + measureUnit`
    /// when it is set and not empty / not "Quantity not specified".
    /// Mirrors the FDC `Cheese, cheddar` shape (fdcId 328637).
    #[test]
    #[allow(non_snake_case)]
    fn portionDescription_takes_precedence() {
        let p = parse_portion(
            r#"{
                "value": 1.0,
                "measureUnit": { "name": "piece" },
                "modifier": "ignored",
                "portionDescription": "1 drumstick"
            }"#,
        );
        let unit_name = p.measure_unit.as_ref().and_then(|u| u.name.as_deref());
        assert_eq!(compose_label(&p, unit_name).as_deref(), Some("1 drumstick"),);
    }

    /// `portionDescription == "Quantity not specified"` is treated as
    /// absent; composition falls through to value + measureUnit.
    #[test]
    #[allow(non_snake_case)]
    fn quantity_not_specified_treated_as_null() {
        let p = parse_portion(
            r#"{
                "value": 2.0,
                "measureUnit": { "name": "tablespoon" },
                "portionDescription": "Quantity not specified"
            }"#,
        );
        let unit_name = p.measure_unit.as_ref().and_then(|u| u.name.as_deref());
        assert_eq!(
            compose_label(&p, unit_name).as_deref(),
            Some("2 tablespoon"),
        );
    }

    /// Portions with `measureUnit.name == "RACC"` are dropped entirely
    /// from the resulting `food_portions` list (not just labelless).
    #[test]
    fn racc_portion_dropped() {
        let food = r#"{
            "fdcId": 9999,
            "dataType": "foundation_food",
            "description": "Test",
            "foodPortions": [
                {
                    "gramWeight": 30.0,
                    "value": 1.0,
                    "measureUnit": { "name": "RACC" },
                    "sequenceNumber": 1
                },
                {
                    "gramWeight": 15.0,
                    "value": 1.0,
                    "measureUnit": { "name": "tablespoon" },
                    "sequenceNumber": 2
                }
            ]
        }"#;
        let portions = portions_from_food(food);
        assert_eq!(
            portions.len(),
            1,
            "RACC portion must be dropped, leaving only the tablespoon"
        );
        assert_eq!(portions[0].measure_unit_name, "tablespoon");
        assert_eq!(portions[0].label.as_deref(), Some("1 tablespoon"));
    }

    /// `value + measureUnit + modifier` composes with a `", "` separator
    /// before the modifier. Mirrors `Beans, snap, green, canned` (fdcId 321611).
    #[test]
    fn value_modifier_composition() {
        let p = parse_portion(
            r#"{
                "value": 1.0,
                "measureUnit": { "name": "cup" },
                "modifier": "drained"
            }"#,
        );
        let unit_name = p.measure_unit.as_ref().and_then(|u| u.name.as_deref());
        assert_eq!(
            compose_label(&p, unit_name).as_deref(),
            Some("1 cup, drained"),
        );
    }

    /// `value: 2.0` renders as `"2"` (no trailing zero / decimal point).
    /// `value: 1.5` keeps the fractional digit.
    #[test]
    fn value_trailing_zero_trimmed() {
        let p = parse_portion(
            r#"{
                "value": 2.0,
                "measureUnit": { "name": "tablespoon" }
            }"#,
        );
        let unit_name = p.measure_unit.as_ref().and_then(|u| u.name.as_deref());
        let label = compose_label(&p, unit_name).expect("must compose");
        assert!(
            label.starts_with("2 "),
            "label `{label}` must start with `2 ` (no trailing `.0`)"
        );
        assert_eq!(label, "2 tablespoon");

        let p_half = parse_portion(
            r#"{
                "value": 1.5,
                "measureUnit": { "name": "cup" }
            }"#,
        );
        let unit_name = p_half.measure_unit.as_ref().and_then(|u| u.name.as_deref());
        assert_eq!(
            compose_label(&p_half, unit_name).as_deref(),
            Some("1.5 cup"),
        );
    }

    /// Empty (or missing) measureUnit name yields no label — caller
    /// falls back to formatAmountUnit. The portion still survives (it
    /// becomes a gram-typed serving).
    #[test]
    fn empty_measure_unit_name() {
        let p = parse_portion(
            r#"{
                "value": 1.0,
                "measureUnit": { "name": "" }
            }"#,
        );
        let unit_name = p
            .measure_unit
            .as_ref()
            .and_then(|u| u.name.as_deref())
            .filter(|s| !s.trim().is_empty());
        assert!(
            compose_label(&p, unit_name).is_none(),
            "empty measureUnit.name must yield no label"
        );

        // Round-trip through into_record(): the portion still surfaces
        // (gram-typed fallback), just with no label.
        let food = r#"{
            "fdcId": 8888,
            "dataType": "foundation_food",
            "description": "Test",
            "foodPortions": [{
                "gramWeight": 14.2,
                "value": 1.0,
                "measureUnit": { "name": "" }
            }]
        }"#;
        let portions = portions_from_food(food);
        assert_eq!(portions.len(), 1);
        assert!(portions[0].label.is_none());
        // measure_unit_name falls back to "gram".
        assert_eq!(portions[0].measure_unit_name, "gram");
    }

    /// `Undetermined` is also a regulatory pseudo-unit; portions with
    /// `measureUnit.name = "Undetermined"` are dropped.
    #[test]
    fn undetermined_portion_dropped() {
        let food = r#"{
            "fdcId": 7777,
            "dataType": "foundation_food",
            "description": "Test",
            "foodPortions": [{
                "gramWeight": 50.0,
                "value": 1.0,
                "measureUnit": { "name": "Undetermined" }
            }]
        }"#;
        // Only this portion is present, and it's Undetermined, so the
        // resulting list is empty.
        let portions = portions_from_food(food);
        assert!(portions.is_empty());
    }

    /// `format_value_for_label` smoke-tests for fractional values seen
    /// in the real FDC export.
    #[test]
    fn format_value_for_label_cases() {
        assert_eq!(format_value_for_label(2.0), "2");
        assert_eq!(format_value_for_label(1.0), "1");
        assert_eq!(format_value_for_label(0.5), "0.5");
        assert_eq!(format_value_for_label(1.5), "1.5");
        assert_eq!(format_value_for_label(0.25), "0.25");
    }
}
