//! Source adapters for the OpenFoodFacts bulk-import pipeline.
//!
//! Two sources are exposed, both implementing
//! [`loseit_core::service::FoodRecordSource`]:
//!
//! * [`JsonlSource`] — newline-delimited JSON file (one product per line),
//!   the canonical OFF "products.jsonl" format.
//! * [`ParquetSource`] — the OFF Parquet dump
//!   (`openfoodfacts-products.parquet`). Gated behind the `parquet`
//!   feature so a developer can build without the heavy `arrow` +
//!   `parquet` stack if they only care about JSONL.
//!
//! Both sources expose a `LimitedSource` wrapper that stops returning
//! records after a fixed count (used by the binary's `--limit` flag for
//! smoke tests).

use std::path::Path;

use async_trait::async_trait;
use loseit_core::service::{FoodRecordSource, OffFoodRecord};
use loseit_core::CoreResult;

pub mod jsonl;
#[cfg(feature = "parquet")]
pub mod parquet_source;

pub use jsonl::JsonlSource;
#[cfg(feature = "parquet")]
pub use parquet_source::ParquetSource;

/// Convenience constructor that opens a source from a path string and a
/// source name (`"jsonl"` or `"parquet"`).
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
            "unknown source kind `{}`; expected `jsonl` or `parquet`",
            other
        )),
    }
}

/// Decorator that caps the total number of records produced by an inner
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
