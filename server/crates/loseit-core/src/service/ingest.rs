use std::collections::HashSet;
use std::str::FromStr;
use std::sync::Arc;

use async_trait::async_trait;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::{FoodDraft, NutriscoreGrade, NutritionPer100g, ServingDraft, ServingSource};
use crate::repo::{
    BatchRepository, FoodRepository, OffFoodUpsert, OffServing, ServingRepository, SystemServing,
    UpsertStats,
};
use crate::CoreResult;

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
    pub sodium_100g: Option<Decimal>,
    pub saturated_fat_100g: Option<Decimal>,
}

/// Chunked record stream the ingest service pulls from. Implementations
/// live in `loseit-ingest` (parquet + JSONL); a `Vec`-backed
/// implementation in `loseit-testing` powers unit tests.
#[async_trait]
pub trait FoodRecordSource: Send {
    /// Return the next chunk of up to `n` records. `Ok(None)` means the
    /// source is exhausted.
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<OffFoodRecord>>>;
}

/// Chunk size hand-tuned to keep memory bounded and round-trip overhead
/// amortized for the OFF dump (~3M rows). 500 was chosen so a single
/// `find_ids_by_barcodes` call after the upsert fits comfortably in one
/// statement.
pub const BATCH_SIZE: usize = 500;
/// Sanity threshold for sodium per 100 g. OFF stores sodium in grams; >50g
/// per 100g is implausible (almost certainly someone uploaded mg).
pub const SODIUM_GRAMS_SANITY_THRESHOLD: f64 = 50.0;

/// Streaming batch upsert orchestrator. Body lives here in T18.
pub struct IngestService {
    foods: Arc<dyn FoodRepository>,
    servings: Arc<dyn ServingRepository>,
    batches: Arc<dyn BatchRepository>,
}

impl IngestService {
    pub fn new(
        foods: Arc<dyn FoodRepository>,
        servings: Arc<dyn ServingRepository>,
        batches: Arc<dyn BatchRepository>,
    ) -> Self {
        Self {
            foods,
            servings,
            batches,
        }
    }

    pub fn foods(&self) -> &Arc<dyn FoodRepository> {
        &self.foods
    }

    pub fn servings(&self) -> &Arc<dyn ServingRepository> {
        &self.servings
    }

