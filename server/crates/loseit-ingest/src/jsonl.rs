//! Newline-delimited-JSON source for the OFF bulk export.
//!
//! OFF's JSONL is wildly heterogeneous: missing fields, fields with the
//! wrong type, products with no nutrition data at all. We use a fully
//! `#[serde(default)]` raw struct so any individual line can be parsed
//! without losing the whole file; lines that fail to parse outright are
//! logged at `WARN` and skipped (the ingest service counts them
//! implicitly via `chunk.len() - accepted.len()`).
//!
//! Nutrient keys in OFF use dashes and pluralization that don't match
//! our normalized field names — e.g. `energy-kcal_100g`, `proteins_100g`,
//! `sugars_100g`. The raw struct uses `#[serde(rename = "...")]` to
//! bridge that.

use std::path::{Path, PathBuf};
use std::str::FromStr;

use async_trait::async_trait;
use loseit_core::service::{FoodRecordSource, OffFoodRecord};
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use serde::Deserialize;
use tokio::fs::File;
use tokio::io::{AsyncBufReadExt, BufReader, Lines};

/// Newline-delimited-JSON source. Each line is a single OFF product.
pub struct JsonlSource {
    lines: Lines<BufReader<File>>,
    path: PathBuf,
}

impl JsonlSource {
    /// Open a JSONL file at `path` and prepare it for line-by-line reads.
    pub async fn open<P: AsRef<Path>>(path: P) -> anyhow::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let file = File::open(&path).await?;
        // 1 MiB buffer keeps the per-line allocations cheap on the OFF
        // dump (some product records are >100 KiB on disk).
        let reader = BufReader::with_capacity(1024 * 1024, file);
        Ok(Self {
            lines: reader.lines(),
            path,
        })
    }
}

#[async_trait]
impl FoodRecordSource for JsonlSource {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<OffFoodRecord>>> {
        let mut out: Vec<OffFoodRecord> = Vec::with_capacity(n);
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
                    match serde_json::from_str::<OffRaw>(trimmed) {
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
                                "skipping unparseable OFF JSONL line"
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

/// Permissive raw shape for a single OFF product. `#[serde(default)]`
/// at the struct level so every field is optional — OFF lines routinely
/// omit half of these.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct OffRaw {
    code: Option<String>,
    product_name: Option<String>,
    brands: Option<String>,
    categories_tags: Vec<String>,
    nutriscore_grade: Option<String>,
    completeness: Option<f64>,
    serving_size: Option<String>,
    serving_quantity: Option<StringOrNumber>,
    nutriments: Option<RawNutriments>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RawNutriments {
    #[serde(rename = "energy-kcal_100g")]
    energy_kcal_100g: Option<f64>,
    #[serde(rename = "proteins_100g")]
    proteins_100g: Option<f64>,
    #[serde(rename = "carbohydrates_100g")]
    carbohydrates_100g: Option<f64>,
    #[serde(rename = "fat_100g")]
    fat_100g: Option<f64>,
    #[serde(rename = "fiber_100g")]
    fiber_100g: Option<f64>,
    #[serde(rename = "sugars_100g")]
    sugars_100g: Option<f64>,
    #[serde(rename = "sodium_100g")]
    sodium_100g: Option<f64>,
    #[serde(rename = "saturated-fat_100g")]
    saturated_fat_100g: Option<f64>,
}

/// OFF sometimes serializes `serving_quantity` as a number, sometimes as
/// a string (e.g. `"45"` vs `45`). This enum absorbs both.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum StringOrNumber {
    Number(f64),
    String(String),
}

impl StringOrNumber {
    fn as_decimal(&self) -> Option<Decimal> {
        match self {
            StringOrNumber::Number(n) => f64_to_decimal(*n),
            StringOrNumber::String(s) => {
                let trimmed = s.trim();
                if trimmed.is_empty() {
                    return None;
                }
                Decimal::from_str(trimmed).ok()
            }
        }
    }
}

fn f64_to_decimal(v: f64) -> Option<Decimal> {
    if !v.is_finite() {
        return None;
    }
    // Decimal::try_from rejects NaN/inf and rounds to its 28-digit
    // significand. Adequate for the OFF nutrient ranges.
    Decimal::try_from(v).ok()
}

impl OffRaw {
    fn into_record(self) -> Option<OffFoodRecord> {
        let code = self.code.unwrap_or_default();
        let product_name = self.product_name.unwrap_or_default();
        let brands = self.brands;
        let categories_tags = self.categories_tags;
        let nutriscore_grade = self.nutriscore_grade;
        let completeness = self.completeness;
        let serving_size = self.serving_size;
        let serving_quantity = self
            .serving_quantity
            .as_ref()
            .and_then(StringOrNumber::as_decimal);

        let n = self.nutriments.unwrap_or_default();

        Some(OffFoodRecord {
            code,
            product_name,
            brands,
            categories_tags,
            nutriscore_grade,
            completeness,
            serving_size,
            serving_quantity,
            energy_kcal_100g: n.energy_kcal_100g.and_then(f64_to_decimal),
            protein_100g: n.proteins_100g.and_then(f64_to_decimal),
            carbs_100g: n.carbohydrates_100g.and_then(f64_to_decimal),
            fat_100g: n.fat_100g.and_then(f64_to_decimal),
            fiber_100g: n.fiber_100g.and_then(f64_to_decimal),
            sugar_100g: n.sugars_100g.and_then(f64_to_decimal),
            sodium_100g: n.sodium_100g.and_then(f64_to_decimal),
            saturated_fat_100g: n.saturated_fat_100g.and_then(f64_to_decimal),
        })
    }
}
