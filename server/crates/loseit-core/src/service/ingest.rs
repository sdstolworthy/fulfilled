use std::collections::HashSet;
use std::sync::Arc;
use std::time::Instant;

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
    /// Energy in kJ per 100 g (OFF's `energy-kj_100g` column). Used as a
    /// fallback when `energy_kcal_100g` is `None` — many OFF rows carry
    /// only kJ. See 1.1 in `import_plan.md`.
    pub energy_kj_100g: Option<Decimal>,
    pub protein_100g: Option<Decimal>,
    pub carbs_100g: Option<Decimal>,
    pub fat_100g: Option<Decimal>,
    pub fiber_100g: Option<Decimal>,
    pub sugar_100g: Option<Decimal>,
    /// Sodium in g/100g (OFF convention). Normalizer converts to mg.
    pub sodium_100g: Option<Decimal>,
    pub saturated_fat_100g: Option<Decimal>,
    /// OFF `states_tags`, e.g. `["en:to-be-deleted", "en:complete"]`.
    /// Used by the normaliser to drop rows the OFF moderation flow has
    /// marked obsolete. See 1.6 in `import_plan.md`.
    pub states_tags: Vec<String>,
    /// OFF `obsolete` flag — `Some(true)` for product entries the
    /// contributors have retired. See 1.6 in `import_plan.md`.
    pub obsolete: Option<bool>,
    /// OFF `no_nutrition_data` — the literal string `"on"` means the
    /// contributor told OFF the product has no nutrition info available.
    /// See 1.7 in `import_plan.md`.
    pub no_nutrition_data: Option<String>,
    /// 4.4: OFF `last_modified_t` — Unix epoch seconds of the last
    /// contributor edit. Used by the normaliser to drop rows that have
    /// been stale for more than `RunOptions.stale_after_years`. `None`
    /// means the source didn't tell us when the row was last touched;
    /// we conservatively keep it (no signal = no drop).
    pub last_modified_t: Option<i64>,
    /// OFF `data_quality_errors_tags` — the moderation flow's flags for
    /// data the contributor mis-entered (e.g. `en:nutrition-value-very-
    /// high-for-category`, `en:energy-value-in-kcal-may-be-in-kj`). A
    /// non-empty list means OFF itself already knows this row is bad.
    /// The normaliser drops these with a warn log that includes the
    /// tags so operators can see which classes of error dominate.
    pub data_quality_errors_tags: Vec<String>,
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
    // Per-100g nutrition (from foodNutrients[]). All FDC datasets
    // (Foundation, SR Legacy, Survey, AND Branded) report these as
    // per-100g — verified 2026-05-19 against live API + CSV bundle.
    // Earlier Phase 1 work assumed Branded was per-serving and added
    // a rescale step; that was based on incorrect research and is
    // gone — see `accept_and_normalize_usda`.
    pub energy_kcal_100g: Option<Decimal>,
    pub protein_100g: Option<Decimal>,
    pub carbs_100g: Option<Decimal>,
    pub fat_100g: Option<Decimal>,
    pub fiber_100g: Option<Decimal>,
    pub sugar_100g: Option<Decimal>,
    /// Sodium in mg/100g (USDA convention — already in mg).
    pub sodium_mg_100g: Option<Decimal>,
    pub saturated_fat_100g: Option<Decimal>,
    /// Serving size for Branded foods (carried through for future
    /// per-serving label emission). Not used for nutrient rescaling.
    pub serving_size: Option<Decimal>,
    /// Unit for `serving_size`.
    pub serving_size_unit: Option<String>,
    /// 4.1: USDA Branded GTIN (UPC-A or EAN-13). Stamped onto
    /// `FoodDraft.barcode` by `accept_and_normalize_usda` so that the
    /// same product imported from both OFF and USDA collapses to a
    /// single `foods` row via `foods_barcode_unique`. `None` for
    /// Foundation / SR Legacy / Survey (which never have a GTIN) and
    /// for Branded rows where the FDC export shipped the field empty
    /// or non-numeric.
    pub gtin_upc: Option<String>,
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

/// 1.4: clamp a per-100g macro field to `[0, 100] g/100g`. Out-of-range
/// values are nulled (the row is kept). Logs the nulled value at WARN so
/// operators see the bad data in import logs.
fn clamp_macro_field(slot: &mut Option<Decimal>, ext_id: &str, field: &str) {
    if let Some(v) = *slot {
        let f = v.to_f64().unwrap_or(0.0);
        if !(0.0..=100.0).contains(&f) {
            tracing::warn!(
                external_id = %ext_id,
                field = %field,
                value = %v,
                "implausible macro value (must be in [0, 100] g/100g); nulling field"
            );
            *slot = None;
        }
    }
}

// ---------------------------------------------------------------------------
// OFF normalizer  (§7.1)
// ---------------------------------------------------------------------------

/// Convert a raw [`OffFoodRecord`] into a [`FoodDraftWithServings`], or
/// `None` if the record fails minimum-viable validation (§7.1).
///
/// Backwards-compatible wrapper: calls [`accept_and_normalize_off_with_opts`]
/// with the default options (no stale-row drop). Prefer the
/// `_with_opts` form when you want to honour 4.4 cutoffs.
pub fn accept_and_normalize_off(record: OffFoodRecord) -> Option<FoodDraftWithServings> {
    accept_and_normalize_off_with_opts(record, &OffNormalizeOpts::default())
}

/// 4.4: per-call knobs threaded through the OFF normaliser. `stale_cutoff`
/// is the inclusive Unix-epoch threshold below which a row is dropped
/// (`record.last_modified_t < stale_cutoff` → drop). `None` disables the
/// drop, matching the default + `--stale-after-years 0` operator override.
#[derive(Debug, Clone, Default)]
pub struct OffNormalizeOpts {
    /// Unix seconds; rows with `last_modified_t < stale_cutoff` are
    /// dropped. `None` → no drop.
    pub stale_cutoff: Option<i64>,
}

