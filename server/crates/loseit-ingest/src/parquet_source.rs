//! Apache Parquet source for the OFF dump.
//!
//! The OFF parquet has a flat schema with kebab-case columns (e.g.
//! `energy-kcal_100g`, `saturated-fat_100g`) and a few list-typed
//! columns (`categories_tags`). Schemas drift across OFF releases, so we
//! introspect the file's schema at open-time, project only the columns
//! we recognize, and reach for column indices by name during the row
//! decode. Unknown / missing columns degrade to `None`.
//!
//! Internally we buffer one Arrow [`RecordBatch`] worth of decoded
//! [`OffFoodRecord`]s; `next_chunk` drains from that buffer, pulling a
//! fresh batch from the stream whenever it empties.

use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::Arc;

use arrow::array::{
    Array, BooleanArray, Float32Array, Float64Array, Int32Array, Int64Array, LargeStringArray,
    ListArray, StringArray,
};
use arrow_schema::{DataType, SchemaRef};
use async_trait::async_trait;
use futures::StreamExt;
use loseit_core::service::{FoodRecordSource, OffFoodRecord};
use loseit_core::CoreResult;
use parquet::arrow::arrow_reader::ArrowReaderOptions;
use parquet::arrow::async_reader::{ParquetRecordBatchStream, ParquetRecordBatchStreamBuilder};
use parquet::arrow::ProjectionMask;
use rust_decimal::Decimal;
use tokio::fs::File;

/// Columns we attempt to project from the OFF parquet. Any that are
/// missing from a particular dump are skipped silently — the record's
/// corresponding field stays `None`.
const PROJECTED_COLUMNS: &[&str] = &[
    "code",
    "product_name",
    "brands",
    "categories_tags",
    "nutriscore_grade",
    "completeness",
    "serving_size",
    "serving_quantity",
    "energy-kcal_100g",
    // 1.1: kJ fallback for kcal derivation.
    "energy-kj_100g",
    "proteins_100g",
    "carbohydrates_100g",
    "fat_100g",
    "fiber_100g",
    "sugars_100g",
    "sodium_100g",
    "saturated-fat_100g",
    // 1.6: obsolete / states_tags drop predicate.
    "states_tags",
    "obsolete",
    // 1.7: no-nutrition-data flag.
    "no_nutrition_data",
];

pub struct ParquetSource {
    stream: ParquetRecordBatchStream<File>,
    buffer: std::collections::VecDeque<OffFoodRecord>,
    path: PathBuf,
}

impl ParquetSource {
    pub async fn open<P: AsRef<Path>>(path: P) -> anyhow::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let file = File::open(&path).await?;
        let builder =
            ParquetRecordBatchStreamBuilder::new_with_options(file, ArrowReaderOptions::new())
                .await?;

        // Build a projection mask of the columns we recognize. Names that
        // don't exist in this file are silently omitted.
        let arrow_schema: SchemaRef = builder.schema().clone();
        let projected_indices: Vec<usize> = PROJECTED_COLUMNS
            .iter()
            .filter_map(|name| arrow_schema.index_of(name).ok())
            .collect();

        let mask = ProjectionMask::roots(builder.parquet_schema(), projected_indices);
        let builder = builder.with_projection(mask).with_batch_size(2048);
        let stream = builder.build()?;

        let _ = arrow_schema; // schema used only to compute the projection
        Ok(Self {
            stream,
            buffer: std::collections::VecDeque::new(),
            path,
        })
    }

    /// Pull the next `RecordBatch` from the underlying stream and decode
    /// it into the internal buffer. Returns `Ok(false)` when the stream
    /// is exhausted.
    async fn pump_one_batch(&mut self) -> CoreResult<bool> {
        let Some(next) = self.stream.next().await else {
            return Ok(false);
        };
        let batch = next.map_err(|e| {
            loseit_core::CoreError::internal(format!("parquet read {:?}: {e}", self.path))
        })?;
        let rows = decode_batch(&batch).map_err(|e| {
            loseit_core::CoreError::internal(format!("parquet decode {:?}: {e}", self.path))
        })?;
        self.buffer.extend(rows);
        Ok(true)
    }
}

#[async_trait]
impl FoodRecordSource for ParquetSource {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<OffFoodRecord>>> {
        // Top up the buffer until we have `n` records or the stream is
        // drained. We may overshoot `n` (the parquet batch size is fixed)
        // and that's fine — the leftover stays in `self.buffer` for the
        // next call.
        while self.buffer.len() < n {
            let progressed = self.pump_one_batch().await?;
            if !progressed {
                break;
            }
        }

