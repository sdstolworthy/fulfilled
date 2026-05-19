use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use uuid::Uuid;

use crate::domain::{FoodDraft, NutriscoreGrade, ServingDraft, ServingSource, Unit};
use crate::repo::{BatchRepository, FoodDraftWithServings, FoodRepository, UpsertStats};
use crate::CoreResult;

// ---------------------------------------------------------------------------
// Record types
// ---------------------------------------------------------------------------

/// Normalized OFF record consumed by the ingest pipeline. The `loseit-ingest`
/// binary owns the JSONL and Parquet sources that produce these — core
/// only describes the shape so the service signature can refer to it.
#[derive(Debug, Clone, Default)]
pub struct OffFoodRecord {
    pub code: String,
    pub product_name: String,
    pub brands: Option<String>,
    pub categories_tags: Vec<String>,
    pub nutriscore_grade: Option<String>,
    pub completeness: Option<f64>,
    pub serving_size: Option<String>,
    pub serving_quantity: Option<Decimal>,
    pub energy_kcal_100g: Option<Decimal>,
    pub protein_100g: Option<Decimal>,
    pub carbs_100g: Option<Decimal>,
    pub fat_100g: Option<Decimal>,
    pub fiber_100g: Option<Decimal>,
    pub sugar_100g: Option<Decimal>,
    /// Sodium in g/100g (OFF convention). Normalizer converts to mg.
    pub sodium_100g: Option<Decimal>,
    pub saturated_fat_100g: Option<Decimal>,
}

/// A single USDA food portion. `gram_weight` is the canonical mass;
/// `measure_unit_name` is USDA's free-text label (e.g. `"tablespoon"`).
#[derive(Debug, Clone)]
pub struct UsdaFoodPortion {
    pub gram_weight: Decimal,
    pub measure_unit_name: String,
    /// Lower sequence numbers are "first". Portion with the lowest
    /// `sequence_number` gets `is_default = true`.
    pub sequence_number: i32,
    /// Pre-composed human-readable label, e.g. `"1 cup, drained"` or
    /// `"2 tablespoon"`. The adapter (`loseit-ingest`) composes this from
    /// the FDC JSON's `portionDescription` (when present) or from
    /// `value + measureUnit.name [+ modifier]`. `None` means no label
    /// could be derived — the normaliser will fall through to
    /// `formatAmountUnit` on the FE.
    pub label: Option<String>,
}

/// Normalized USDA record consumed by the ingest pipeline.
#[derive(Debug, Clone, Default)]
pub struct UsdaFoodRecord {
    pub fdc_id: i64,
    pub data_type: String,
    pub description: String,
    pub brand_owner: Option<String>,
    pub food_portions: Vec<UsdaFoodPortion>,
    // Per-100g nutrition (from foodNutrients[])
    pub energy_kcal_100g: Option<Decimal>,
    pub protein_100g: Option<Decimal>,
    pub carbs_100g: Option<Decimal>,
    pub fat_100g: Option<Decimal>,
    pub fiber_100g: Option<Decimal>,
    pub sugar_100g: Option<Decimal>,
    /// Sodium in mg/100g (USDA convention — already in mg).
    pub sodium_mg_100g: Option<Decimal>,
    pub saturated_fat_100g: Option<Decimal>,
}

// ---------------------------------------------------------------------------
// Source traits
// ---------------------------------------------------------------------------

/// Chunked record stream the ingest service pulls from. Implementations
/// live in `loseit-ingest` (parquet + JSONL); a `Vec`-backed
/// implementation in `loseit-testing` powers unit tests.
#[async_trait]
pub trait FoodRecordSource: Send {
    /// Return the next chunk of up to `n` records. `Ok(None)` means the
    /// source is exhausted.
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<OffFoodRecord>>>;
}

/// Alias: the spec calls this `OffSource` in §7.4. `FoodRecordSource` is
/// preserved so existing `loseit-ingest` code continues to compile.
pub use FoodRecordSource as OffSource;

