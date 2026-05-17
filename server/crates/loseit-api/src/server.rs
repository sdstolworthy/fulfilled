//! Composition root.
//!
//! This file is the *only* place that knows what concrete repository,
//! authenticator, and service types we use. Everything downstream — the
//! services, handlers, middleware — receives its dependencies through
//! traits or through [`AppState`].
//!
//! The composition is split into two seams:
//!
//! * [`build_state`] turns a Postgres pool and config into a fully wired
//!   [`AppState`]. Production uses this.
//! * [`router`] takes any [`AppState`] and returns the axum router. Tests
//!   call this directly with a state built from in-memory fakes.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use axum::middleware;
use axum::Router;
use loseit_core::auth::Authenticator;
use loseit_core::domain::UserIdentity;
use loseit_core::repo::{
    FoodRepository, GoalRepository, LocalAuthRepository, LogRepository, OidcHandoffRepository,
    ServingRepository, UserRepository, WeightRepository,
};
use loseit_core::service::{
    AuthService, FoodService, GoalService, LogService, ServingService, UserService, WeightService,
};
use loseit_db::{
    PgFoodRepository, PgGoalRepository, PgLocalAuthRepository, PgLogRepository,
    PgOidcHandoffRepository, PgPool, PgServingRepository, PgUserRepository, PgWeightRepository,
};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use crate::auth::{
    dev::DevAuthenticator, local::LocalAuthenticator, require_auth, DynAuthenticator,
};
use crate::auth::jwks::JwksVerifier;
use crate::auth::oidc::state::StateSigner;
use crate::config::{AppConfig, AuthConfig};
use crate::routes;

// ── OIDC composition types ────────────────────────────────────────────────────

/// A single OIDC provider's runtime state: its parsed config, a warmed
/// JWKS verifier, and a per-provider HTTP client.
pub struct OidcProvider {
    pub config: crate::config::OidcProviderConfig,
    pub jwks: Arc<JwksVerifier>,
    pub http: reqwest::Client,
}

/// Everything the OIDC route handlers need, assembled at boot time.
pub struct OidcRegistry {
    pub providers: HashMap<String, Arc<OidcProvider>>,
    pub state_signer: Arc<StateSigner>,
    pub fe_origin: String,
    pub handoffs: Arc<dyn OidcHandoffRepository>,
    pub auth: Arc<AuthService>,
}

// ── AppState ──────────────────────────────────────────────────────────────────

/// Application state handed to every axum handler. Holds services as
/// `Arc`s so handlers can clone freely and concurrent requests share one
/// underlying instance.
#[derive(Clone)]
pub struct AppState {
    pub users: Arc<UserService>,
    pub weights: Arc<WeightService>,
    pub goals: Arc<GoalService>,
    pub foods: Arc<FoodService>,
    pub servings: Arc<ServingService>,
    pub logs: Arc<LogService>,
    pub authenticator: DynAuthenticator,
    pub auth: Option<Arc<AuthService>>,
    /// `Some` when at least one OIDC provider is configured.
    pub oidc: Option<Arc<OidcRegistry>>,
    /// `true` when the local-creds login path is enabled.
    pub local_login_enabled: bool,
}

impl AppState {
    /// Assemble an [`AppState`] from already-built ports. Tests use this
    /// directly with in-memory fakes; [`build_state`] wraps it for the
    /// production wiring path.
    #[allow(clippy::too_many_arguments)]
    pub fn from_ports(
        users: Arc<dyn UserRepository>,
        weights: Arc<dyn WeightRepository>,
        goals: Arc<dyn GoalRepository>,
        foods: Arc<dyn FoodRepository>,
        servings: Arc<dyn ServingRepository>,
        logs: Arc<dyn LogRepository>,
        authenticator: DynAuthenticator,
        auth_service: Option<Arc<AuthService>>,
        oidc: Option<Arc<OidcRegistry>>,
        local_login_enabled: bool,
    ) -> Self {
        let user_service = Arc::new(UserService::new(users));
        let weight_service = Arc::new(WeightService::new(weights));
        let goal_service = Arc::new(GoalService::new(goals.clone()));
        let food_service = Arc::new(FoodService::new(foods.clone(), servings.clone()));
        let serving_service = Arc::new(ServingService::new(servings.clone(), foods.clone()));
        let log_service = Arc::new(LogService::new(logs, foods, servings, goals));
        Self {
            users: user_service,
            weights: weight_service,
            goals: goal_service,
            foods: food_service,
            servings: serving_service,
            logs: log_service,
            authenticator,
            auth: auth_service,
            oidc,
            local_login_enabled,
        }
    }
}

// ── build_state ───────────────────────────────────────────────────────────────