        if self.buffer.is_empty() {
            return Ok(None);
        }

        let take = n.min(self.buffer.len());
        let mut out: Vec<OffFoodRecord> = Vec::with_capacity(take);
        for _ in 0..take {
            if let Some(r) = self.buffer.pop_front() {
                out.push(r);
            }
        }
        Ok(Some(out))
    }
}

/// Decode an Arrow `RecordBatch` into a vec of `OffFoodRecord`s by
/// looking up each projected column by name. Missing columns produce
/// `None` for their field.
fn decode_batch(batch: &arrow::record_batch::RecordBatch) -> Result<Vec<OffFoodRecord>, String> {
    let n = batch.num_rows();
    let mut out: Vec<OffFoodRecord> = (0..n).map(|_| OffFoodRecord::default()).collect();
    let schema = batch.schema();

    // Each column we recognize updates the corresponding field on every
    // row. Columns we don't recognize are ignored.
    for (idx, field) in schema.fields().iter().enumerate() {
        let col = batch.column(idx);
        match field.name().as_str() {
            "code" => {
                decode_string_into(col, |i, v| out[i].code = v.unwrap_or_default().to_string())
            }
            "product_name" => decode_string_into(col, |i, v| {
                out[i].product_name = v.unwrap_or_default().to_string()
            }),
            "brands" => decode_string_into(col, |i, v| {
                out[i].brands = v.map(|s| s.to_string());
            }),
            "categories_tags" => decode_categories(col, &mut out),
            "nutriscore_grade" => decode_string_into(col, |i, v| {
                out[i].nutriscore_grade = v.map(|s| s.to_string());
            }),
            "completeness" => decode_f64_into(col, |i, v| {
                out[i].completeness = v;
            }),
            "serving_size" => decode_string_into(col, |i, v| {
                out[i].serving_size = v.map(|s| s.to_string());
            }),
            "serving_quantity" => decode_quantity(col, &mut out),
            "energy-kcal_100g" => decode_decimal_into(col, |i, v| out[i].energy_kcal_100g = v),
            "energy-kj_100g" => decode_decimal_into(col, |i, v| out[i].energy_kj_100g = v),
            "proteins_100g" => decode_decimal_into(col, |i, v| out[i].protein_100g = v),
            "carbohydrates_100g" => decode_decimal_into(col, |i, v| out[i].carbs_100g = v),
            "fat_100g" => decode_decimal_into(col, |i, v| out[i].fat_100g = v),
            "fiber_100g" => decode_decimal_into(col, |i, v| out[i].fiber_100g = v),
            "sugars_100g" => decode_decimal_into(col, |i, v| out[i].sugar_100g = v),
            "sodium_100g" => decode_decimal_into(col, |i, v| out[i].sodium_100g = v),
            "saturated-fat_100g" => decode_decimal_into(col, |i, v| out[i].saturated_fat_100g = v),
            "states_tags" => decode_states_tags(col, &mut out),
            "obsolete" => decode_bool_into(col, |i, v| out[i].obsolete = v),
            "no_nutrition_data" => decode_string_into(col, |i, v| {
                out[i].no_nutrition_data = v.map(|s| s.to_string());
            }),
            _ => {}
        }
    }
    Ok(out)
}

fn decode_string_into<F: FnMut(usize, Option<&str>)>(col: &Arc<dyn Array>, mut f: F) {
    if let Some(arr) = col.as_any().downcast_ref::<StringArray>() {
        for i in 0..arr.len() {
            f(
                i,
                if arr.is_null(i) {
                    None
                } else {
                    Some(arr.value(i))
                },
            );
        }
    } else if let Some(arr) = col.as_any().downcast_ref::<LargeStringArray>() {
        for i in 0..arr.len() {
            f(
                i,
                if arr.is_null(i) {
                    None
                } else {
                    Some(arr.value(i))
                },
            );
        }
    }
}

fn decode_f64_into<F: FnMut(usize, Option<f64>)>(col: &Arc<dyn Array>, mut f: F) {
    if let Some(arr) = col.as_any().downcast_ref::<Float64Array>() {
        for i in 0..arr.len() {
            f(
                i,
                if arr.is_null(i) {
                    None
                } else {
                    Some(arr.value(i))
                },
            );
        }
    } else if let Some(arr) = col.as_any().downcast_ref::<Float32Array>() {
        for i in 0..arr.len() {
            f(
                i,
                if arr.is_null(i) {
                    None
                } else {
                    Some(arr.value(i) as f64)
                },
            );
        }
    } else if let Some(arr) = col.as_any().downcast_ref::<Int64Array>() {
        for i in 0..arr.len() {
            f(
                i,
                if arr.is_null(i) {
                    None
                } else {
                    Some(arr.value(i) as f64)
                },
            );
        }
    } else if let Some(arr) = col.as_any().downcast_ref::<Int32Array>() {
        for i in 0..arr.len() {
            f(
                i,
                if arr.is_null(i) {
                    None
                } else {
                    Some(arr.value(i) as f64)
                },
            );
        }
    }
}

