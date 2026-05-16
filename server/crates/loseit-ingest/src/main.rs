//! OpenFoodFacts bulk-import binary.
//!
//! Reads a local OFF dump (JSONL or Parquet), normalizes each product,
//! upserts into the `foods` + `servings` tables in 500-row chunks, and
//! records progress in the `food_import_batches` table.
//!
//! Postgres must be reachable via `DATABASE_URL` (or `--database-url`).
//! No network fetch is performed — provide the file via `--input`.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::Parser;
use loseit_core::service::{FoodRecordSource, IngestService};
use loseit_db::{
    build_pool, run_migrations, PgBatchRepository, PgFoodRepository, PgServingRepository,
    PoolConfig,
};
use loseit_ingest::{open_source, LimitedSource};
use tracing::info;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(
    name = "loseit-ingest",
    about = "Bulk-import OFF products into the loseit DB"
)]
struct Args {
    /// Source format. `jsonl` is always available; `parquet` is
    /// available when the binary is built with `--features parquet`
    /// (the default).
    #[arg(long, default_value = "jsonl")]
    source: String,

    /// Path to the OFF dump file.
    #[arg(long)]
    input: PathBuf,

    /// Postgres connection URL. Defaults to `$DATABASE_URL`.
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,

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
        input = %args.input.display(),
        limit = ?args.limit,
        "starting loseit-ingest"
    );

    let pool_config = PoolConfig {
        url: args.database_url.clone(),
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
    let servings = Arc::new(PgServingRepository::new(pool.clone()));
    let batches = Arc::new(PgBatchRepository::new(pool));

    let service = IngestService::new(foods, servings, batches);

    let source = open_source(&args.source, &args.input)
        .await
        .with_context(|| format!("opening source `{}` at {:?}", args.source, args.input))?;
    let source: Box<dyn FoodRecordSource> = match args.limit {
        Some(n) => Box::new(LimitedSource::new(source, n)),
        None => source,
    };

    let source_url = args.input.display().to_string();
    let stats = service
        .run(BoxedSource(source), &source_url, None)
        .await
        .context("ingest run failed")?;

    info!(
        inserted = stats.inserted,
        updated = stats.updated,
        skipped = stats.skipped,
        "ingest complete"
    );
    Ok(())
}

/// `IngestService::run` takes `S: FoodRecordSource` by value; the
/// `Box<dyn ...>` we build at the CLI layer doesn't satisfy `Sized`
/// generic bounds directly, so we wrap it in a tiny newtype that
/// re-implements the trait by delegating.
struct BoxedSource(Box<dyn FoodRecordSource>);

#[async_trait::async_trait]
impl FoodRecordSource for BoxedSource {
    async fn next_chunk(
        &mut self,
        n: usize,
    ) -> loseit_core::CoreResult<Option<Vec<loseit_core::service::OffFoodRecord>>> {
        self.0.next_chunk(n).await
    }
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,loseit_ingest=info,loseit_core=info,sqlx=warn"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}
