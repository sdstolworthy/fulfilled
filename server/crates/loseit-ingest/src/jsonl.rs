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
    /// 1.6: OFF `states_tags` — used to drop obsolete / to-be-deleted rows.
    states_tags: Vec<String>,
    /// 1.6: OFF `obsolete` flag.
    obsolete: Option<bool>,
    /// 1.7: OFF `no_nutrition_data` — string `"on"` means the row has no
    /// nutrition info per the contributor.
    no_nutrition_data: Option<String>,
    /// 4.4: OFF `last_modified_t` — Unix epoch seconds of the most recent
    /// contributor edit. Used by `accept_and_normalize_off_with_opts` to
    /// drop rows that have been stale for more than `--stale-after-years`.
    last_modified_t: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct RawNutriments {
    #[serde(rename = "energy-kcal_100g")]
    energy_kcal_100g: Option<LenientNumber>,
    /// 1.1: OFF `energy-kj_100g` — used as a fallback when the kcal
    /// column is missing. The normaliser converts kJ → kcal at 4.184.
    #[serde(rename = "energy-kj_100g")]
    energy_kj_100g: Option<LenientNumber>,
    #[serde(rename = "proteins_100g")]
    proteins_100g: Option<LenientNumber>,
    #[serde(rename = "carbohydrates_100g")]
    carbohydrates_100g: Option<LenientNumber>,
    #[serde(rename = "fat_100g")]
    fat_100g: Option<LenientNumber>,
    #[serde(rename = "fiber_100g")]
    fiber_100g: Option<LenientNumber>,
    #[serde(rename = "sugars_100g")]
    sugars_100g: Option<LenientNumber>,
    #[serde(rename = "sodium_100g")]
    sodium_100g: Option<LenientNumber>,
    #[serde(rename = "saturated-fat_100g")]
    saturated_fat_100g: Option<LenientNumber>,
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

/// 1.3: Lenient deserializer for nutrient fields. Accepts:
/// - a JSON number (canonical case),
/// - a string holding a number (`"1.5"`, `"  3 "`),
/// - a comma-decimal string (`"1,5"` → `1.5` — used by many EU locales),
/// - `"trace"` / `"traces"` → `Some(0.0)`,
/// - `"<N"` / `"< N"` (any numeric N) → `Some(0.0)` (below the limit
///   of detection — treat as effectively zero),
/// - empty / `"null"` / `"NaN"` → `None`.
///
/// Anything else logs a debug-level message and resolves to `None`
/// (the *field* is dropped, but the *line* is not — this is the entire
/// point: today a single `"trace"` value drops the whole product).
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum LenientNumber {
    Number(f64),
    String(String),
}

impl LenientNumber {
    fn as_decimal(&self) -> Option<Decimal> {
        match self {
            LenientNumber::Number(n) => f64_to_decimal(*n),
            LenientNumber::String(s) => parse_lenient_string(s),
        }
    }
}

/// 1.3: parse the textual nutrient variants seen in real OFF data.
pub(crate) fn parse_lenient_string(s: &str) -> Option<Decimal> {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Common textual sentinels — explicit None.
    let lower = trimmed.to_ascii_lowercase();
    if lower == "nan" || lower == "null" || lower == "none" || lower == "-" {
        return None;
    }
    // "trace" / "traces" → 0.
    if lower == "trace" || lower == "traces" {
        return Some(Decimal::ZERO);
    }
    // "<N" (below limit of detection) → 0. Handle "<0.5", "< 0.5", "<.5", etc.
    if let Some(rest) = trimmed.strip_prefix('<') {
        let rest = rest.trim();
        // We accept any well-formed numeric, comma-decimal included.
        if rest.is_empty() || parse_numeric_lenient(rest).is_some() {
            return Some(Decimal::ZERO);
        }
    }
    // Plain numeric (handles comma-decimal too).
    if let Some(d) = parse_numeric_lenient(trimmed) {
        return Some(d);
    }
    tracing::debug!(value = %trimmed, "unparseable OFF nutrient text; nulling field");
    None
}

/// Parse a numeric string allowing comma-decimal (EU locale): `"1,5"` → `1.5`.
fn parse_numeric_lenient(s: &str) -> Option<Decimal> {
    let candidate = if s.contains(',') && !s.contains('.') {
        // Treat the comma as a decimal point; this is the OFF/EU
        // convention. Multi-comma values (`"1,234,5"`) fall through to
        // `from_str` and naturally fail.
        s.replacen(',', ".", 1)
    } else {
        s.to_string()
    };
    Decimal::from_str(candidate.trim()).ok()
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
            energy_kcal_100g: n
                .energy_kcal_100g
                .as_ref()
                .and_then(LenientNumber::as_decimal),
            energy_kj_100g: n
                .energy_kj_100g
                .as_ref()
                .and_then(LenientNumber::as_decimal),
            protein_100g: n.proteins_100g.as_ref().and_then(LenientNumber::as_decimal),
            carbs_100g: n
                .carbohydrates_100g
                .as_ref()
                .and_then(LenientNumber::as_decimal),
            fat_100g: n.fat_100g.as_ref().and_then(LenientNumber::as_decimal),
            fiber_100g: n.fiber_100g.as_ref().and_then(LenientNumber::as_decimal),
            sugar_100g: n.sugars_100g.as_ref().and_then(LenientNumber::as_decimal),
            sodium_100g: n.sodium_100g.as_ref().and_then(LenientNumber::as_decimal),
            saturated_fat_100g: n
                .saturated_fat_100g
                .as_ref()
                .and_then(LenientNumber::as_decimal),
            states_tags: self.states_tags,
            obsolete: self.obsolete,
            no_nutrition_data: self.no_nutrition_data,
            last_modified_t: self.last_modified_t,
        })
    }
}

