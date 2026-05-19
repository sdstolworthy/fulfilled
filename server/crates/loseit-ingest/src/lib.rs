//! Source adapters for the OpenFoodFacts and USDA bulk-import pipelines.
//!
//! OFF sources (both implementing [`loseit_core::service::FoodRecordSource`]):
//!
//! * [`JsonlSource`] — newline-delimited JSON file (one product per line),
//!   the canonical OFF "products.jsonl" format.
//! * [`ParquetSource`] — the OFF Parquet dump
//!   (`openfoodfacts-products.parquet`). Gated behind the `parquet`
//!   feature so a developer can build without the heavy `arrow` +
//!   `parquet` stack if they only care about JSONL.
//!
//! USDA source (implementing [`loseit_core::service::UsdaSource`]):
//!
//! * [`UsdaJsonlSource`] — newline-delimited JSON, one USDA food object per
//!   line (pre-split from the FDC bulk export).
//!
//! Both source families expose a `LimitedSource` / `LimitedUsdaSource`
//! wrapper that stops returning records after a fixed count (used by the
//! binary's `--limit` flag for smoke tests).

use std::path::Path;

use async_trait::async_trait;
use loseit_core::service::{FoodRecordSource, OffFoodRecord, UsdaFoodRecord, UsdaSource};
use loseit_core::CoreResult;

pub mod jsonl;
#[cfg(feature = "parquet")]
pub mod parquet_source;
pub mod usda_jsonl;

pub use jsonl::JsonlSource;
#[cfg(feature = "parquet")]
pub use parquet_source::ParquetSource;
pub use usda_jsonl::UsdaJsonlSource;

/// Convenience constructor that opens an OFF source from a path string and a
/// format name (`"jsonl"` or `"parquet"`).
pub async fn open_source(kind: &str, path: &Path) -> anyhow::Result<Box<dyn FoodRecordSource>> {
    match kind {
        "jsonl" => Ok(Box::new(JsonlSource::open(path).await?)),
        #[cfg(feature = "parquet")]
        "parquet" => Ok(Box::new(ParquetSource::open(path).await?)),
        #[cfg(not(feature = "parquet"))]
        "parquet" => Err(anyhow::anyhow!(
            "this build was compiled without the `parquet` feature"
        )),
        other => Err(anyhow::anyhow!(
            "unknown OFF source format `{}`; expected `jsonl` or `parquet`",
            other
        )),
    }
}

/// Convenience constructor that opens a USDA source from a path string and a
/// format name (currently only `"jsonl"` is supported).
pub async fn open_usda_source(kind: &str, path: &Path) -> anyhow::Result<Box<dyn UsdaSource>> {
    match kind {
        "jsonl" => Ok(Box::new(UsdaJsonlSource::open(path).await?)),
        other => Err(anyhow::anyhow!(
            "unknown USDA source format `{}`; expected `jsonl`",
            other
        )),
    }
}

/// Decorator that caps the total number of OFF records produced by an inner
/// source. Used by the binary's `--limit` flag.
pub struct LimitedSource {
    inner: Box<dyn FoodRecordSource>,
    remaining: usize,
}

impl LimitedSource {
    pub fn new(inner: Box<dyn FoodRecordSource>, limit: usize) -> Self {
        Self {
            inner,
            remaining: limit,
        }
    }
}

#[async_trait]
impl FoodRecordSource for LimitedSource {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<OffFoodRecord>>> {
        if self.remaining == 0 {
            return Ok(None);
        }
        let take = n.min(self.remaining);
        let chunk = self.inner.next_chunk(take).await?;
        match chunk {
            Some(mut v) => {
                if v.len() > self.remaining {
                    v.truncate(self.remaining);
                }
                self.remaining -= v.len();
                Ok(Some(v))
            }
            None => Ok(None),
        }
    }
}

/// Decorator that caps the total number of USDA records produced by an inner
/// source. Used by the binary's `--limit` flag.
pub struct LimitedUsdaSource {
    inner: Box<dyn UsdaSource>,
    remaining: usize,
}

impl LimitedUsdaSource {
    pub fn new(inner: Box<dyn UsdaSource>, limit: usize) -> Self {
        Self {
            inner,
            remaining: limit,
        }
    }
}

#[async_trait]
impl UsdaSource for LimitedUsdaSource {
    async fn next_chunk(&mut self, n: usize) -> CoreResult<Option<Vec<UsdaFoodRecord>>> {
        if self.remaining == 0 {
            return Ok(None);
        }
        let take = n.min(self.remaining);
        let chunk = self.inner.next_chunk(take).await?;
        match chunk {
            Some(mut v) => {
                if v.len() > self.remaining {
                    v.truncate(self.remaining);
                }
                self.remaining -= v.len();
                Ok(Some(v))
            }
            None => Ok(None),
        }
    }
}