    pub fn batches(&self) -> &Arc<dyn BatchRepository> {
        &self.batches
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
                // Best-effort: surface the failure on the batch record but
                // propagate the original error to the caller regardless.
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

            // Filter + normalize. Within a single chunk OFF occasionally
            // duplicates barcodes; we dedupe (last write wins) so the
            // upsert call has a clean set and the post-upsert barcode
            // lookup is unambiguous.
            let mut accepted: Vec<OffFoodUpsert> = Vec::with_capacity(chunk.len());
            let mut seen_barcodes: HashSet<String> = HashSet::new();
            for record in chunk {
                if let Some(upsert) = accept_and_normalize(record) {
                    // dedupe within the chunk
                    if let Some(bc) = upsert.draft.barcode.clone() {
                        if !seen_barcodes.insert(bc) {
                            // already have this barcode in this chunk
                            // overwrite the previous entry
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

            let stats = self.foods.upsert_off_batch(batch_id, &accepted).await?;

            // Look up the resulting food ids by barcode so we can wire up
            // servings without N round-trips. NIL_USER for visibility
            // because OFF foods are visible to everyone.
            let barcodes: Vec<&str> = accepted
                .iter()
                .filter_map(|u| u.draft.barcode.as_deref())
                .collect();
            let ids = self
                .foods
                .find_ids_by_barcodes(Uuid::nil(), &barcodes)
                .await?;

            for upsert in &accepted {
                let Some(bc) = upsert.draft.barcode.as_deref() else {
                    continue;
                };
                let Some(food_id) = ids.get(bc).copied() else {
                    continue;
                };
                self.materialize_servings(food_id, upsert).await?;
            }

            total.inserted += stats.inserted;
            total.updated += stats.updated;
            total.skipped += skipped;
            self.batches
                .bump_counts(batch_id, seen, stats.inserted + stats.updated, skipped)
                .await?;
        }

        Ok(total)
    }

    /// Idempotently materialize the system 100 g serving + (optional) OFF
    /// serving for a freshly upserted food. The in-memory repo's
    /// `upsert_off_batch` already rebuilds servings for OFF foods; the Pg
    /// path doesn't, so this is where the Pg side creates them. We avoid
    /// duplicates by checking the existing serving set first.
    async fn materialize_servings(&self, food_id: Uuid, upsert: &OffFoodUpsert) -> CoreResult<()> {
        let existing = self.servings.list_for_food(food_id).await?;
        let has_off_existing = existing.iter().any(|s| s.source == ServingSource::Off);
        let off_present = upsert.off_serving.is_some();

        // Ensure a system 100 g serving exists.
        let system_id = match existing.iter().find(|s| s.source == ServingSource::System) {
            Some(s) => s.id,
            None => {
                let draft = ServingDraft {
                    label: upsert.system_100g_serving.label.clone(),
                    grams: upsert.system_100g_serving.grams,
                    // Default starts on the system row; the OFF row will
                    // steal it via `set_default` below if present.
                    is_default: !off_present,
                    source: ServingSource::System,
                    sort_order: 0,
                };
                let s = self.servings.create(food_id, &draft).await?;
                s.id
            }
        };

        if let Some(off) = &upsert.off_serving {
            if !has_off_existing {
                let draft = ServingDraft {
                    label: off.label.clone(),
                    grams: off.grams,
                    is_default: true,
                    source: ServingSource::Off,
                    sort_order: 1,
                };
                let off_serving = self.servings.create(food_id, &draft).await?;
                self.servings.set_default(food_id, off_serving.id).await?;
            }
        } else if !existing.iter().any(|s| s.is_default) {
            // No OFF serving and no existing default — pin the system row.
            self.servings.set_default(food_id, system_id).await?;
        }

        Ok(())
    }
}

/// Convert a raw [`OffFoodRecord`] into the storage-shaped
/// [`OffFoodUpsert`], or `None` if the record fails minimum-viable
/// validation (no barcode, no name, or no energy data — see T18 spec).
/// Sodium > 50 g/100g is dropped (not the whole record) with a
/// `tracing::warn!`.
pub fn accept_and_normalize(mut record: OffFoodRecord) -> Option<OffFoodUpsert> {
    if record.code.trim().is_empty() {
        return None;
    }
    if record.product_name.trim().is_empty() {
        return None;
    }
    record.energy_kcal_100g?;

    // Sodium sanity check. OFF stores sodium in g/100g; we keep that
    // convention. >50g/100g is implausible — almost certainly mg-as-g.
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

    let quality_score = score(&record);
    let (off_serving, _grams) = derive_off_serving(&record);

    let nutrition = NutritionPer100g {
        energy_kcal: record.energy_kcal_100g,
        protein_g: record.protein_100g,
        carbs_g: record.carbs_100g,
        fat_g: record.fat_100g,
        fiber_g: record.fiber_100g,
        sugar_g: record.sugar_100g,
        sodium_g: record.sodium_100g,
        saturated_fat_g: record.saturated_fat_100g,
    };

    let nutriscore_grade = record
        .nutriscore_grade
        .as_deref()
        .and_then(NutriscoreGrade::parse);

    let draft = FoodDraft {
        name: record.product_name.trim().to_string(),
        brands: record.brands.clone().filter(|s| !s.trim().is_empty()),
        barcode: Some(record.code.trim().to_string()),
        categories_tags: record.categories_tags.clone(),
        nutrition,
        nutriscore_grade,
    };

    Some(OffFoodUpsert {
        draft,
        quality_score,
        off_serving,
        system_100g_serving: SystemServing {
            label: "100 g".to_string(),
            grams: Decimal::from(100),
        },
    })
}

/// Derive an OFF-named serving from the record, if possible. Returns the
/// `OffServing` plus the parsed grams (which the quality-score also
/// consults).
fn derive_off_serving(record: &OffFoodRecord) -> (Option<OffServing>, Option<Decimal>) {
    // Prefer the structured `serving_quantity` if present and positive,
    // falling back to parsing `serving_size` ("30 g" / "1 cup (240 g)").
    let from_quantity = record.serving_quantity.filter(|q| *q > Decimal::ZERO);

    let from_size = record
        .serving_size
        .as_deref()
        .and_then(parse_serving_size_grams)
        .filter(|g| *g > Decimal::ZERO);

    let grams = from_quantity.or(from_size);

    if let Some(g) = grams {
        let label = record
            .serving_size
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| format!("{} g", g));
        (Some(OffServing { label, grams: g }), Some(g))
    } else {
        (None, None)
    }
}

/// Compute the 0..=100 quality score for an OFF record. The score is a
/// rough proxy for "how usable is this record for a tracking app" and
/// drives ranking in `/foods/search`.
///
/// Breakdown (max 100):
///   - 40 pts: `nutriscore_grade` is Some and parses to a known grade.
///   - 15 pts: `brands` is Some and non-empty after trim.
///   - 15 pts: a usable OFF-derived serving exists (positive
///     `serving_quantity` or `parse_serving_size_grams` succeeds).
///   - 10 pts: ≥6 of the seven non-energy nutrient fields are populated.
///     5 pts: 3..=5 of them populated.
///   - up to 10 pts: `round(min(completeness, 1.0) * 10)`.
///   - 10 pts: `categories_tags` non-empty.
pub fn score(record: &OffFoodRecord) -> i16 {
    let mut total: i32 = 0;

    // Nutriscore (40 pts).
    if let Some(g) = record.nutriscore_grade.as_deref() {
        if NutriscoreGrade::parse(g).is_some() {
            total += 40;
        }
    }

    // Brand (15 pts).
    if record
        .brands
        .as_deref()
        .map(|b| !b.trim().is_empty())
        .unwrap_or(false)
    {
        total += 15;
    }

    // OFF-derived serving (15 pts).
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

    // Nutrient population (5 or 10 pts).
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

    // Completeness (up to 10 pts).
    if let Some(c) = record.completeness {
        let clamped = c.clamp(0.0, 1.0);
        total += (clamped * 10.0).round() as i32;
    }

    // Categories (10 pts).
    if !record.categories_tags.is_empty() {
        total += 10;
    }

    total.clamp(0, 100) as i16
}

/// Parse a serving-size string to grams. Handles `"30 g"`, `"30g"`,
/// `"30.5 g"`, `"1 cup (240 g)"`. Pure-ml entries return `None` (the v1
/// scope skips volume-only servings since we don't track density).
///
/// Implementation: greedily scan for `(\d+\.?\d*)\s*g\b` patterns and take
/// the **last** match, which is the disambiguating one in
/// `"1 cup (240 g)"`. ASCII-only by design — the OFF dump puts non-ASCII
/// volume units (cl, oz…) in plain text we can't trust.
pub fn parse_serving_size_grams(s: &str) -> Option<Decimal> {
    let bytes = s.as_bytes();
    let mut best: Option<Decimal> = None;
    let mut i = 0usize;
    while i < bytes.len() {
        // Skip until we find an ASCII digit.
        if !bytes[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        // Consume the numeric run (digits and at most one dot).
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
        let num_end = i;
        let num_str = &s[start..num_end];

        // Skip optional whitespace between number and unit.
        while i < bytes.len() && bytes[i] == b' ' {
            i += 1;
        }
        // Check the unit. We accept `g`, `G`, `gr`, `grams` (case-insensitive),
        // but reject `gal`, `gallon`, etc. by requiring the unit to end at
        // a non-letter boundary.
        let unit_start = i;
        while i < bytes.len() && bytes[i].is_ascii_alphabetic() {
            i += 1;
        }
        let unit = s[unit_start..i].to_ascii_lowercase();
        let is_grams = matches!(unit.as_str(), "g" | "gr" | "gram" | "grams");
        if is_grams {
            if let Ok(parsed) = Decimal::from_str(num_str) {
                best = Some(parsed);
            }
        }
        // continue scanning
    }
    best
}
