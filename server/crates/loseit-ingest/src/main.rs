//! OpenFoodFacts / USDA FoodData Central bulk-import binary.
//!
//! Reads a local dump file, normalizes each product, upserts into the
//! `foods` + `servings` tables in 500-row chunks, and records progress in
//! the `food_import_batches` table.
//!
//! # CLI
//!
//! ```text
//! loseit-ingest --source off  --format jsonl   --input off-products.jsonl [--limit N]
//! loseit-ingest --source off  --format parquet --input off-products.parquet
//! loseit-ingest --source usda --format jsonl   --input fdc-foods.jsonl
//! ```
//!
//! `DATABASE_URL` (or `--database-url`) must point to a reachable Postgres
//! instance unless you only pass `--help` (which exits before any DB work).
//!
//! No network fetch is performed — provide the file via `--input`.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::Parser;
use loseit_core::service::{FoodRecordSource, IngestService, RunOptions, UsdaSource};
use loseit_db::{build_pool, run_migrations, PgBatchRepository, PgFoodRepository, PoolConfig};
use loseit_ingest::{open_source, open_usda_source, LimitedSource, LimitedUsdaSource};
use sha2::{Digest, Sha256};
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(
    name = "loseit-ingest",
    about = "Bulk-import OFF or USDA FDC products into the loseit DB"
)]
struct Args {
    /// Data source. `off` = OpenFoodFacts; `usda` = USDA FoodData Central.
    #[arg(long, default_value = "off")]
    source: String,

    /// File format within the chosen source. OFF supports `jsonl` and
    /// `parquet`; USDA supports `jsonl` only.
    #[arg(long, default_value = "jsonl")]
    format: String,

    /// Path to the dump file.
    #[arg(long)]
    input: PathBuf,

    /// Postgres connection URL. Defaults to `$DATABASE_URL`.
    #[arg(long, env = "DATABASE_URL")]
    database_url: Option<String>,

    /// Skip running migrations on startup (assumes the DB schema is
    /// already at HEAD).
    #[arg(long)]
    skip_migrations: bool,

    /// Cap the number of records processed. Useful for smoke runs.
    #[arg(long)]
    limit: Option<usize>,

    /// 2.1: bypass the etag short-circuit. By default the pipeline skips a
    /// rerun when a `status='completed'` batch already covers the same
    /// `(source_url, source_etag)` pair — useful so accidentally running
    /// the same dump twice is a no-op. Pass `--force` to redo a botched
    /// import without re-downloading.
    #[arg(long)]
    force: bool,

    /// Override the `source-url` stored on the `food_import_batches`
    /// provenance row. Defaults to the resolved input path. Useful when
    /// running from a local copy of a remote dump — set this to the
    /// canonical URL so the etag short-circuit matches future reruns.
    #[arg(long)]
    source_url: Option<String>,

    /// 4.4: drop OFF rows whose `last_modified_t` is older than this
    /// many years. `0` (the default) disables the drop — we ingest
    /// everything and let the OFF moderation flags
    /// (`states_tags = en:to-be-deleted`, `obsolete = true`,
    /// `data_quality_errors_tags`) do the real quality filtering.
    /// `last_modified_t` is "when did anyone last edit anything",
    /// which can be a trivial photo or translation fix — not a
    /// reliable proxy for nutrition staleness. Operators can opt
    /// into a cutoff (e.g. `--stale-after-years 15`) for stricter
    /// imports. USDA rows are unaffected — FDC dumps don't carry a
    /// per-row last-modified field.
    #[arg(long, default_value_t = 0)]
    stale_after_years: u32,
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();
    let args = Args::parse();

    // 2.1: stream the input file once, computing a SHA-256 digest + file
    // size. The pair lands on `food_import_batches.source_etag` as
    // `sha256:<hex>;size:<bytes>` so future reruns of the same dump are a
    // no-op via the etag short-circuit. Streamed read (8 KiB buffer) so
    // multi-GB dumps don't blow up memory.
    let (file_sha256, file_size) = hash_input_file(&args.input)
        .with_context(|| format!("computing SHA-256 of {:?}", args.input))?;
    let source_etag = format!("sha256:{file_sha256};size:{file_size}");

    let source_url = args
        .source_url
        .clone()
        .unwrap_or_else(|| args.input.display().to_string());