/// Production wiring: Postgres repositories + the authenticator selected
/// from config, plus the full OIDC registry when providers are configured.
///
/// Async because per-provider JwksVerifiers warm their caches via an
/// initial HTTP fetch at construction. Failing that fetch means the
/// configured idP is unreachable; we'd rather refuse to start than 503
/// every request.
pub async fn build_state(pool: PgPool, config: &AppConfig) -> Result<AppState> {
    let users: Arc<dyn UserRepository> = Arc::new(PgUserRepository::new(pool.clone()));
    let weights: Arc<dyn WeightRepository> = Arc::new(PgWeightRepository::new(pool.clone()));
    let goals: Arc<dyn GoalRepository> = Arc::new(PgGoalRepository::new(pool.clone()));
    let foods: Arc<dyn FoodRepository> = Arc::new(PgFoodRepository::new(pool.clone()));
    let servings: Arc<dyn ServingRepository> = Arc::new(PgServingRepository::new(pool.clone()));
    let logs: Arc<dyn LogRepository> = Arc::new(PgLogRepository::new(pool.clone()));

    let local_login_enabled = config.auth.local.is_some();
    let (authenticator, auth_service) =
        pick_authenticator(&config.auth, &config.env_name, pool.clone()).await?;

    // Build OidcRegistry when providers are configured.
    let oidc: Option<Arc<OidcRegistry>> = if config.auth.oidc.is_empty() {
        None
    } else {
        // oidc_common is guaranteed Some when oidc is non-empty (enforced by
        // load_auth at startup).
        let common = config.oidc_common.as_ref().ok_or_else(|| {
            anyhow!("oidc_common must be present when OIDC providers are configured")
        })?;

        // auth_service is Some whenever local or oidc is present.
        let auth = auth_service.as_ref().ok_or_else(|| {
            anyhow!("auth_service must be present when OIDC providers are configured")
        })?;

        let mut providers = HashMap::new();
        for p in &config.auth.oidc {
            let jwks = Arc::new(
                JwksVerifier::new(p.jwks_url.clone(), Duration::from_secs(600)).await?,
            );
            let http = reqwest::Client::builder()
                .timeout(Duration::from_secs(common.http_timeout_secs))
                .build()?;
            providers.insert(
                p.id.clone(),
                Arc::new(OidcProvider {
                    config: p.clone(),
                    jwks,
                    http,
                }),
            );
        }

        let handoffs: Arc<dyn OidcHandoffRepository> =
            Arc::new(PgOidcHandoffRepository::new(pool.clone()));
        let state_signer = Arc::new(StateSigner::new(common.state_secret.clone()));

        Some(Arc::new(OidcRegistry {
            providers,
            state_signer,
            fe_origin: common.fe_origin.clone(),
            handoffs,
            auth: auth.clone(),
        }))
    };

    Ok(AppState::from_ports(
        users,
        weights,
        goals,
        foods,
        servings,
        logs,
        authenticator,
        auth_service,
        oidc,
        local_login_enabled,
    ))
}

// ── router ────────────────────────────────────────────────────────────────────

/// Build the axum router for any application state. Pure function — no
/// I/O — so tests can swap in fakes and assert HTTP behaviour without a
/// network.
pub fn router(state: AppState) -> Router {
    let public = routes::health::router();
    let public = if state.auth.is_some() {
        public.merge(routes::auth::router())
    } else {
        public
    };

    let authed = Router::new()
        .merge(routes::profile::router())
        .merge(routes::weights::router())
        .merge(routes::goals::router())
        .merge(routes::foods::router())
        .merge(routes::log::router())
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth));

    let api = Router::new().merge(public).merge(authed);

    Router::new()
        .nest("/api/v1", api)
        .with_state(state)
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
}

/// Convenience for the production binary: build state and router in one
/// call.
pub async fn build_router(pool: PgPool, config: &AppConfig) -> Result<Router> {
    Ok(router(build_state(pool, config).await?))
}

// ── pick_authenticator ────────────────────────────────────────────────────────

/// Select the runtime authenticator from config. Precedence:
/// 1. Dev-bypass (if configured and env != production).
/// 2. LocalAuthenticator (resolves opaque tokens from `local_auth_tokens`).
///    Used for both local-creds login AND OIDC users after the callback
///    mints their session token.
///
/// `JwksAuthenticator` is no longer wired here — it remains available for
/// direct use in tests or future specialised paths, but OIDC users
/// authenticate via the same `LocalAuthenticator` surface after callback.
async fn pick_authenticator(
    cfg: &AuthConfig,
    env_name: &str,
    pool: PgPool,
) -> Result<(DynAuthenticator, Option<Arc<AuthService>>)> {
    // 1. Dev-bypass has highest precedence.
    if let Some(dev) = &cfg.dev_bypass {
        if env_name == "production" {
            return Err(anyhow!("dev auth bypass cannot be used in production"));
        }
        let identity = UserIdentity {
            issuer: dev.issuer.clone(),
            external_id: dev.external_id.clone(),
            email: dev.email.clone(),
            display_name: dev.display_name.clone(),
        };
        let authn: Arc<dyn Authenticator> =
            Arc::new(DevAuthenticator::new(dev.token.clone(), identity));
        return Ok((authn, None));
    }

    // 2. Local-creds (or OIDC-only) → resolve opaque tokens against
    //    local_auth_tokens via LocalAuthenticator.
    if cfg.local.is_some() || !cfg.oidc.is_empty() {
        let users: Arc<dyn UserRepository> = Arc::new(PgUserRepository::new(pool.clone()));
        let local: Arc<dyn LocalAuthRepository> =
            Arc::new(PgLocalAuthRepository::new(pool.clone()));
        let auth_service = Arc::new(AuthService::new(users, local));
        let authn: Arc<dyn Authenticator> =
            Arc::new(LocalAuthenticator::new(auth_service.clone()));
        return Ok((authn, Some(auth_service)));
    }

    // Should be unreachable — load_auth already enforced "at least one method".
    Err(anyhow!("no auth method configured"))
}
