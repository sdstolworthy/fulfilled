use std::env;
use std::net::SocketAddr;

use anyhow::{anyhow, Context, Result};

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub bind: SocketAddr,
    pub database_url: String,
    pub run_migrations: bool,
    pub auth: AuthConfig,
    pub env_name: String,
}

#[derive(Debug, Clone)]
pub enum AuthConfig {
    /// Static-bearer-token bypass for local development. The token maps
    /// to a single configured identity. Never enabled in production.
    DevBypass {
        token: String,
        issuer: String,
        external_id: String,
        email: Option<String>,
        display_name: Option<String>,
    },
    /// Validate JWTs against an OIDC issuer's JWKS endpoint. Not wired up
    /// in this initial pass — kept as a placeholder so the composition
    /// root can dispatch on it once we add the JWKS validator.
    Jwks { issuer: String, jwks_url: String },
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let bind: SocketAddr = env::var("LOSEIT_BIND")
            .unwrap_or_else(|_| "0.0.0.0:8080".to_string())
            .parse()
            .context("LOSEIT_BIND must be a host:port")?;

        let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;

        let run_migrations = env_bool("LOSEIT_RUN_MIGRATIONS", true);
        let env_name = env::var("RUST_ENV").unwrap_or_else(|_| "development".to_string());

        let auth = load_auth(&env_name)?;

        Ok(Self {
            bind,
            database_url,
            run_migrations,
            auth,
            env_name,
        })
    }
}

fn load_auth(env_name: &str) -> Result<AuthConfig> {
    if env_bool("DEV_AUTH_BYPASS", false) {
        if env_name == "production" {
            return Err(anyhow!(
                "refusing to start: DEV_AUTH_BYPASS is set with RUST_ENV=production"
            ));
        }
        return Ok(AuthConfig::DevBypass {
            token: env::var("DEV_AUTH_TOKEN").unwrap_or_else(|_| "dev-token".to_string()),
            issuer: env::var("DEV_AUTH_ISSUER").unwrap_or_else(|_| "dev".to_string()),
            external_id: env::var("DEV_AUTH_USER_ID").unwrap_or_else(|_| "dev-user".to_string()),
            email: env::var("DEV_AUTH_EMAIL").ok(),
            display_name: env::var("DEV_AUTH_DISPLAY_NAME").ok(),
        });
    }

    let issuer =
        env::var("OIDC_ISSUER").context("OIDC_ISSUER is required when DEV_AUTH_BYPASS is off")?;
    let jwks_url = env::var("OIDC_JWKS_URL")
        .context("OIDC_JWKS_URL is required when DEV_AUTH_BYPASS is off")?;
    Ok(AuthConfig::Jwks { issuer, jwks_url })
}

fn env_bool(key: &str, default: bool) -> bool {
    env::var(key)
        .ok()
        .map(|v| matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(default)
}
