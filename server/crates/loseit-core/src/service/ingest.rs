use std::collections::HashSet;
use std::str::FromStr;
use std::sync::Arc;

use async_trait::async_trait;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::domain::{FoodDraft, NutriscoreGrade, ServingDraft, ServingSource, Unit};
use crate::repo::{BatchRepository, FoodDraftWithServings, FoodRepository, ServingRepository, UpsertStats};
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
/// amortized for the OFF dump (~3M rows).
pub const BATCH_SIZE: usize = 500;
/// Sanity threshold for sodium per 100 g. OFF stores sodium in g/100g; >50g
/// per 100g is implausible (almost certainly someone uploaded mg).
pub const SODIUM_GRAMS_SANITY_THRESHOLD: f64 = 50.0;

/// Streaming batch upsert orchestrator. T14 rewrites the normalizer body.
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
                if let Some(upsert) = accept_and_normalize(record) {
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
}

/// Build a placeholder system `100 g` serving draft.
/// T14 will replace this with per-serving nutrition from the new normalizer.
fn make_system_100g_serving_draft(is_default: bool) -> ServingDraft {
    ServingDraft {
        label: Some("100 g".to_string()),
        amount: Decimal::from(100),
        unit: Unit::Gram,
        kcal: Decimal::ZERO, // placeholder — T14 fills nutrition
        protein_g: None,
        carbs_g: None,
        fat_g: None,
        fiber_g: None,
        sugar_g: None,
        sodium_mg: None,
        saturated_fat_g: None,
        is_default,
        source: ServingSource::System,
        sort_order: 0,
    }
}

/// Build a placeholder OFF-derived serving draft.
/// T14 will replace this with per-serving nutrition from the new normalizer.
fn make_off_serving_draft_placeholder(label: String, grams: Decimal) -> ServingDraft {
    ServingDraft {
        label: Some(label),
        amount: grams,
        unit: Unit::Gram,
        kcal: Decimal::ZERO, // placeholder — T14 fills nutrition
        protein_g: None,
        carbs_g: None,
        fat_g: None,
        fiber_g: None,
        sugar_g: None,
        sodium_mg: None,
        saturated_fat_g: None,
        is_default: true,
        source: ServingSource::Off,
        sort_order: 1,
    }
}

/// Convert a raw [`OffFoodRecord`] into a [`FoodDraftWithServings`], or
/// `None` if the record fails minimum-viable validation. T14 rewrites the
/// normalizer to emit full per-serving nutrition.
pub fn accept_and_normalize(mut record: OffFoodRecord) -> Option<FoodDraftWithServings> {
    if record.code.trim().is_empty() {
        return None;
    }
    if record.product_name.trim().is_empty() {
        return None;
    }
    record.energy_kcal_100g?;

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
    let (off_label, off_grams) = derive_off_serving_parts(&record);

    let nutriscore_grade = record
        .nutriscore_grade
        .as_deref()
        .and_then(NutriscoreGrade::parse);

    // Build serving list. T14 will fill real per-serving nutrition here.
    let mut servings: Vec<ServingDraft> = Vec::new();
    if let (Some(label), Some(grams)) = (off_label, off_grams) {
        servings.push(make_off_serving_draft_placeholder(label, grams));
        servings.push(make_system_100g_serving_draft(false));
    } else {
        servings.push(make_system_100g_serving_draft(true));
    }

    // FoodDraft.servings is no longer used for ingest — servings are carried
    // on FoodDraftWithServings directly. Pass empty here.
    let draft = FoodDraft {
        name: record.product_name.trim().to_string(),
        brands: record.brands.clone().filter(|s| !s.trim().is_empty()),
        barcode: Some(record.code.trim().to_string()),
        categories_tags: record.categories_tags.clone(),
        nutriscore_grade,
        servings: vec![], // T14: emit actual ServingDraft rows via FoodDraftWithServings.servings
    };

    Some(FoodDraftWithServings {
        draft,
        quality_score,
        servings,
    })
}

/// Derive an OFF-named serving (label, grams) from the record, if possible.
fn derive_off_serving_parts(record: &OffFoodRecord) -> (Option<String>, Option<Decimal>) {
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
        (Some(label), Some(g))
    } else {
        (None, None)
    }
}

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

/// Parse a serving-size string to grams.
pub fn parse_serving_size_grams(s: &str) -> Option<Decimal> {
    let bytes = s.as_bytes();
    let mut best: Option<Decimal> = None;
    let mut i = 0usize;
    while i < bytes.len() {
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
        let num_end = i;
        let num_str = &s[start..num_end];

        while i < bytes.len() && bytes[i] == b' ' {
            i += 1;
        }
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
    }
    best
}
