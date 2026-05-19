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

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::Parser;
use loseit_core::service::{FoodRecordSource, IngestService, UsdaSource};
use loseit_db::{build_pool, run_migrations, PgBatchRepository, PgFoodRepository, PoolConfig};
use loseit_ingest::{open_source, open_usda_source, LimitedSource, LimitedUsdaSource};
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
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();
    let args = Args::parse();

    info!(
        source = %args.source,
        format = %args.format,
        input = %args.input.display(),
        limit = ?args.limit,
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

    let source_url = args.input.display().to_string();

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
            run_off(&service, BoxedOffSource(source), &source_url).await?
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
            run_usda(&service, BoxedUsdaSource(source), &source_url).await?
        }
        other => {
            anyhow::bail!("unknown --source `{}`; expected `off` or `usda`", other);
        }
    };

    info!(
        inserted = stats.inserted,
        updated = stats.updated,
        skipped = stats.skipped,
        "ingest complete"
    );
    Ok(())
}

// ---------------------------------------------------------------------------
// run_off / run_usda pipeline helpers  (§7.4)
// ---------------------------------------------------------------------------

/// §7.4: Pull `OffFoodRecord`s from `source`, normalize each via
/// `accept_and_normalize_off`, and upsert the resulting
/// `FoodDraftWithServings` batch via `repo.upsert_external_food_batch`.
async fn run_off<S: FoodRecordSource>(
    service: &IngestService,
    source: S,
    source_url: &str,
) -> Result<loseit_core::repo::UpsertStats> {
    service
        .run_off(source, source_url, None)
        .await
        .context("OFF ingest run failed")
}

/// §7.4: Pull `UsdaFoodRecord`s from `source`, normalize each via
/// `accept_and_normalize_usda`, and upsert the resulting
/// `FoodDraftWithServings` batch via `repo.upsert_external_food_batch`.
async fn run_usda<S: UsdaSource>(
    service: &IngestService,
    source: S,
    source_url: &str,
) -> Result<loseit_core::repo::UpsertStats> {
    service
        .run_usda(source, source_url, None)
        .await
        .context("USDA ingest run failed")
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
