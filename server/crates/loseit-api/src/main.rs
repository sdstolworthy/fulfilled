use std::time::Duration;

use anyhow::{Context, Result};
use loseit_api::build_router;
use loseit_api::config::AppConfig;
use loseit_db::{build_pool, run_migrations, PoolConfig};
use tokio::net::TcpListener;
use tracing::info;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();

    let config = AppConfig::from_env().context("loading config from environment")?;
    info!(env = %config.env_name, bind = %config.bind, "starting loseit-api");

    let pool_config = PoolConfig {
        url: config.database_url.clone(),
        max_connections: 10,
        acquire_timeout: Duration::from_secs(5),
    };
    let pool = build_pool(&pool_config)
        .await
        .context("connecting to postgres")?;

    if config.run_migrations {
        info!("running migrations");
        run_migrations(&pool).await.context("running migrations")?;
    }

    let router = build_router(pool, &config)?;
    let listener = TcpListener::bind(config.bind)
        .await
        .with_context(|| format!("binding to {}", config.bind))?;

    info!("listening");
    axum::serve(listener, router).await.context("serving")?;
    Ok(())
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,tower_http=info,sqlx=warn"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}