/// Chunked USDA record stream.
#[async_trait]
pub trait UsdaSource: Send {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<UsdaFoodRecord>>>;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Chunk size hand-tuned to keep memory bounded and round-trip overhead
/// amortized for the OFF dump (~3M rows).
pub const BATCH_SIZE: usize = 500;

/// Sanity threshold for sodium per 100 g. OFF stores sodium in g/100g; >50 g
/// per 100 g is implausible (almost certainly someone uploaded mg by mistake).
pub const SODIUM_GRAMS_SANITY_THRESHOLD: f64 = 50.0;

// ---------------------------------------------------------------------------
// Serving-size parser
// ---------------------------------------------------------------------------

/// Parse a serving-size string (e.g. `"30 g"`, `"1 cup (240 ml)"`) into an
/// `{amount, unit}` pair.
///
/// Strategy:
/// - Scan left-to-right for the first number.
/// - After the number, skip whitespace then read an alphabetic unit token.
/// - If the unit token doesn't match the table, look for a parenthetical
///   `(N <unit>)` and try that.
/// - Returns `None` if no parseable `{amount, unit}` is found.
pub fn parse_serving_size(s: &str) -> Option<(Decimal, Unit)> {
    let results = parse_all_amount_unit_pairs(s);
    // Prefer the first pair that maps to a known unit. The parenthetical
    // `(240 ml)` in `"1 cup (240 ml)"` is secondary — we want the `1 cup`.
    results.into_iter().next()
}

/// Internal: collect all `(amount, unit)` pairs found in `s`.
fn parse_all_amount_unit_pairs(s: &str) -> Vec<(Decimal, Unit)> {
    let bytes = s.as_bytes();
    let mut results = Vec::new();
    let mut i = 0usize;

    while i < bytes.len() {
        // Find start of a number.
        if !bytes[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        let start = i;
        let mut saw_dot = false;
        while i < bytes.len() {
            let b = bytes[i];
            if b.is_ascii_digit() {
                i += 1;
            } else if b == b'.' && !saw_dot {
                saw_dot = true;
                i += 1;
            } else {
                break;
            }
        }
        let num_str = &s[start..i];
        let amount = match num_str.parse::<Decimal>() {
            Ok(v) if v > Decimal::ZERO => v,
            _ => continue,
        };

        // Skip whitespace.
        while i < bytes.len() && bytes[i] == b' ' {
            i += 1;
        }

        // Read the unit token (letters, spaces, dots — to handle "fl. oz").
        let unit_start = i;
        while i < bytes.len()
            && (bytes[i].is_ascii_alphabetic() || bytes[i] == b'.' || bytes[i] == b' ')
        {
            i += 1;
        }
        let raw_unit = s[unit_start..i].trim().to_ascii_lowercase();

        if let Some(u) = map_unit_str(&raw_unit) {
            results.push((amount, u));
        }
    }

    results
}

/// Map a (lowercased, trimmed) unit string to a `Unit`. This is the shared
/// parser table for both OFF and USDA per §7.1 / §7.2.
fn map_unit_str(s: &str) -> Option<Unit> {
    // Normalise: collapse internal runs of whitespace/dots.
    let normalised: String = s
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == ' ')
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    match normalised.as_str() {
        // Mass
        "g" | "gr" | "gram" | "grams" => Some(Unit::Gram),
        "kg" | "kilogram" | "kilograms" => Some(Unit::Kilogram),
        "oz" | "ounce" | "ounces" => Some(Unit::Ounce),
        "lb" | "lbs" | "pound" | "pounds" => Some(Unit::Pound),
        // Volume
        "ml" | "milliliter" | "millilitre" | "milliliters" | "millilitres" => {
            Some(Unit::Milliliter)
        }
        "l" | "liter" | "litre" | "liters" | "litres" => Some(Unit::Liter),
        "cup" | "cups" => Some(Unit::Cup),
        "fl oz" | "fl. oz" | "fluid ounce" | "fluid ounces" => Some(Unit::FluidOunce),
        "tbsp" | "tablespoon" | "tablespoons" => Some(Unit::Tablespoon),
        "tsp" | "teaspoon" | "teaspoons" => Some(Unit::Teaspoon),
        // Count
        "piece" | "pieces" | "pcs" => Some(Unit::Piece),
        "serving" | "servings" => Some(Unit::Serving),
        _ => None,
    }
}

/// Legacy helper: parse a serving-size string to grams only.
/// Retained for quality-score helper and existing tests.
pub fn parse_serving_size_grams(s: &str) -> Option<Decimal> {
    parse_all_amount_unit_pairs(s)
        .into_iter()
        .find(|(_, u)| *u == Unit::Gram)
        .map(|(amt, _)| amt)
}

// ---------------------------------------------------------------------------
// Nutrition scaling helper
// ---------------------------------------------------------------------------

/// Scale a per-100g nutrient value to a per-serving value given the serving's
/// gram-equivalent. Returns `None` if the per-100g value is `None`. Clamps to
/// 0 because USDA's "carbohydrate by difference" (nutrient 1005) can be
/// slightly negative on lean meats (e.g. raw chicken breast = -0.428 g/100g)
/// due to rounding in the `100 - protein - fat - moisture - ash` formula.
/// The DB CHECK constraint requires every nutrient ≥ 0.
fn scale_per_100g(per_100g: Option<Decimal>, grams: Decimal) -> Option<Decimal> {
    per_100g.map(|v| (v * grams / dec!(100)).max(Decimal::ZERO))
}

// ---------------------------------------------------------------------------
// OFF normalizer  (§7.1)
// ---------------------------------------------------------------------------

/// Convert a raw [`OffFoodRecord`] into a [`FoodDraftWithServings`], or
/// `None` if the record fails minimum-viable validation (§7.1).
pub fn accept_and_normalize_off(mut record: OffFoodRecord) -> Option<FoodDraftWithServings> {
    // §7.1 rule 1: drop if code or product_name empty.
    if record.code.trim().is_empty() {
        return None;
    }
    if record.product_name.trim().is_empty() {
        return None;
    }

    // Sodium sanity check (§7.1 sodium rules) — run in g/100g space before conversion.
    if let Some(sod) = record.sodium_100g {
        let as_f = sod.to_f64().unwrap_or(0.0);
        if as_f > SODIUM_GRAMS_SANITY_THRESHOLD {
            tracing::warn!(
                barcode = %record.code,
                sodium = %sod,
                "implausible sodium value (>50 g/100g); nulling field"
            );
            record.sodium_100g = None;
        }
    }

    let has_per_100g = record.energy_kcal_100g.is_some()
        || record.protein_100g.is_some()
        || record.carbs_100g.is_some()
        || record.fat_100g.is_some();

    // Try to parse the serving_size string.
    let parsed_serving = record.serving_size.as_deref().and_then(parse_serving_size);

    // §7.1 rule 7: drop entirely if both per-100g and serving-level nutrition are absent.
    // We consider per-100g absent when energy_kcal_100g is None AND no macro is present.
    // Since OFF only gives us per-100g data (no per-serving nutrition fields), we
    // require per-100g to have at least kcal present to compute serving nutrition.
    if record.energy_kcal_100g.is_none() && !has_per_100g {
        return None;
    }
    // If we have no per-100g kcal and can't build any serving, drop.
    if record.energy_kcal_100g.is_none() && parsed_serving.is_none() {
        return None;
    }
    // Must have kcal_100g to emit any serving (OFF only provides per-100g nutrition).
    let kcal_100g = record.energy_kcal_100g?;

    let quality_score = score(&record);
    let nutriscore_grade = record
        .nutriscore_grade
        .as_deref()
        .and_then(NutriscoreGrade::parse);

    let mut servings: Vec<ServingDraft> = Vec::new();

    match parsed_serving {
        Some((amount, unit)) => {
            // §7.1 rule 3: compute per-serving nutrition.
            // For mass units: scale per-100g × gram-equivalent of the serving.
            // For volume units: OFF has no per-serving nutrients in the record,
            //   only per-100g. No density assumption → we use gramWeight = 0
            //   which would give wrong numbers. Per §7.1 rule 3 for volume:
            //   "if OFF gives only per-100g and the serving is volumetric, drop the row".
            //   But §7.1 rule 4 says "always emit 100g companion when per-100g present",
            //   which takes precedence for the companion; we still drop the volumetric
            //   serving itself when we can't compute it, but emit only the companion.
            let serving_grams: Option<Decimal> = match unit.family() {
                crate::domain::unit::UnitFamily::Mass => {
                    // Convert to grams via ratio table.
                    Some(amount * unit.ratio_to_canonical())
                }
                crate::domain::unit::UnitFamily::Volume => {
                    // No density; can't scale. The volumetric serving is emitted
                    // but we can't derive its nutrition from per-100g alone.
                    // Per §7.1 rule 3: "if OFF gives only per-100g and the serving
                    // is volumetric, drop the row" — meaning: drop the volumetric
                    // serving entry; the 100g companion (rule 4) still lands.
                    None
                }
                crate::domain::unit::UnitFamily::Count => {
                    // COUNT units (serving, piece): OFF doesn't give us the gram
                    // weight either, so we can't scale. Treat like volume.
                    None
                }
            };

            if let Some(grams) = serving_grams {
                // §7.1 rule 5: this serving is is_default = true.
                let sodium_mg = record
                    .sodium_100g
                    .map(|s| s * grams / dec!(100) * dec!(1000));
                servings.push(ServingDraft {
                    label: None,
                    amount,
                    unit,
                    kcal: kcal_100g * grams / dec!(100),
                    protein_g: scale_per_100g(record.protein_100g, grams),
                    carbs_g: scale_per_100g(record.carbs_100g, grams),
                    fat_g: scale_per_100g(record.fat_100g, grams),
                    fiber_g: scale_per_100g(record.fiber_100g, grams),
                    sugar_g: scale_per_100g(record.sugar_100g, grams),
                    sodium_mg,
                    saturated_fat_g: scale_per_100g(record.saturated_fat_100g, grams),
                    is_default: true,
                    source: ServingSource::Off,
                    sort_order: 0,
                });
            }

            // §7.1 rule 4: always emit companion {100, Gram} when per-100g present.
            // Marked is_default = false (unless the parsed serving couldn't yield
            // nutrition above, in which case this becomes the only serving and we
            // mark it default).
            let companion_is_default = servings.is_empty();
            if has_per_100g {
                let sodium_mg_100 = record.sodium_100g.map(|s| s * dec!(1000));
                servings.push(ServingDraft {
                    label: None,
                    amount: dec!(100),
                    unit: Unit::Gram,
                    kcal: kcal_100g,
                    protein_g: record.protein_100g,
                    carbs_g: record.carbs_100g,
                    fat_g: record.fat_100g,
                    fiber_g: record.fiber_100g,
                    sugar_g: record.sugar_100g,
                    sodium_mg: sodium_mg_100,
                    saturated_fat_g: record.saturated_fat_100g,
                    is_default: companion_is_default,
                    source: ServingSource::System,
                    sort_order: 1,
                });
            }
        }
        None => {
            // §7.1 rule 6: no serving_size, but per-100g present → emit {100, g} as default.
            if !has_per_100g {
                // §7.1 rule 7: drop entirely.
                return None;
            }
            let sodium_mg_100 = record.sodium_100g.map(|s| s * dec!(1000));
            servings.push(ServingDraft {
                label: None,
                amount: dec!(100),
                unit: Unit::Gram,
                kcal: kcal_100g,
                protein_g: record.protein_100g,
                carbs_g: record.carbs_100g,
                fat_g: record.fat_100g,
                fiber_g: record.fiber_100g,
                sugar_g: record.sugar_100g,
                sodium_mg: sodium_mg_100,
                saturated_fat_g: record.saturated_fat_100g,
                is_default: true,
                source: ServingSource::System,
                sort_order: 0,
            });
        }
    }

    if servings.is_empty() {
        return None;
    }

    let draft = FoodDraft {
        name: record.product_name.trim().to_string(),
        brands: record.brands.clone().filter(|s| !s.trim().is_empty()),
        barcode: Some(record.code.trim().to_string()),
        fdc_id: None,
        data_type: None,
        categories_tags: record.categories_tags.clone(),
        nutriscore_grade,
        servings: vec![], // servings are carried on FoodDraftWithServings.servings
    };

    Some(FoodDraftWithServings {
        draft,
        quality_score,
        servings,
    })
}

/// Backward-compatible alias: `accept_and_normalize` → `accept_and_normalize_off`.
/// Existing test code and callers continue to work.
pub fn accept_and_normalize(record: OffFoodRecord) -> Option<FoodDraftWithServings> {
    accept_and_normalize_off(record)
}

// ---------------------------------------------------------------------------
// USDA normalizer  (§7.2)
// ---------------------------------------------------------------------------

/// Convert a raw [`UsdaFoodRecord`] into a [`FoodDraftWithServings`], or
/// `None` if the record fails minimum-viable validation (§7.2 rule 5).
pub fn accept_and_normalize_usda(record: UsdaFoodRecord) -> Option<FoodDraftWithServings> {
    // §7.2 rule 5: drop if foodPortions empty AND no energy-kcal.
    if record.food_portions.is_empty() && record.energy_kcal_100g.is_none() {
        return None;
    }

    let kcal_100g = record.energy_kcal_100g.unwrap_or(Decimal::ZERO);

    // §7.2 rule 1–4: build one serving per portion.
    let mut portions = record.food_portions.clone();
    // Sort by sequence_number ascending; first = lowest = default.
    portions.sort_by_key(|p| p.sequence_number);

    let mut servings: Vec<ServingDraft> = Vec::new();

    for (idx, portion) in portions.iter().enumerate() {
        let gram_weight = portion.gram_weight;
        if gram_weight <= Decimal::ZERO {
            continue;
        }

        // §7.2 rule 2: map measureUnit.name → Unit; fallback {gramWeight, Gram}.
        let (amount, unit) = map_usda_unit(&portion.measure_unit_name, gram_weight);

        // §7.2 rule 3: per-serving nutrition = per-100g * gramWeight / 100.
        let kcal = (kcal_100g * gram_weight / dec!(100)).max(Decimal::ZERO);
        let protein_g = scale_per_100g(record.protein_100g, gram_weight);
        let carbs_g = scale_per_100g(record.carbs_100g, gram_weight);
        let fat_g = scale_per_100g(record.fat_100g, gram_weight);
        let fiber_g = scale_per_100g(record.fiber_100g, gram_weight);
        let sugar_g = scale_per_100g(record.sugar_100g, gram_weight);
        // USDA sodium is already in mg/100g.
        let sodium_mg = record.sodium_mg_100g.map(|s| s * gram_weight / dec!(100));
        let saturated_fat_g = scale_per_100g(record.saturated_fat_100g, gram_weight);

        // §7.2 rule 4: first (lowest sequenceNumber) is is_default = true.
        let is_default = idx == 0;

        servings.push(ServingDraft {
            label: portion.label.clone(),
            amount,
            unit,
            kcal,
            protein_g,
            carbs_g,
            fat_g,
            fiber_g,
            sugar_g,
            sodium_mg,
            saturated_fat_g,
            is_default,
            // OpenAPI ServingSource enum is [off, user, system] — `Usda` was
            // a Rust-only variant that broke the FE decoder when USDA rows
            // shipped. Treat USDA-imported servings as `System` (same as
            // the OFF normalizer's auto-companion gram serving).
            source: ServingSource::System,
            sort_order: idx as i32,
        });
    }

    // F4-T1: if we produced at least one FDC-derived serving, append a labelless
    // 100 g companion so power users always get a per-100 g baseline (and the
    // FE renders both the human label and `100 g`). This is non-default — the
    // first FDC portion wins `is_default`. If `food_portions` was empty (or all
    // portions were filtered out upstream e.g. RACC drop), fall through to the
    // empty-fallback block below — that path takes `is_default = true`.
    if !servings.is_empty() && record.energy_kcal_100g.is_some() {
        let sodium_mg = record.sodium_mg_100g;
        let sort_order = servings.len() as i32;
        servings.push(ServingDraft {
            label: None,
            amount: dec!(100),
            unit: Unit::Gram,
            kcal: kcal_100g,
            protein_g: record.protein_100g,
            carbs_g: record.carbs_100g,
            fat_g: record.fat_100g,
            fiber_g: record.fiber_100g,
            sugar_g: record.sugar_100g,
            sodium_mg,
            saturated_fat_g: record.saturated_fat_100g,
            is_default: false,
            source: ServingSource::System,
            sort_order,
        });
    }

    // If portions was empty but kcal is present, emit a single 100g serving.
    if servings.is_empty() {
        record.energy_kcal_100g?;
        let sodium_mg = record.sodium_mg_100g;
        servings.push(ServingDraft {
            label: None,
            amount: dec!(100),
            unit: Unit::Gram,
            kcal: kcal_100g,
            protein_g: record.protein_100g,
            carbs_g: record.carbs_100g,
            fat_g: record.fat_100g,
            fiber_g: record.fiber_100g,
            sugar_g: record.sugar_100g,
            sodium_mg,
            saturated_fat_g: record.saturated_fat_100g,
            is_default: true,
            source: ServingSource::System,
            sort_order: 0,
        });
    }

    let data_type = if record.data_type.trim().is_empty() {
        None
    } else {
        Some(record.data_type.trim().to_string())
    };
    let draft = FoodDraft {
        name: record.description.trim().to_string(),
        brands: record.brand_owner.filter(|s| !s.trim().is_empty()),
        barcode: None,
        fdc_id: Some(record.fdc_id),
        data_type,
        categories_tags: vec![],
        nutriscore_grade: None,
        servings: vec![],
    };

    Some(FoodDraftWithServings {
        draft,
        quality_score: 50, // USDA data is considered medium quality by default
        servings,
    })
}

/// Map a USDA measure unit name string + gramWeight to `(amount, Unit)`.
/// Per §7.2 rule 2: fallback is `{gramWeight, Gram}`.
fn map_usda_unit(name: &str, gram_weight: Decimal) -> (Decimal, Unit) {
    let lower = name.trim().to_ascii_lowercase();
    // Try the shared unit table first.
    if let Some(unit) = map_unit_str(&lower) {
        // For named volume/count units, use amount=1 (one tablespoon, one cup, etc.).
        // For mass units from the table, use the gramWeight converted appropriately.
        match unit.family() {
            crate::domain::unit::UnitFamily::Mass => {
                // Express gramWeight in the mapped mass unit.
                let ratio = unit.ratio_to_canonical(); // g per unit
                if ratio > Decimal::ZERO {
                    (gram_weight / ratio, unit)
                } else {
                    (gram_weight, Unit::Gram)
                }
            }
            crate::domain::unit::UnitFamily::Volume | crate::domain::unit::UnitFamily::Count => {
                // Volume/count: 1 unit of the named measure.
                (Decimal::ONE, unit)
            }
        }
    } else {
        // Fallback: {gramWeight, Gram}
        (gram_weight, Unit::Gram)
    }
}

// ---------------------------------------------------------------------------
// Quality score (OFF)
// ---------------------------------------------------------------------------

/// Compute the 0..=100 quality score for an OFF record.
pub fn score(record: &OffFoodRecord) -> i16 {
    let mut total: i32 = 0;

    if let Some(g) = record.nutriscore_grade.as_deref() {
        if NutriscoreGrade::parse(g).is_some() {
            total += 40;
        }
    }

    if record
        .brands
        .as_deref()
        .map(|b| !b.trim().is_empty())
        .unwrap_or(false)
    {
        total += 15;
    }

    let has_off_serving = record
        .serving_quantity
        .filter(|q| *q > Decimal::ZERO)
        .is_some()
        || record
            .serving_size
            .as_deref()
            .and_then(parse_serving_size_grams)
            .filter(|g| *g > Decimal::ZERO)
            .is_some();
    if has_off_serving {
        total += 15;
    }

    let nutrients_filled = [
        record.protein_100g.is_some(),
        record.carbs_100g.is_some(),
        record.fat_100g.is_some(),
        record.fiber_100g.is_some(),
        record.sugar_100g.is_some(),
        record.sodium_100g.is_some(),
        record.saturated_fat_100g.is_some(),
    ]
    .iter()
    .filter(|b| **b)
    .count();
    if nutrients_filled >= 6 {
        total += 10;
    } else if nutrients_filled >= 3 {
        total += 5;
    }

    if let Some(c) = record.completeness {
        let clamped = c.clamp(0.0, 1.0);
        total += (clamped * 10.0).round() as i32;
    }

    if !record.categories_tags.is_empty() {
        total += 10;
    }

    total.clamp(0, 100) as i16
}

// ---------------------------------------------------------------------------
// IngestService
// ---------------------------------------------------------------------------

/// Streaming batch upsert orchestrator.
pub struct IngestService {
    foods: Arc<dyn FoodRepository>,
    batches: Arc<dyn BatchRepository>,
}

impl IngestService {
    pub fn new(foods: Arc<dyn FoodRepository>, batches: Arc<dyn BatchRepository>) -> Self {
        Self { foods, batches }
    }