    info!(
        source = %args.source,
        format = %args.format,
        input = %args.input.display(),
        source_url = %source_url,
        etag = %source_etag,
        limit = ?args.limit,
        force = args.force,
        stale_after_years = args.stale_after_years,
        "starting loseit-ingest"
    );

    let database_url = args
        .database_url
        .clone()
        .context("--database-url or DATABASE_URL must be set")?;

    let pool_config = PoolConfig {
        url: database_url,
        max_connections: 8,
        acquire_timeout: Duration::from_secs(10),
    };
    let pool = build_pool(&pool_config)
        .await
        .context("connecting to postgres")?;

    if !args.skip_migrations {
        info!("running migrations");
        run_migrations(&pool).await.context("running migrations")?;
    }

    let foods = Arc::new(PgFoodRepository::new(pool.clone()));
    let batches = Arc::new(PgBatchRepository::new(pool));

    let service = IngestService::new(foods, batches);
    let run_options = RunOptions {
        force: args.force,
        stale_after_years: args.stale_after_years,
    };

    let stats = match args.source.as_str() {
        "off" => {
            let source = open_source(&args.format, &args.input)
                .await
                .with_context(|| {
                    format!(
                        "opening OFF source (format={}) at {:?}",
                        args.format, args.input
                    )
                })?;
            let source: Box<dyn FoodRecordSource> = match args.limit {
                Some(n) => Box::new(LimitedSource::new(source, n)),
                None => source,
            };
            service
                .run_off_with_options(
                    BoxedOffSource(source),
                    &source_url,
                    Some(&source_etag),
                    run_options,
                )
                .await
                .context("OFF ingest run failed")?
        }
        "usda" => {
            let source = open_usda_source(&args.format, &args.input)
                .await
                .with_context(|| {
                    format!(
                        "opening USDA source (format={}) at {:?}",
                        args.format, args.input
                    )
                })?;
            let source: Box<dyn UsdaSource> = match args.limit {
                Some(n) => Box::new(LimitedUsdaSource::new(source, n)),
                None => source,
            };
            service
                .run_usda_with_options(
                    BoxedUsdaSource(source),
                    &source_url,
                    Some(&source_etag),
                    run_options,
                )
                .await
                .context("USDA ingest run failed")?
        }
        other => {
            anyhow::bail!("unknown --source `{}`; expected `off` or `usda`", other);
        }
    };

    info!(
        inserted = stats.inserted,
        merged = stats.updated,
        skipped = stats.skipped,
        "ingest complete"
    );
    Ok(())
}

/// 2.1: streamed SHA-256 over the input file. Returns `(hex_digest,
/// size_bytes)`. The 8 KiB chunk size keeps memory bounded for multi-GB
/// OFF parquet dumps.
fn hash_input_file(path: &Path) -> Result<(String, u64)> {
    let file = File::open(path).with_context(|| format!("opening {path:?}"))?;
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = reader.read(&mut buf).context("reading input file")?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let digest = hasher.finalize();
    Ok((hex_encode(&digest), size))
}

/// Lowercase hex without pulling in a `hex` crate dependency.
fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0f) as usize] as char);
    }
    out
}

// ---------------------------------------------------------------------------
// Boxed source newtypes
// ---------------------------------------------------------------------------

/// `IngestService::run_off` takes `S: FoodRecordSource` by value; the
/// `Box<dyn ...>` we build at the CLI layer doesn't satisfy `Sized`
/// generic bounds directly, so we wrap it in a tiny newtype that
/// re-implements the trait by delegating.
struct BoxedOffSource(Box<dyn FoodRecordSource>);

#[async_trait::async_trait]
impl FoodRecordSource for BoxedOffSource {
    async fn next_chunk(
        &mut self,
        n: usize,
    ) -> loseit_core::CoreResult<Option<Vec<loseit_core::service::OffFoodRecord>>> {
        self.0.next_chunk(n).await
    }
}

/// Boxed USDA source newtype — same rationale as `BoxedOffSource`.
struct BoxedUsdaSource(Box<dyn UsdaSource>);

#[async_trait::async_trait]
impl UsdaSource for BoxedUsdaSource {
    async fn next_chunk(
        &mut self,
        n: usize,
    ) -> loseit_core::CoreResult<Option<Vec<loseit_core::service::UsdaFoodRecord>>> {
        self.0.next_chunk(n).await
    }
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,loseit_ingest=info,loseit_core=info,sqlx=warn"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}