/// 4.4: convert `--stale-after-years N` into an absolute Unix-second
/// cutoff. `N == 0` returns `None` ("never drop"). Uses
/// `SystemTime::now()` so test fixtures need to manufacture timestamps
/// relative to wall-clock; the predicate itself is exercised in unit
/// tests via [`OffNormalizeOpts.stale_cutoff`] direct injection.
pub fn compute_stale_cutoff(stale_after_years: u32) -> Option<i64> {
    if stale_after_years == 0 {
        return None;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    // 365.25 days * 86400 s/day ≈ 31_557_600 s/yr. Integer math is
    // adequate here (we tolerate a few days of slop near the boundary).
    let span = (stale_after_years as i64) * 31_557_600;
    Some(now.saturating_sub(span))
}

/// 4.4-aware OFF normaliser. Drops rows whose `last_modified_t` is older
/// than `opts.stale_cutoff` (when set) in addition to the §7.1 rules.
///
/// Every drop path emits `tracing::info!` under target
/// `loseit_ingest::off_drop` with a `reason` field so operators can
/// categorize the skipped-row counter by cause (`empty_code`,
/// `quality_tags`, `stale`, `obsolete`, `no_nutrition_data`,
/// `all_zero`, `no_kcal_no_serving`, …). Implausible-kcal/macro/sodium
/// drops keep their existing `warn!` calls — those are surprising
/// data; everything else is expected filter behavior.
pub fn accept_and_normalize_off_with_opts(
    mut record: OffFoodRecord,
    opts: &OffNormalizeOpts,
) -> Option<FoodDraftWithServings> {
    // §7.1 rule 1: drop if code or product_name empty.
    if record.code.trim().is_empty() {
        tracing::info!(target: "loseit_ingest::off_drop", reason = "empty_code", "drop");
        return None;
    }
    if record.product_name.trim().is_empty() {
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "empty_product_name",
            barcode = %record.code,
            "drop"
        );
        return None;
    }

    // OFF moderation flow already flagged this row. The full HF parquet
    // ships this column; the slim "flat" subset doesn't (empty vec there,
    // so this is a no-op on flat dumps). Tags include
    // `en:energy-value-in-kcal-may-be-in-kj`,
    // `en:nutrition-value-very-high-for-category`, etc. — exactly the
    // rows our `(0, 900]` kcal clamp also catches by accident. Dropping
    // them here turns a 4-digit kcal typo into a named, source-tagged
    // skip rather than a downstream warn.
    if !record.data_quality_errors_tags.is_empty() {
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "quality_tags",
            barcode = %record.code,
            tags = ?record.data_quality_errors_tags,
            "drop"
        );
        return None;
    }

    // 4.4: stale-row drop. We act only on rows that *have* a timestamp;
    // a missing `last_modified_t` is treated as "no signal, keep the row"
    // so that older OFF dumps without the column aren't silently nuked.
    if let (Some(cutoff), Some(t)) = (opts.stale_cutoff, record.last_modified_t) {
        if t < cutoff {
            tracing::info!(
                target: "loseit_ingest::off_drop",
                reason = "stale",
                barcode = %record.code,
                last_modified_t = t,
                cutoff,
                "drop"
            );
            return None;
        }
    }

    // 1.6: drop rows the OFF moderation flow has retired or marked for
    // deletion. `obsolete == true` is the explicit boolean column; the
    // `states_tags` array carries the same signal in a few flavours.
    if record.obsolete == Some(true) {
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "obsolete_flag",
            barcode = %record.code,
            "drop"
        );
        return None;
    }
    if record
        .states_tags
        .iter()
        .any(|t| t == "en:to-be-deleted" || t == "en:obsolete")
    {
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "states_tags",
            barcode = %record.code,
            "drop"
        );
        return None;
    }

    // 1.7: drop rows the contributor explicitly flagged as no-nutrition.
    if let Some(flag) = record.no_nutrition_data.as_deref() {
        if flag.trim().eq_ignore_ascii_case("on") {
            tracing::info!(
                target: "loseit_ingest::off_drop",
                reason = "no_nutrition_data",
                barcode = %record.code,
                "drop"
            );
            return None;
        }
    }

    // 1.1: derive kcal from energy-kj_100g when the kcal column is
    // missing (very common in real OFF rows). 1 kcal = 4.184 kJ.
    if record.energy_kcal_100g.is_none() {
        if let Some(kj) = record.energy_kj_100g {
            // 4.184 kJ / kcal (NIST thermochemical calorie). Decimal
            // division gives full precision up to the 28-digit
            // significand — adequate for the typical 0–4000 kJ range.
            record.energy_kcal_100g = Some(kj / dec!(4.184));
        }
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

    // 1.4: per-field sanity clamps. kcal_100g must be in `(0, 900]` —
    // outside → null + drop row (no kcal = no servings possible).
    // Each macro must be in `[0, 100]` g/100g — outside → null the field
    // but keep the row.
    if let Some(k) = record.energy_kcal_100g {
        let k_f = k.to_f64().unwrap_or(0.0);
        if k_f <= 0.0 || k_f > 900.0 {
            tracing::warn!(
                barcode = %record.code,
                kcal = %k,
                "implausible kcal/100g (must be in (0, 900]); dropping row"
            );
            record.energy_kcal_100g = None;
        }
    }
    clamp_macro_field(&mut record.protein_100g, &record.code, "protein_g_per_100g");
    clamp_macro_field(&mut record.carbs_100g, &record.code, "carbs_g_per_100g");
    clamp_macro_field(&mut record.fat_100g, &record.code, "fat_g_per_100g");
    clamp_macro_field(&mut record.fiber_100g, &record.code, "fiber_g_per_100g");
    clamp_macro_field(&mut record.sugar_100g, &record.code, "sugars_g_per_100g");
    clamp_macro_field(
        &mut record.saturated_fat_100g,
        &record.code,
        "saturated_fat_g_per_100g",
    );

    // 1.7 (continued): drop all-zero rows where kcal == 0 AND every
    // macro is None or 0. These are placeholder shells with no
    // useful nutrition. Note the kcal clamp above already nulls
    // values <= 0 — so this primarily catches the original
    // `Some(0.0)` payload before the clamp.
    let macros_all_zero_or_none = |v: &Option<Decimal>| match v {
        None => true,
        Some(d) => *d == Decimal::ZERO,
    };
    let kcal_zero_or_missing = record
        .energy_kcal_100g
        .map(|k| k == Decimal::ZERO)
        .unwrap_or(true);
    let all_macros_zero = macros_all_zero_or_none(&record.protein_100g)
        && macros_all_zero_or_none(&record.carbs_100g)
        && macros_all_zero_or_none(&record.fat_100g)
        && macros_all_zero_or_none(&record.fiber_100g)
        && macros_all_zero_or_none(&record.sugar_100g)
        && macros_all_zero_or_none(&record.saturated_fat_100g);
    if kcal_zero_or_missing && all_macros_zero {
        // No nutrition signal at all — drop the row outright.
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "all_zero",
            barcode = %record.code,
            "drop"
        );
        return None;
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
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "no_nutrition_signal",
            barcode = %record.code,
            "drop"
        );
        return None;
    }
    // If we have no per-100g kcal and can't build any serving, drop.
    if record.energy_kcal_100g.is_none() && parsed_serving.is_none() {
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "no_kcal_no_serving",
            barcode = %record.code,
            "drop"
        );
        return None;
    }
    // Must have kcal_100g to emit any serving (OFF only provides per-100g nutrition).
    let Some(kcal_100g) = record.energy_kcal_100g else {
        tracing::info!(
            target: "loseit_ingest::off_drop",
            reason = "no_kcal_after_clamp",
            barcode = %record.code,
            "drop"
        );
        return None;
    };

    let quality_score = score(&record);
    let nutriscore_grade = record
        .nutriscore_grade
        .as_deref()
        .and_then(NutriscoreGrade::parse);

    let mut servings: Vec<ServingDraft> = Vec::new();

    match parsed_serving {
        Some((amount, unit)) => {
            // §7.1 rule 3: compute per-serving nutrition.
            // For mass units: scale per-100g × gram-equivalent of the serving
            //   (the parsed string is authoritative — `serving_quantity` is
            //   ignored here on purpose).
            // For volume/count units: we have no density and the unit alone
            //   doesn't tell us a gram weight. But OFF's `serving_quantity`
            //   column IS the gram weight of one labelled serving (e.g.
            //   "2 tbsp" with serving_quantity = 32 → 32 g). When that value
            //   is present and plausible (> 0 and ≤ 1000 g — one serving over
            //   a kilogram is junk data) we use it to scale per-100g
            //   nutrition and emit the real per-serving entry. When it's
            //   missing or implausible we fall back to the original behaviour:
            //   drop the volumetric/count serving and let the 100 g companion
            //   (rule 4) stand alone.
            let serving_grams: Option<Decimal> = match unit.family() {
                crate::domain::unit::UnitFamily::Mass => {
                    // Convert to grams via ratio table.
                    Some(amount * unit.ratio_to_canonical())
                }
                crate::domain::unit::UnitFamily::Volume
                | crate::domain::unit::UnitFamily::Count => record
                    .serving_quantity
                    .filter(|q| *q > Decimal::ZERO && *q <= dec!(1000)),
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

/// USDA `dataType` values we accept for ingest. Anything outside this set
/// is dropped (loud-fail) by `accept_and_normalize_usda` per 2.3 — the
/// historical behaviour was a silent `continue` at the writer that lied
/// about import stats.
fn is_known_usda_data_type(raw: &str) -> bool {
    matches!(
        raw.trim().to_ascii_lowercase().as_str(),
        "foundation"
            | "foundation_food"
            | "sr legacy"
            | "sr_legacy"
            | "sr_legacy_food"
            | "survey (fndds)"
            | "survey_fndds_food"
            | "fndds"
            | "branded"
            | "branded_food"
    )
}

/// 4.1: case-insensitive multi-form check for USDA Branded. Real FDC JSON
/// ships `dataType: "Branded"` (PascalCase); the CSV export and our
/// internal canonical form use `"branded_food"`. We accept either. Used
/// by the GTIN stamping path so Branded rows from any source surface
/// their gtinUpc on `FoodDraft.barcode`.
fn is_usda_branded(raw: &str) -> bool {
    matches!(
        raw.trim().to_ascii_lowercase().as_str(),
        "branded" | "branded_food"
    )
}

/// 4.1 + 4.2: sanity-clean a USDA `gtinUpc` for use as a barcode. FDC CSV
/// exports sometimes ship the field with a leading `'` (Excel "force
/// text" escape) or trailing whitespace; we trim and reject anything
/// that isn't pure digits. Returns `Some(cleaned)` when the input is a
/// non-empty digit string, `None` otherwise. The string form is kept
/// verbatim — no zero-padding, no integer round-trip — so leading
/// zeros survive end-to-end.
fn sanitize_gtin(raw: &str, fdc_id: i64) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.bytes().all(|b| b.is_ascii_digit()) {
        Some(trimmed.to_string())
    } else {
        tracing::warn!(
            fdc_id = fdc_id,
            gtin_upc = %raw,
            "USDA gtinUpc contains non-digit characters; nulling barcode but keeping food"
        );
        None
    }
}

/// Convert a raw [`UsdaFoodRecord`] into a [`FoodDraftWithServings`], or
/// `None` if the record fails minimum-viable validation (§7.2 rule 5).
pub fn accept_and_normalize_usda(mut record: UsdaFoodRecord) -> Option<FoodDraftWithServings> {
    // 2.3: drop rows whose `data_type` we don't recognise. The DB writer
    // would reject them downstream anyway (CHECK constraint on
    // `foods.data_type`), but doing it here keeps the per-batch `skipped`
    // counter accurate — `BatchWriteOutcome.skipped` already covers the
    // writer branch, and the normalizer drop is counted via
    // `normalizer_skipped` in `IngestService::run_usda_inner`.
    if !is_known_usda_data_type(&record.data_type) {
        tracing::warn!(
            fdc_id = record.fdc_id,
            data_type = %record.data_type,
            "unknown USDA data_type; dropping row"
        );
        return None;
    }

    // NOTE on USDA Branded basis: Phase 1 originally rescaled Branded
    // `foodNutrients[]` from per-serving to per-100g here, based on a
    // research-agent claim that Branded reports per-serving. The smoke
    // import against real FDC data (Wesson Oil at 867 kcal for 15ml,
    // Coca-Cola at 39 kcal for 355ml) confirmed both numbers only make
    // sense as per-100g — rescaling would have produced 3-5x kcal blowups.
    // Both the CSV bundle and the live API agree on per-100g for Branded.
    // The `servingSize` / `servingSizeUnit` fields are still useful for
    // emitting a per-serving `ServingDraft` alongside the per-100g one,
    // but we do NOT touch the nutrient amounts.

    // §7.2 rule 5: drop if foodPortions empty AND no energy-kcal.
    if record.food_portions.is_empty() && record.energy_kcal_100g.is_none() {
        return None;
    }

    // 1.4: per-field sanity clamps (mirror of the OFF block).
    let fdc_id_str = record.fdc_id.to_string();
    if let Some(k) = record.energy_kcal_100g {
        let k_f = k.to_f64().unwrap_or(0.0);
        if k_f <= 0.0 || k_f > 900.0 {
            tracing::warn!(
                fdc_id = record.fdc_id,
                kcal = %k,
                "implausible USDA kcal/100g (must be in (0, 900]); dropping row"
            );
            // kcal out of range → no servings can be emitted with sane
            // numbers, so drop the row outright (matches the OFF policy).
            return None;
        }
    }
    clamp_macro_field(&mut record.protein_100g, &fdc_id_str, "protein_g_per_100g");
    clamp_macro_field(&mut record.carbs_100g, &fdc_id_str, "carbs_g_per_100g");
    clamp_macro_field(&mut record.fat_100g, &fdc_id_str, "fat_g_per_100g");
    clamp_macro_field(&mut record.fiber_100g, &fdc_id_str, "fiber_g_per_100g");
    clamp_macro_field(&mut record.sugar_100g, &fdc_id_str, "sugars_g_per_100g");
    clamp_macro_field(
        &mut record.saturated_fat_100g,
        &fdc_id_str,
        "saturated_fat_g_per_100g",
    );

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

    // 4.1: only Branded USDA rows can carry a GTIN; Foundation / SR Legacy
    // / Survey rows have no consumer SKU so we never stamp one even if
    // some upstream tool inexplicably populated `gtinUpc`. `is_usda_branded`
    // is case-insensitive to handle real FDC JSON (`"Branded"`) and our
    // canonical form (`"branded_food"`) alike — see 2026-05-19 smoke import.
    let barcode = if is_usda_branded(&record.data_type) {
        record
            .gtin_upc
            .as_deref()
            .and_then(|raw| sanitize_gtin(raw, record.fdc_id))
    } else {
        None
    };

    let draft = FoodDraft {
        name: record.description.trim().to_string(),
        brands: record.brand_owner.filter(|s| !s.trim().is_empty()),
        barcode,
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

/// Phase 2.1: per-run knobs that callers can flip without touching the
/// existing `run_off` / `run_usda` 3-arg signatures. Default is "respect
/// the etag short-circuit"; CLI `--force` flips `force = true`.
#[derive(Debug, Clone, Default)]
pub struct RunOptions {
    /// When `true`, bypass the `find_completed_batch` short-circuit and
    /// always start a fresh import. Useful for redoing a botched import
    /// without re-downloading the source file.
    pub force: bool,
    /// 4.4: drop OFF rows whose `last_modified_t` is older than this
    /// many years. `0` (the default) disables the drop; we ingest
    /// everything and rely on the OFF moderation columns
    /// (`states_tags`, `obsolete`, `data_quality_errors_tags`) for
    /// real quality filtering. `last_modified_t` is "any edit
    /// touched this row" — trivial photo/translation fixes reset it
    /// — so it isn't a reliable proxy for nutrition staleness.
    /// Operators can opt into a cutoff for stricter imports.
    pub stale_after_years: u32,
}

impl IngestService {
    pub fn new(foods: Arc<dyn FoodRepository>, batches: Arc<dyn BatchRepository>) -> Self {
        Self { foods, batches }
    }

    pub async fn run<S: FoodRecordSource>(
        &self,
        source: S,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<UpsertStats> {
        self.run_off_with_options(source, source_url, source_etag, RunOptions::default())
            .await
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
        self.run_off_with_options(source, source_url, source_etag, RunOptions::default())
            .await
    }

    /// Phase 2.1: same as [`Self::run_off`] but takes a [`RunOptions`]
    /// so callers (CLI `--force`) can bypass the etag short-circuit.
    pub async fn run_off_with_options<S: FoodRecordSource>(
        &self,
        mut source: S,
        source_url: &str,
        source_etag: Option<&str>,
        options: RunOptions,
    ) -> CoreResult<UpsertStats> {
        // 2.1: short-circuit if a completed batch already covers this exact
        // (source_url, source_etag) pair. Operator can opt out via --force.
        if !options.force {
            if let Some(existing) = self
                .batches
                .find_completed_batch(source_url, source_etag)
                .await?
            {
                tracing::info!(
                    target: "loseit_ingest::progress",
                    source = "off",
                    batch_id = %existing.id,
                    etag = source_etag.unwrap_or(""),
                    "ingest short-circuit: matching completed batch exists for etag; skipping"
                );
                // Report the original batch's counts so dashboards stay
                // meaningful. Phase 4.3: `merged` rides on `UpsertStats.updated`
                // so callers can still distinguish inserts vs. dedup hits.
                return Ok(UpsertStats {
                    inserted: existing.records_upserted.max(0) as u64,
                    updated: existing.records_merged.max(0) as u64,
                    skipped: existing.records_skipped.max(0) as u64,
                });
            }
        }

        let batch = self.batches.start(source_url, source_etag).await?;
        tracing::info!(
            target: "loseit_ingest::progress",
            source = "off",
            batch_id = %batch.id,
            source_url = %source_url,
            etag = source_etag.unwrap_or(""),
            stale_after_years = options.stale_after_years,
            "ingest starting"
        );
        let started = Instant::now();
        let norm_opts = OffNormalizeOpts {
            stale_cutoff: compute_stale_cutoff(options.stale_after_years),
        };
        let result = self
            .run_inner(&mut source, batch.id, started, "off", &norm_opts)
            .await;
        match result {
            Ok(stats) => {
                self.batches.finish(batch.id, stats.clone()).await?;
                tracing::info!(
                    target: "loseit_ingest::progress",
                    source = "off",
                    batch_id = %batch.id,
                    processed = stats.inserted + stats.updated + stats.skipped,
                    upserted = stats.inserted,
                    merged = stats.updated,
                    skipped = stats.skipped,
                    duration_ms = %started.elapsed().as_millis(),
                    "ingest complete"
                );
                Ok(stats)
            }
            Err(err) => {
                let msg = err.to_string();
                let _ = self.batches.fail(batch.id, &msg).await;
                Err(err)
            }
        }
    }

    /// §7.4: Run the USDA pipeline. Reads `UsdaFoodRecord`s from `source`,
    /// normalizes each via `accept_and_normalize_usda`, and upserts the
    /// resulting `FoodDraftWithServings` batch via
    /// `FoodRepository::upsert_external_food_batch`.
    pub async fn run_usda<S: UsdaSource>(
        &self,
        source: S,
        source_url: &str,
        source_etag: Option<&str>,
    ) -> CoreResult<UpsertStats> {
        self.run_usda_with_options(source, source_url, source_etag, RunOptions::default())
            .await
    }

    /// Phase 2.1: same as [`Self::run_usda`] but takes a [`RunOptions`].
    pub async fn run_usda_with_options<S: UsdaSource>(
        &self,
        mut source: S,
        source_url: &str,
        source_etag: Option<&str>,
        options: RunOptions,
    ) -> CoreResult<UpsertStats> {
        if !options.force {
            if let Some(existing) = self
                .batches
                .find_completed_batch(source_url, source_etag)
                .await?
            {
                tracing::info!(
                    target: "loseit_ingest::progress",
                    source = "usda",
                    batch_id = %existing.id,
                    etag = source_etag.unwrap_or(""),
                    "ingest short-circuit: matching completed batch exists for etag; skipping"
                );
                return Ok(UpsertStats {
                    inserted: existing.records_upserted.max(0) as u64,
                    updated: existing.records_merged.max(0) as u64,
                    skipped: existing.records_skipped.max(0) as u64,
                });
            }
        }

        let batch = self.batches.start(source_url, source_etag).await?;
        tracing::info!(
            target: "loseit_ingest::progress",
            source = "usda",
            batch_id = %batch.id,
            source_url = %source_url,
            etag = source_etag.unwrap_or(""),
            "ingest starting"
        );
        let started = Instant::now();
        let result = self
            .run_usda_inner(&mut source, batch.id, started, "usda")
            .await;
        match result {
            Ok(stats) => {
                self.batches.finish(batch.id, stats.clone()).await?;
                tracing::info!(
                    target: "loseit_ingest::progress",
                    source = "usda",
                    batch_id = %batch.id,
                    processed = stats.inserted + stats.updated + stats.skipped,
                    upserted = stats.inserted,
                    merged = stats.updated,
                    skipped = stats.skipped,
                    duration_ms = %started.elapsed().as_millis(),
                    "ingest complete"
                );
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
        started: Instant,
        source_name: &'static str,
        norm_opts: &OffNormalizeOpts,
    ) -> CoreResult<UpsertStats> {
        let mut total = UpsertStats::default();
        let mut processed: u64 = 0;
        let mut total_upserted: u64 = 0;
        let mut total_merged: u64 = 0;
        let mut total_skipped: u64 = 0;

        loop {
            let chunk_start = Instant::now();
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
                if let Some(upsert) = accept_and_normalize_off_with_opts(record, norm_opts) {
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
            // 1.5: writer-level skip count is rolled in alongside normalizer-level drops.
            let normalizer_skipped = seen.saturating_sub(accepted.len() as u64);

            let outcome = self
                .foods
                .upsert_external_food_batch(batch_id, accepted)
                .await?;

            let upserted = outcome.upserted;
            let merged = outcome.merged;
            let skipped = normalizer_skipped + outcome.skipped;

            total.inserted += upserted;
            total.updated += merged;
            total.skipped += skipped;
            self.batches
                .bump_counts(batch_id, seen, upserted, merged, skipped)
                .await?;

            // 2.2: per-chunk progress log so multi-hour imports surface
            // throughput to operators tailing the logs.
            processed += seen;
            total_upserted += upserted;
            total_merged += merged;
            total_skipped += skipped;
            let total_elapsed = started.elapsed();
            let throughput = if total_elapsed.as_secs_f64() > 0.0 {
                processed as f64 / total_elapsed.as_secs_f64()
            } else {
                0.0
            };
            tracing::info!(
                target: "loseit_ingest::progress",
                source = source_name,
                batch_id = %batch_id,
                processed,
                upserted = total_upserted,
                merged = total_merged,
                skipped = total_skipped,
                chunk_duration_ms = %chunk_start.elapsed().as_millis(),
                throughput_per_sec = %format!("{throughput:.1}"),
                "ingest progress"
            );
        }

        Ok(total)
    }

    async fn run_usda_inner<S: UsdaSource>(
        &self,
        source: &mut S,
        batch_id: Uuid,
        started: Instant,
        source_name: &'static str,
    ) -> CoreResult<UpsertStats> {
        let mut total = UpsertStats::default();
        let mut processed: u64 = 0;
        let mut total_upserted: u64 = 0;
        let mut total_merged: u64 = 0;
        let mut total_skipped: u64 = 0;

        loop {
            let chunk_start = Instant::now();
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
            // 1.5: writer-level skip count is rolled in alongside normalizer-level drops.
            let normalizer_skipped = seen.saturating_sub(accepted.len() as u64);

            let outcome = self
                .foods
                .upsert_external_food_batch(batch_id, accepted)
                .await?;

            let upserted = outcome.upserted;
            let merged = outcome.merged;
            let skipped = normalizer_skipped + outcome.skipped;

            total.inserted += upserted;
            total.updated += merged;
            total.skipped += skipped;
            self.batches
                .bump_counts(batch_id, seen, upserted, merged, skipped)
                .await?;

            // 2.2: per-chunk progress log (USDA twin).
            processed += seen;
            total_upserted += upserted;
            total_merged += merged;
            total_skipped += skipped;
            let total_elapsed = started.elapsed();
            let throughput = if total_elapsed.as_secs_f64() > 0.0 {
                processed as f64 / total_elapsed.as_secs_f64()
            } else {
                0.0
            };
            tracing::info!(
                target: "loseit_ingest::progress",
                source = source_name,
                batch_id = %batch_id,
                processed,
                upserted = total_upserted,
                merged = total_merged,
                skipped = total_skipped,
                chunk_duration_ms = %chunk_start.elapsed().as_millis(),
                throughput_per_sec = %format!("{throughput:.1}"),
                "ingest progress"
            );
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

    // -----------------------------------------------------------------------
    // Phase 1 fixes (import_plan.md §4)
    // -----------------------------------------------------------------------

    /// 1.1: kJ-only OFF row derives kcal as `kj / 4.184` (NIST thermochemical
    /// calorie). The serving emitted by the normaliser must reflect that.
    #[test]
    fn off_derives_kcal_from_kj_when_kcal_missing() {
        // 1500 kJ/100g → 1500 / 4.184 = 358.508... kcal/100g.
        let r = OffFoodRecord {
            code: "KJ001".into(),
            product_name: "KJ-only snack".into(),
            energy_kcal_100g: None,
            energy_kj_100g: Some(dec!(1500)),
            protein_100g: Some(dec!(5)),
            ..Default::default()
        };
        let out = accept_and_normalize_off(r).expect("should accept");
        assert!(!out.servings.is_empty(), "must emit at least 1 serving");
        let s100 = out
            .servings
            .iter()
            .find(|s| s.unit == Unit::Gram && s.amount == dec!(100))
            .expect("100 g companion present");
        let expected = dec!(1500) / dec!(4.184);
        // Compare within ±0.01 kcal.
        let diff = (s100.kcal - expected).abs();
        assert!(
            diff < dec!(0.01),
            "kcal {} not within 0.01 of expected {}",
            s100.kcal,
            expected
        );
    }

    /// 1.1: when both kcal and kJ are present the explicit kcal wins.
    #[test]
    fn off_prefers_explicit_kcal_over_kj() {
        let r = OffFoodRecord {
            code: "KJ002".into(),
            product_name: "Both energies".into(),
            energy_kcal_100g: Some(dec!(200)),
            energy_kj_100g: Some(dec!(9999)),
            ..Default::default()
        };
        let out = accept_and_normalize_off(r).expect("should accept");
        let s100 = out
            .servings
            .iter()
            .find(|s| s.unit == Unit::Gram && s.amount == dec!(100))
            .unwrap();
        assert_eq!(s100.kcal, dec!(200));
    }

    /// Per the 2026-05-19 smoke import: FDC Branded food_nutrient values
    /// are per-100g, NOT per-serving (Wesson Oil ships 867 kcal for a 15ml
    /// serving — only sensible as per-100g; rescale would give 5780).
    /// We pass the values through unchanged regardless of dataType.
    #[test]
    fn usda_branded_kcal_passes_through_per_100g() {
        let r = UsdaFoodRecord {
            fdc_id: 50001,
            data_type: "branded_food".into(),
            description: "Wesson Oil".into(),
            brand_owner: Some("Richardson Oilseed".into()),
            food_portions: vec![],
            energy_kcal_100g: Some(dec!(867)),
            fat_100g: Some(dec!(93.33)),
            serving_size: Some(dec!(15)),
            serving_size_unit: Some("ml".into()),
            ..Default::default()
        };
        let out = accept_and_normalize_usda(r).expect("should accept");
        let s100 = out
            .servings
            .iter()
            .find(|s| s.unit == Unit::Gram && s.amount == dec!(100))
            .expect("100g companion missing");
        // Per-100g pass-through: 867 stays 867.
        assert_eq!(s100.kcal, dec!(867));
        assert_eq!(s100.fat_g, Some(dec!(93.33)));
    }

    /// `dataType` casing variants both flow through unchanged. Pre-fix this
    /// would have exercised the (incorrect) rescale on "branded_food" but
    /// not on "Branded".
    #[test]
    fn usda_branded_data_type_casing_irrelevant() {
        for dt in ["branded_food", "Branded", "BRANDED"] {
            let r = UsdaFoodRecord {
                fdc_id: 50002,
                data_type: dt.into(),
                description: "Coke".into(),
                food_portions: vec![],
                energy_kcal_100g: Some(dec!(39)),
                serving_size: Some(dec!(355)),
                serving_size_unit: Some("ml".into()),
                ..Default::default()
            };
            let out = accept_and_normalize_usda(r).expect("should accept");
            let s100 = out
                .servings
                .iter()
                .find(|s| s.unit == Unit::Gram && s.amount == dec!(100))
                .unwrap();
            // 39 kcal / 100ml is real Coke per-100ml; no rescale should occur.
            assert_eq!(s100.kcal, dec!(39), "dataType={dt} did not pass through");
        }
    }

    /// Foundation rows continue to flow through per-100g. (Same as before
    /// the fix; kept as a regression marker against accidental rescale.)
    #[test]
    fn usda_foundation_passes_through_per_100g() {
        let r = UsdaFoodRecord {
            fdc_id: 50006,
            data_type: "foundation_food".into(),
            description: "Foundation".into(),
            food_portions: vec![],
            energy_kcal_100g: Some(dec!(100)),
            serving_size: Some(dec!(30)),
            serving_size_unit: Some("g".into()),
            ..Default::default()
        };
        let out = accept_and_normalize_usda(r).expect("should accept");
        let s = &out.servings[0];
        assert_eq!(s.kcal, dec!(100));
    }

    /// 1.4: OFF row with 5000 kcal/100g is dropped (out of (0, 900]).
    #[test]
    fn off_implausible_kcal_dropped() {
        let r = OffFoodRecord {
            code: "CL001".into(),
            product_name: "Glow stick".into(),
            energy_kcal_100g: Some(dec!(5000)),
            protein_100g: Some(dec!(5)),
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_none());
    }

    /// 1.4: OFF row with -2g protein keeps the row but nulls the protein field.
    #[test]
    fn off_negative_macro_nulls_field_keeps_row() {
        let r = OffFoodRecord {
            code: "CL002".into(),
            product_name: "Bizarre".into(),
            energy_kcal_100g: Some(dec!(150)),
            protein_100g: Some(dec!(-2)),
            carbs_100g: Some(dec!(20)),
            ..Default::default()
        };
        let out = accept_and_normalize_off(r).expect("row must be kept");
        // The protein field on every emitted serving is None.
        for s in &out.servings {
            assert!(s.protein_g.is_none(), "protein must be nulled");
        }
        // Other fields untouched.
        let s100 = out.servings.iter().find(|s| s.amount == dec!(100)).unwrap();
        assert_eq!(s100.carbs_g, Some(dec!(20)));
    }

    /// 1.4: OFF macro >100 g/100g is nulled.
    #[test]
    fn off_macro_over_100_nulls_field() {
        let r = OffFoodRecord {
            code: "CL003".into(),
            product_name: "Overshoot".into(),
            energy_kcal_100g: Some(dec!(200)),
            fat_100g: Some(dec!(150)),
            carbs_100g: Some(dec!(10)),
            ..Default::default()
        };
        let out = accept_and_normalize_off(r).expect("row must be kept");
        for s in &out.servings {
            assert!(s.fat_g.is_none());
        }
    }

    /// OFF row with a non-empty `data_quality_errors_tags` is dropped
    /// — the upstream classifier already flagged it as bad data.
    #[test]
    fn off_data_quality_errors_tags_drops_row() {
        let r = OffFoodRecord {
            code: "DQ001".into(),
            product_name: "Bad kcal entry".into(),
            energy_kcal_100g: Some(dec!(200)),
            data_quality_errors_tags: vec![
                "en:energy-value-in-kcal-may-be-in-kj".into(),
                "en:nutrition-value-very-high-for-category".into(),
            ],
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_none());
    }

    /// Empty `data_quality_errors_tags` does not drop.
    #[test]
    fn off_empty_data_quality_errors_tags_passes() {
        let r = OffFoodRecord {
            code: "DQ002".into(),
            product_name: "Clean".into(),
            energy_kcal_100g: Some(dec!(200)),
            data_quality_errors_tags: vec![],
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_some());
    }

    /// 1.6: OFF row tagged `en:to-be-deleted` is dropped.
    #[test]
    fn off_to_be_deleted_dropped() {
        let r = OffFoodRecord {
            code: "OB001".into(),
            product_name: "Retired snack".into(),
            energy_kcal_100g: Some(dec!(200)),
            states_tags: vec!["en:to-be-deleted".into(), "en:complete".into()],
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_none());
    }

    /// 1.6: OFF row with `obsolete = true` is dropped.
    #[test]
    fn off_obsolete_dropped() {
        let r = OffFoodRecord {
            code: "OB002".into(),
            product_name: "Obsolete".into(),
            energy_kcal_100g: Some(dec!(200)),
            obsolete: Some(true),
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_none());
    }

    /// 1.6: a row without obsolete signals passes through.
    #[test]
    fn off_clean_row_passes_states_tags_filter() {
        let r = OffFoodRecord {
            code: "OB003".into(),
            product_name: "Clean".into(),
            energy_kcal_100g: Some(dec!(200)),
            states_tags: vec!["en:complete".into()],
            obsolete: Some(false),
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_some());
    }

    /// 1.7: `no_nutrition_data == "on"` drops the row.
    #[test]
    fn off_no_nutrition_data_flag_dropped() {
        let r = OffFoodRecord {
            code: "NN001".into(),
            product_name: "Flagged".into(),
            energy_kcal_100g: Some(dec!(200)),
            no_nutrition_data: Some("on".into()),
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_none());
    }

    /// 1.7: all-zero OFF row (kcal == 0 AND every macro None or 0) is dropped.
    #[test]
    fn off_all_zero_row_dropped() {
        let r = OffFoodRecord {
            code: "ZZ001".into(),
            product_name: "Hollow".into(),
            energy_kcal_100g: Some(Decimal::ZERO),
            protein_100g: Some(Decimal::ZERO),
            carbs_100g: Some(Decimal::ZERO),
            fat_100g: None,
            ..Default::default()
        };
        assert!(accept_and_normalize_off(r).is_none());
    }

    // -----------------------------------------------------------------------
    // Phase 4 fixes (import_plan.md §4)
    // -----------------------------------------------------------------------

    /// 4.1: USDA Branded with a clean `gtin_upc` lands on `FoodDraft.barcode`
    /// verbatim — leading zero preserved end-to-end (no int coercion path).
    #[test]
    fn usda_branded_stamps_barcode_from_gtin_upc() {
        let r = UsdaFoodRecord {
            fdc_id: 60001,
            data_type: "Branded".into(), // PascalCase, real-world casing
            description: "Coca-Cola".into(),
            food_portions: vec![],
            energy_kcal_100g: Some(dec!(39)),
            gtin_upc: Some("0049000028911".into()),
            ..Default::default()
        };
        let out = accept_and_normalize_usda(r).expect("should accept");
        assert_eq!(
            out.draft.barcode.as_deref(),
            Some("0049000028911"),
            "Branded GTIN must land on FoodDraft.barcode verbatim (leading 0 kept)"
        );
        assert_eq!(out.draft.fdc_id, Some(60001));
    }

    /// 4.1: Foundation rows never carry a GTIN even when `gtin_upc` is
    /// erroneously present in the input — only Branded foods are stamped.
    #[test]
    fn usda_foundation_leaves_barcode_none() {
        let r = UsdaFoodRecord {
            fdc_id: 60002,
            data_type: "foundation_food".into(),
            description: "Butter".into(),
            food_portions: vec![],
            energy_kcal_100g: Some(dec!(717)),
            gtin_upc: Some("not-applicable".into()),
            ..Default::default()
        };
        let out = accept_and_normalize_usda(r).expect("should accept");
        assert!(
            out.draft.barcode.is_none(),
            "Foundation rows must NOT stamp a barcode even if gtin_upc is set"
        );
    }

    /// 4.1: whitespace-only `gtin_upc` on a Branded row is treated as
    /// missing — the food is kept, barcode is `None`.
    #[test]
    fn usda_branded_whitespace_gtin_rejected() {
        let r = UsdaFoodRecord {
            fdc_id: 60003,
            data_type: "branded_food".into(),
            description: "Mystery Bar".into(),
            food_portions: vec![],
            energy_kcal_100g: Some(dec!(200)),
            gtin_upc: Some("   ".into()),
            ..Default::default()
        };
        let out = accept_and_normalize_usda(r).expect("should accept");
        assert!(
            out.draft.barcode.is_none(),
            "whitespace-only gtin_upc must yield no barcode"
        );
    }

    /// 4.1: Branded with a non-digit `gtin_upc` (CSV leading apostrophe,
    /// stray punctuation) is rejected — barcode is `None` but the food
    /// survives. A `tracing::warn!` fires (not asserted here; tested
    /// via log capture in the integration suite).
    #[test]
    fn usda_branded_non_digit_gtin_rejected() {
        let r = UsdaFoodRecord {
            fdc_id: 60004,
            data_type: "Branded".into(),
            description: "Excel-Escaped".into(),
            food_portions: vec![],
            energy_kcal_100g: Some(dec!(150)),
            gtin_upc: Some("'00490000289".into()),
            ..Default::default()
        };
        let out = accept_and_normalize_usda(r).expect("food must NOT be dropped");
        assert!(out.draft.barcode.is_none());
    }

    /// 4.2: leading-zero barcode round-trips through the OFF normaliser
    /// byte-identical. The `code` field is `String` end-to-end; this is
    /// the regression marker against any future int-coercion refactor.
    #[test]
    fn off_leading_zero_barcode_preserved() {
        let r = OffFoodRecord {
            code: "0049000028911".into(),
            product_name: "Coca-Cola (OFF)".into(),
            energy_kcal_100g: Some(dec!(39)),
            ..Default::default()
        };
        let out = accept_and_normalize_off(r).expect("should accept");
        assert_eq!(out.draft.barcode.as_deref(), Some("0049000028911"));
    }

    /// 4.4: a row with `last_modified_t` older than the cutoff is dropped.
    #[test]
    fn off_stale_row_dropped() {
        // Cutoff = now - 5 years; row last modified 6 years ago.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let cutoff = now - 5 * 31_557_600;
        let r = OffFoodRecord {
            code: "ST001".into(),
            product_name: "Antique Snack".into(),
            energy_kcal_100g: Some(dec!(200)),
            last_modified_t: Some(now - 6 * 31_557_600),
            ..Default::default()
        };
        let opts = OffNormalizeOpts {
            stale_cutoff: Some(cutoff),
        };
        assert!(
            accept_and_normalize_off_with_opts(r, &opts).is_none(),
            "6-year-old row must be dropped under a 5-year cutoff"
        );
    }

    /// 4.4: a row 4 years old is kept (well under a 5-year cutoff).
    #[test]
    fn off_fresh_row_kept() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let cutoff = now - 5 * 31_557_600;
        let r = OffFoodRecord {
            code: "ST002".into(),
            product_name: "Fresh Snack".into(),
            energy_kcal_100g: Some(dec!(200)),
            last_modified_t: Some(now - 4 * 31_557_600),
            ..Default::default()
        };
        let opts = OffNormalizeOpts {
            stale_cutoff: Some(cutoff),
        };
        assert!(
            accept_and_normalize_off_with_opts(r, &opts).is_some(),
            "4-year-old row must pass a 5-year cutoff"
        );
    }

    /// 4.4: a row with no `last_modified_t` is conservatively kept — the
    /// source didn't tell us when the row was last touched, so we
    /// preserve it rather than silently drop.
    #[test]
    fn off_missing_last_modified_kept() {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let cutoff = now - 5 * 31_557_600;
        let r = OffFoodRecord {
            code: "ST003".into(),
            product_name: "No Timestamp".into(),
            energy_kcal_100g: Some(dec!(200)),
            last_modified_t: None,
            ..Default::default()
        };
        let opts = OffNormalizeOpts {
            stale_cutoff: Some(cutoff),
        };
        assert!(accept_and_normalize_off_with_opts(r, &opts).is_some());
    }

    /// 4.4: `--stale-after-years 0` returns `None` from `compute_stale_cutoff`
    /// → the normaliser keeps a 6-year-old row.
    #[test]
    fn off_stale_after_years_zero_keeps_everything() {
        assert!(compute_stale_cutoff(0).is_none());
        // And a stale row passes when opts.stale_cutoff == None.
        let r = OffFoodRecord {
            code: "ST004".into(),
            product_name: "Vintage".into(),
            energy_kcal_100g: Some(dec!(200)),
            last_modified_t: Some(0), // 1970 — the oldest possible record
            ..Default::default()
        };
        let opts = OffNormalizeOpts { stale_cutoff: None };
        assert!(
            accept_and_normalize_off_with_opts(r, &opts).is_some(),
            "stale_cutoff = None must keep everything"
        );
    }
}