fn decode_decimal_into<F: FnMut(usize, Option<Decimal>)>(col: &Arc<dyn Array>, mut f: F) {
    decode_f64_into(col, |i, v| {
        let dec = v.and_then(|n| {
            if n.is_finite() {
                Decimal::try_from(n).ok()
            } else {
                None
            }
        });
        f(i, dec);
    });
}

fn decode_quantity(col: &Arc<dyn Array>, out: &mut [OffFoodRecord]) {
    match col.data_type() {
        DataType::Utf8 | DataType::LargeUtf8 => {
            decode_string_into(col, |i, v| {
                if let Some(s) = v {
                    let trimmed = s.trim();
                    if !trimmed.is_empty() {
                        if let Ok(d) = Decimal::from_str(trimmed) {
                            out[i].serving_quantity = Some(d);
                        }
                    }
                }
            });
        }
        _ => {
            decode_decimal_into(col, |i, v| out[i].serving_quantity = v);
        }
    }
}

fn decode_bool_into<F: FnMut(usize, Option<bool>)>(col: &Arc<dyn Array>, mut f: F) {
    if let Some(arr) = col.as_any().downcast_ref::<BooleanArray>() {
        for i in 0..arr.len() {
            f(
                i,
                if arr.is_null(i) {
                    None
                } else {
                    Some(arr.value(i))
                },
            );
        }
    }
}

/// 1.6: states_tags is a `List<String>` in modern OFF parquet exports;
/// fall back to comma-separated plain string for older builds (same shape
/// as `decode_categories`).
fn decode_states_tags(col: &Arc<dyn Array>, out: &mut [OffFoodRecord]) {
    if let Some(list) = col.as_any().downcast_ref::<ListArray>() {
        let n = list.len().min(out.len());
        for (i, row) in out.iter_mut().enumerate().take(n) {
            if list.is_null(i) {
                continue;
            }
            let values = list.value(i);
            let mut tags: Vec<String> = Vec::new();
            if let Some(s) = values.as_any().downcast_ref::<StringArray>() {
                for j in 0..s.len() {
                    if !s.is_null(j) {
                        tags.push(s.value(j).to_string());
                    }
                }
            } else if let Some(s) = values.as_any().downcast_ref::<LargeStringArray>() {
                for j in 0..s.len() {
                    if !s.is_null(j) {
                        tags.push(s.value(j).to_string());
                    }
                }
            }
            row.states_tags = tags;
        }
    } else if matches!(col.data_type(), DataType::Utf8 | DataType::LargeUtf8) {
        decode_string_into(col, |i, v| {
            if let Some(s) = v {
                let tags: Vec<String> = s
                    .split(['|', ','])
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                    .collect();
                out[i].states_tags = tags;
            }
        });
    }
}

/// Categories tags can be a `List<String>` (canonical Arrow shape) or a
/// pipe-separated plain string in older OFF parquet builds. Handle both.
fn decode_categories(col: &Arc<dyn Array>, out: &mut [OffFoodRecord]) {
    if let Some(list) = col.as_any().downcast_ref::<ListArray>() {
        let n = list.len().min(out.len());
        for (i, row) in out.iter_mut().enumerate().take(n) {
            if list.is_null(i) {
                continue;
            }
            let values = list.value(i);
            let mut tags: Vec<String> = Vec::new();
            if let Some(s) = values.as_any().downcast_ref::<StringArray>() {
                for j in 0..s.len() {
                    if !s.is_null(j) {
                        tags.push(s.value(j).to_string());
                    }
                }
            } else if let Some(s) = values.as_any().downcast_ref::<LargeStringArray>() {
                for j in 0..s.len() {
                    if !s.is_null(j) {
                        tags.push(s.value(j).to_string());
                    }
                }
            }
            row.categories_tags = tags;
        }
    } else if matches!(col.data_type(), DataType::Utf8 | DataType::LargeUtf8) {
        // Fallback: pipe- or comma-separated string.
        decode_string_into(col, |i, v| {
            if let Some(s) = v {
                let tags: Vec<String> = s
                    .split(['|', ','])
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                    .collect();
                out[i].categories_tags = tags;
            }
        });
    }
}
