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
}

#[derive(Debug, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct RawFoodPortion {
    gram_weight: Option<f64>,
    sequence_number: Option<i32>,
    measure_unit: Option<RawMeasureUnit>,
    /// Some FDC exports inline the measure unit name directly.
    #[serde(rename = "portionDescription")]
    portion_description: Option<String>,
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

        // Build food portions.
        let food_portions: Vec<UsdaFoodPortion> = self
            .food_portions
            .into_iter()
            .filter_map(|p| {
                let gram_weight = p.gram_weight.and_then(f64_to_decimal)?;
                if gram_weight <= Decimal::ZERO {
                    return None;
                }
                // Prefer measureUnit.name, fall back to portionDescription.
                let measure_unit_name = p
                    .measure_unit
                    .and_then(|u| u.name)
                    .filter(|s| !s.trim().is_empty())
                    .or(p.portion_description)
                    .unwrap_or_else(|| "gram".to_string());
                let sequence_number = p.sequence_number.unwrap_or(i32::MAX);
                Some(UsdaFoodPortion {
                    gram_weight,
                    measure_unit_name,
                    sequence_number,
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
        })
    }
}