// ---------------------------------------------------------------------------
// Tests (1.3: lenient nutrient parsing)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    /// 1.3: `"trace"` → 0.
    #[test]
    fn lenient_trace_becomes_zero() {
        assert_eq!(parse_lenient_string("trace"), Some(Decimal::ZERO));
        assert_eq!(parse_lenient_string("TRACE"), Some(Decimal::ZERO));
        assert_eq!(parse_lenient_string("  traces  "), Some(Decimal::ZERO));
    }

    /// 1.3: `"<0.5"`, `"< 0.5"`, `"<5"` → 0.
    #[test]
    fn lenient_below_limit_becomes_zero() {
        assert_eq!(parse_lenient_string("<0.5"), Some(Decimal::ZERO));
        assert_eq!(parse_lenient_string("< 0.5"), Some(Decimal::ZERO));
        assert_eq!(parse_lenient_string("<5"), Some(Decimal::ZERO));
        assert_eq!(parse_lenient_string("<2,5"), Some(Decimal::ZERO));
    }

    /// 1.3: comma-decimal `"1,5"` → 1.5.
    #[test]
    fn lenient_comma_decimal_parses() {
        assert_eq!(parse_lenient_string("1,5"), Some(dec!(1.5)));
        assert_eq!(parse_lenient_string("12,75"), Some(dec!(12.75)));
        // Plain dot-decimal still works.
        assert_eq!(parse_lenient_string("1.5"), Some(dec!(1.5)));
    }

    /// 1.3: `"NaN"`, `"null"`, `""` → None (field nulled, line kept).
    #[test]
    fn lenient_sentinels_become_none() {
        assert!(parse_lenient_string("NaN").is_none());
        assert!(parse_lenient_string("nan").is_none());
        assert!(parse_lenient_string("null").is_none());
        assert!(parse_lenient_string("").is_none());
        assert!(parse_lenient_string("   ").is_none());
        assert!(parse_lenient_string("-").is_none());
    }

    /// 1.3: unparseable garbage → None (field nulled, **line kept**). This
    /// is the regression marker: today a `"???"` value in a JSON number
    /// field crashes serde for the whole record; with `LenientNumber` only
    /// the field is dropped.
    #[test]
    fn lenient_garbage_becomes_none() {
        assert!(parse_lenient_string("???").is_none());
        assert!(parse_lenient_string("abc").is_none());
    }

    /// 1.3 end-to-end: a JSONL line with a `"trace"` nutrient value parses
    /// (line kept) instead of being dropped wholesale. Prior to 1.3 the
    /// `f64` deserializer rejected the line on first non-numeric nutrient.
    #[test]
    fn jsonl_line_with_trace_nutrient_parses() {
        let line = r#"{
            "code": "BC100",
            "product_name": "Trace Cracker",
            "nutriments": {
                "energy-kcal_100g": 400,
                "proteins_100g": "trace",
                "carbohydrates_100g": "1,5",
                "fat_100g": "<0.5"
            }
        }"#;
        let raw: OffRaw = serde_json::from_str(line).expect("line must parse");
        let rec = raw.into_record().expect("record must materialise");
        assert_eq!(rec.code, "BC100");
        assert_eq!(rec.energy_kcal_100g, Some(dec!(400)));
        assert_eq!(rec.protein_100g, Some(Decimal::ZERO));
        assert_eq!(rec.carbs_100g, Some(dec!(1.5)));
        assert_eq!(rec.fat_100g, Some(Decimal::ZERO));
    }

    /// 1.6: `states_tags` + `obsolete` survive deserialization.
    #[test]
    fn jsonl_states_tags_and_obsolete_threaded() {
        let line = r#"{
            "code": "BC200",
            "product_name": "Obsolete",
            "states_tags": ["en:to-be-deleted", "en:complete"],
            "obsolete": true
        }"#;
        let raw: OffRaw = serde_json::from_str(line).expect("line must parse");
        let rec = raw.into_record().expect("record must materialise");
        assert!(rec.states_tags.iter().any(|t| t == "en:to-be-deleted"));
        assert_eq!(rec.obsolete, Some(true));
    }

    /// 1.1: `energy-kj_100g` surfaces on the normalized record so the
    /// normaliser can derive kcal.
    #[test]
    fn jsonl_kj_only_surfaces_on_record() {
        let line = r#"{
            "code": "BC300",
            "product_name": "kJ-only Snack",
            "nutriments": {
                "energy-kj_100g": 1500
            }
        }"#;
        let raw: OffRaw = serde_json::from_str(line).expect("line must parse");
        let rec = raw.into_record().expect("record must materialise");
        assert_eq!(rec.energy_kj_100g, Some(dec!(1500)));
        assert!(rec.energy_kcal_100g.is_none());
    }
}