    pub async fn run<S: FoodRecordSource>(
        &self,
        mut source: S,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<UpsertStats> {
        let batch = self.batches.start(source_url, source_etag).await?;
        let result = self.run_inner(&mut source, batch.id).await;
        match result {
            Ok(stats) => {
                self.batches.finish(batch.id, stats.clone()).await?;
                Ok(stats)
            }
            Err(err) => {
                let msg = err.to_string();
                let _ = self.batches.fail(batch.id, &msg).await;
                Err(err)
            }
        }
    }

    /// §7.4: Run the OFF pipeline. Reads `OffFoodRecord`s from `source`,
    /// normalizes each via `accept_and_normalize_off`, and upserts the
    /// resulting `FoodDraftWithServings` batch via
    /// `FoodRepository::upsert_external_food_batch`.
    pub async fn run_off<S: FoodRecordSource>(
        &self,
        source: S,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<UpsertStats> {
        self.run(source, source_url, source_etag).await
    }

    /// §7.4: Run the USDA pipeline. Reads `UsdaFoodRecord`s from `source`,
    /// normalizes each via `accept_and_normalize_usda`, and upserts the
    /// resulting `FoodDraftWithServings` batch via
    /// `FoodRepository::upsert_external_food_batch`.
    pub async fn run_usda<S: UsdaSource>(
        &self,
        mut source: S,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<UpsertStats> {
        let batch = self.batches.start(source_url, source_etag).await?;
        let result = self.run_usda_inner(&mut source, batch.id).await;
        match result {
            Ok(stats) => {
                self.batches.finish(batch.id, stats.clone()).await?;
                Ok(stats)
            }
            Err(err) => {
                let msg = err.to_string();
                let _ = self.batches.fail(batch.id, &msg).await;
                Err(err)
            }
        }
    }

    async fn run_inner<S: FoodRecordSource>(
        &self,
        source: &mut S,
        batch_id: Uuid,
    ) -> CoreResult<UpsertStats> {
        let mut total = UpsertStats::default();

        loop {
            let Some(chunk) = source.next_chunk(BATCH_SIZE).await? else {
                break;
            };
            if chunk.is_empty() {
                continue;
            }

            let seen = chunk.len() as u64;

            let mut accepted: Vec<FoodDraftWithServings> = Vec::with_capacity(chunk.len());
            let mut seen_barcodes: HashSet<String> = HashSet::new();
            for record in chunk {
                if let Some(upsert) = accept_and_normalize_off(record) {
                    if let Some(bc) = upsert.draft.barcode.clone() {
                        if !seen_barcodes.insert(bc) {
                            if let Some(slot) = accepted
                                .iter_mut()
                                .find(|u| u.draft.barcode == upsert.draft.barcode)
                            {
                                *slot = upsert;
                                continue;
                            }
                        }
                    }
                    accepted.push(upsert);
                }
            }
            let skipped = seen.saturating_sub(accepted.len() as u64);
            let upserted = accepted.len() as u64;

            self.foods
                .upsert_external_food_batch(batch_id, accepted)
                .await?;

            total.inserted += upserted;
            total.skipped += skipped;
            self.batches
                .bump_counts(batch_id, seen, upserted, skipped)
                .await?;
        }

        Ok(total)
    }

    async fn run_usda_inner<S: UsdaSource>(
        &self,
        source: &mut S,
        batch_id: Uuid,
    ) -> CoreResult<UpsertStats> {
        let mut total = UpsertStats::default();

        loop {
            let Some(chunk) = source.next_chunk(BATCH_SIZE).await? else {
                break;
            };
            if chunk.is_empty() {
                continue;
            }

            let seen = chunk.len() as u64;

            let mut accepted: Vec<FoodDraftWithServings> = Vec::with_capacity(chunk.len());
            for record in chunk {
                if let Some(upsert) = accept_and_normalize_usda(record) {
                    accepted.push(upsert);
                }
            }
            let skipped = seen.saturating_sub(accepted.len() as u64);
            let upserted = accepted.len() as u64;

            self.foods
                .upsert_external_food_batch(batch_id, accepted)
                .await?;

            total.inserted += upserted;
            total.skipped += skipped;
            self.batches
                .bump_counts(batch_id, seen, upserted, skipped)
                .await?;
        }

        Ok(total)
    }
}

// ---------------------------------------------------------------------------
// Unit tests  (§8 ingest layer)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn d(n: i64) -> Decimal {
        Decimal::from(n)
    }

    fn base_off(code: &str, name: &str) -> OffFoodRecord {
        OffFoodRecord {
            code: code.to_string(),
            product_name: name.to_string(),
            energy_kcal_100g: Some(d(150)),
            protein_100g: Some(d(5)),
            carbs_100g: Some(d(20)),
            fat_100g: Some(d(5)),
            fiber_100g: Some(d(3)),
            sugar_100g: Some(d(8)),
            sodium_100g: Some(Decimal::new(5, 1)), // 0.5 g/100g
            saturated_fat_100g: Some(d(1)),
            ..Default::default()
        }
    }

    // ---- OFF cases ----

    /// §8 off_30g_serving: "30 g" + per-100g → emit {30, Gram} is_default=true.
    #[test]
    fn off_30g_serving() {
        let mut r = base_off("BC001", "Cracker");
        r.serving_size = Some("30 g".to_string());

        let out = accept_and_normalize_off(r).expect("should accept");
        let default_serving = out
            .servings
            .iter()
            .find(|s| s.is_default)
            .expect("must have default");

        assert_eq!(default_serving.amount, d(30));
        assert_eq!(default_serving.unit, Unit::Gram);
        assert!(default_serving.is_default);
        assert_eq!(default_serving.source, ServingSource::Off);

        // kcal = 150 * 30 / 100 = 45
        assert_eq!(default_serving.kcal, dec!(45));
    }

    /// §8 off_cup_with_ml_companion: "1 cup (240 ml)" + per-100g →
    /// emit {1, Cup} default=true AND companion {100, g} non-default.
    #[test]
    fn off_cup_with_ml_companion() {
        let mut r = base_off("BC002", "Cereal");
        r.serving_size = Some("1 cup (240 ml)".to_string());

        let out = accept_and_normalize_off(r).expect("should accept");

        // The "1 cup" is volumetric — no gram equivalent without density.
        // Per §7.1 rule 3: volumetric serving with only per-100g nutrition → drop
        // the volumetric serving. But rule 4 still emits the 100g companion.
        // Rule 6 fallback: companion becomes is_default = true.
        let has_cup = out.servings.iter().any(|s| s.unit == Unit::Cup);
        let has_100g = out
            .servings
            .iter()
            .any(|s| s.unit == Unit::Gram && s.amount == dec!(100));

        // The cup serving cannot carry nutrition (no density), so we get only 100g.
        // The companion is emitted; it becomes default because the cup serving was dropped.
        assert!(
            !has_cup,
            "volumetric serving without density should be dropped"
        );
        assert!(has_100g, "100g companion must still be emitted");

        let default = out
            .servings
            .iter()
            .find(|s| s.is_default)
            .expect("must have default");
        assert_eq!(default.unit, Unit::Gram);
        assert_eq!(default.amount, dec!(100));
    }

    /// §8 off_unparseable_no_per100g_dropped: serving_size="??" + no per-100g → None.
    #[test]
    fn off_unparseable_no_per100g_dropped() {
        let r = OffFoodRecord {
            code: "BC003".to_string(),
            product_name: "Mystery".to_string(),
            serving_size: Some("??".to_string()),
            energy_kcal_100g: None,
            protein_100g: None,
            carbs_100g: None,
            fat_100g: None,
            ..Default::default()
        };

        assert!(
            accept_and_normalize_off(r).is_none(),
            "row with unparseable serving and no per-100g must be dropped"
        );
    }

    /// §8 off_per100g_only: no serving_size, per-100g present →
    /// emit single {100, Gram} is_default=true.
    #[test]
    fn off_per100g_only() {
        let mut r = base_off("BC004", "Flour");
        r.serving_size = None;
        r.serving_quantity = None;

        let out = accept_and_normalize_off(r).expect("should accept");
        assert_eq!(out.servings.len(), 1);
        let s = &out.servings[0];
        assert_eq!(s.amount, dec!(100));
        assert_eq!(s.unit, Unit::Gram);
        assert!(s.is_default);
        assert_eq!(s.kcal, d(150)); // 150 kcal/100g
    }

    /// §8 off_sodium_over_50g_per100g_nulls_field: sodium_100g=60.0 →
    /// serving has sodium_mg=None, row NOT dropped.
    #[test]
    fn off_sodium_over_50g_per100g_nulls_field() {
        let mut r = base_off("BC005", "SaltyCracker");
        r.sodium_100g = Some(dec!(60)); // 60 g/100g — implausible
        r.serving_size = None;

        let out = accept_and_normalize_off(r).expect("row must NOT be dropped");
        for s in &out.servings {
            assert!(
                s.sodium_mg.is_none(),
                "sodium_mg must be None after sanity null, got {:?}",
                s.sodium_mg
            );
        }
    }

    // ---- USDA cases ----

    /// §8 usda_tablespoon_maps: portion {gramWeight:15.0, measureUnit:"tablespoon"} →
    /// {1, Tablespoon}. F4-T1: also asserts the composed label and the 100 g companion.
    #[test]
    fn usda_tablespoon_maps() {
        let r = UsdaFoodRecord {
            fdc_id: 1001,
            data_type: "sr_legacy_food".to_string(),
            description: "Butter".to_string(),
            brand_owner: None,
            food_portions: vec![UsdaFoodPortion {
                gram_weight: dec!(14.2),
                measure_unit_name: "tablespoon".to_string(),
                sequence_number: 1,
                label: Some("1 tablespoon".to_string()),
            }],
            energy_kcal_100g: Some(dec!(717)),
            protein_100g: Some(dec!(0.85)),
            fat_100g: Some(dec!(81)),
            carbs_100g: Some(Decimal::ZERO),
            ..Default::default()
        };

        let out = accept_and_normalize_usda(r).expect("should accept");
        // F4-T1: 1 FDC portion + 1 system 100 g companion = 2 servings.
        assert_eq!(out.servings.len(), 2);
        let s = &out.servings[0];
        assert_eq!(s.unit, Unit::Tablespoon);
        assert_eq!(s.amount, Decimal::ONE);
        assert!(s.is_default);
        assert_eq!(s.label.as_deref(), Some("1 tablespoon"));
        // Companion: labelless 100 g, non-default, system source.
        let companion = &out.servings[1];
        assert_eq!(companion.unit, Unit::Gram);
        assert_eq!(companion.amount, dec!(100));
        assert!(!companion.is_default);
        assert!(companion.label.is_none());
        assert_eq!(companion.source, ServingSource::System);
    }

    /// §8 usda_unmapped_fallback_grams: measureUnit:"foobar" →
    /// {gramWeight, Gram} fallback.
    #[test]
    fn usda_unmapped_fallback_grams() {
        let r = UsdaFoodRecord {
            fdc_id: 1002,
            data_type: "foundation_food".to_string(),
            description: "Mystery food".to_string(),
            brand_owner: None,
            food_portions: vec![UsdaFoodPortion {
                gram_weight: dec!(45),
                measure_unit_name: "foobar".to_string(),
                sequence_number: 1,
                label: None,
            }],
            energy_kcal_100g: Some(dec!(200)),
            ..Default::default()
        };

        let out = accept_and_normalize_usda(r).expect("should accept");
        let s = &out.servings[0];
        assert_eq!(s.unit, Unit::Gram);
        assert_eq!(s.amount, dec!(45));
    }

    /// F4-T1: per-portion composed label is threaded through into the
    /// `ServingDraft.label`, and a labelless 100 g companion is appended
    /// after the FDC portions with `is_default = false`.
    #[test]
    fn usda_label_with_modifier_composed() {
        let r = UsdaFoodRecord {
            fdc_id: 321611,
            data_type: "foundation_food".into(),
            description: "Beans, snap, green, canned".into(),
            brand_owner: None,
            food_portions: vec![UsdaFoodPortion {
                gram_weight: dec!(129),
                measure_unit_name: "cup".into(),
                sequence_number: 1,
                label: Some("1 cup, drained".into()),
            }],
            energy_kcal_100g: Some(dec!(28)),
            ..Default::default()
        };

        let out = accept_and_normalize_usda(r).expect("should accept");
        // 1 FDC portion + 1 system 100 g companion.
        assert_eq!(out.servings.len(), 2);

        // Portion: cup, default, labelled.
        let portion = out
            .servings
            .iter()
            .find(|s| s.unit == Unit::Cup)
            .expect("cup portion present");
        assert_eq!(portion.label.as_deref(), Some("1 cup, drained"));
        assert!(portion.is_default);
        assert_eq!(portion.source, ServingSource::System);

        // Companion: 100 g, labelless, non-default.
        let companion = out
            .servings
            .iter()
            .find(|s| s.unit == Unit::Gram && s.amount == dec!(100))
            .expect("100 g companion present");
        assert!(companion.label.is_none());
        assert!(!companion.is_default);
        assert_eq!(companion.source, ServingSource::System);

        // Exactly one default across all servings (matches the partial
        // unique index `servings_one_default_per_food`).
        assert_eq!(
            out.servings.iter().filter(|s| s.is_default).count(),
            1,
            "exactly one is_default = true serving per food"
        );
    }

    /// F4-T1: if all FDC portions are filtered out upstream (e.g. all RACC),
    /// the empty-fallback block emits the 100 g serving as default.
    #[test]
    fn usda_empty_portions_emits_default_companion() {
        let r = UsdaFoodRecord {
            fdc_id: 1004,
            data_type: "foundation_food".into(),
            description: "kcal-only food".into(),
            brand_owner: None,
            food_portions: vec![],
            energy_kcal_100g: Some(dec!(120)),
            ..Default::default()
        };

        let out = accept_and_normalize_usda(r).expect("should accept");
        assert_eq!(out.servings.len(), 1);
        let s = &out.servings[0];
        assert_eq!(s.unit, Unit::Gram);
        assert_eq!(s.amount, dec!(100));
        assert!(s.is_default);
        assert!(s.label.is_none());
        assert_eq!(s.source, ServingSource::System);
    }

    /// §8 usda_empty_portions_no_kcal_dropped: foodPortions=[] + no energy-kcal → None.
    #[test]
    fn usda_empty_portions_no_kcal_dropped() {
        let r = UsdaFoodRecord {
            fdc_id: 1003,
            data_type: "foundation_food".to_string(),
            description: "Empty".to_string(),
            food_portions: vec![],
            energy_kcal_100g: None,
            ..Default::default()
        };

        assert!(
            accept_and_normalize_usda(r).is_none(),
            "empty portions + no kcal must be dropped"
        );
    }

    // ---- parse_serving_size unit tests ----

    #[test]
    fn parse_30g() {
        let (amt, unit) = parse_serving_size("30 g").expect("should parse");
        assert_eq!(amt, d(30));
        assert_eq!(unit, Unit::Gram);
    }

    #[test]
    fn parse_cup_ignores_parenthetical_ml() {
        // "1 cup (240 ml)" → {1, Cup} (not {240, Milliliter})
        let (amt, unit) = parse_serving_size("1 cup (240 ml)").expect("should parse");
        assert_eq!(amt, Decimal::ONE);
        assert_eq!(unit, Unit::Cup);
    }

    #[test]
    fn parse_100ml() {
        let (amt, unit) = parse_serving_size("100 ml").expect("should parse");
        assert_eq!(amt, d(100));
        assert_eq!(unit, Unit::Milliliter);
    }

    #[test]
    fn parse_unparseable_returns_none() {
        assert!(parse_serving_size("??").is_none());
        assert!(parse_serving_size("").is_none());
        assert!(parse_serving_size("one tablespoon").is_none()); // no leading digit
    }

    #[test]
    fn parse_tablespoon() {
        let (amt, unit) = parse_serving_size("1 tablespoon").expect("should parse");
        assert_eq!(amt, Decimal::ONE);
        assert_eq!(unit, Unit::Tablespoon);
    }

    #[test]
    fn parse_fluid_ounce() {
        let (amt, unit) = parse_serving_size("4 fl oz").expect("should parse");
        assert_eq!(amt, dec!(4));
        assert_eq!(unit, Unit::FluidOunce);
    }
}
