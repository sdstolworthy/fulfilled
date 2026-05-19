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
    AuthService, DaySummaryService, FoodService, GoalService, LogService, ServingService,
    UserFoodSummaryReader, UserService, WeightService,
};
use loseit_db::{
    PgFoodRepository, PgGoalRepository, PgLocalAuthRepository, PgLogRepository,
    PgOidcHandoffRepository, PgPool, PgServingRepository, PgUserFoodSummaryReader,
    PgUserRepository, PgWeightRepository,
};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use crate::auth::jwks::JwksVerifier;
use crate::auth::oidc::state::StateSigner;
use crate::auth::{
    dev::DevAuthenticator, local::LocalAuthenticator, require_auth, DynAuthenticator,
};
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
    pub day_summary: Arc<DaySummaryService>,
    pub authenticator: DynAuthenticator,
    pub auth: Option<Arc<AuthService>>,
    /// `Some` when at least one OIDC provider is configured.
    pub oidc: Option<Arc<OidcRegistry>>,
    /// `true` when the local-creds login path is enabled.
    pub local_login_enabled: bool,
    /// `true` when `LOSEIT_ENV_NAME=production`; used to set the `Secure`
    /// attribute on cookies that must not be sent over plain HTTP.
    pub env_is_production: bool,
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
        summary_reader: Arc<dyn UserFoodSummaryReader>,
        authenticator: DynAuthenticator,
        auth_service: Option<Arc<AuthService>>,
        oidc: Option<Arc<OidcRegistry>>,
        local_login_enabled: bool,
        env_is_production: bool,
    ) -> Self {
        let user_service = Arc::new(UserService::new(users));
        let weight_service = Arc::new(WeightService::new(weights));
        let goal_service = Arc::new(GoalService::new(goals.clone()));
        let food_service = Arc::new(FoodService::new(
            foods.clone(),
            servings.clone(),
            summary_reader.clone(),
        ));
        let serving_service = Arc::new(ServingService::new(servings.clone(), foods.clone()));
        let day_summary_service = Arc::new(DaySummaryService::new(logs.clone(), goals.clone()));
        let log_service = Arc::new(LogService::new(logs, foods, servings, summary_reader));
        Self {
            users: user_service,
            weights: weight_service,
            goals: goal_service,
            foods: food_service,
            servings: serving_service,
            logs: log_service,
            day_summary: day_summary_service,
            authenticator,
            auth: auth_service,
            oidc,
            local_login_enabled,
            env_is_production,
        }
    }
}

// ── Narrow state extractors ───────────────────────────────────────────────────
//
// Audit-fix R2: handlers that need only one service used to extract the full
// `State<AppState>` (11+ fields, every clone walked the whole struct). Each
// `FromRef<AppState>` impl below lets a handler write
// `State(logs): State<Arc<LogService>>` instead of
// `State(state): State<AppState>` — the extractor pulls the one service it
// needs and ignores the rest. Handlers that genuinely need two or more
// fields can list multiple `State<>` extractors side-by-side; only the few
// that need the auth/OIDC plumbing still reach for the whole `AppState`.

impl axum::extract::FromRef<AppState> for Arc<UserService> {
    fn from_ref(s: &AppState) -> Self {
        s.users.clone()
    }
}

impl axum::extract::FromRef<AppState> for Arc<WeightService> {
    fn from_ref(s: &AppState) -> Self {
        s.weights.clone()
    }
}

impl axum::extract::FromRef<AppState> for Arc<GoalService> {
    fn from_ref(s: &AppState) -> Self {
        s.goals.clone()
    }
}

impl axum::extract::FromRef<AppState> for Arc<FoodService> {
    fn from_ref(s: &AppState) -> Self {
        s.foods.clone()
    }
}

impl axum::extract::FromRef<AppState> for Arc<ServingService> {
    fn from_ref(s: &AppState) -> Self {
        s.servings.clone()
    }
}

impl axum::extract::FromRef<AppState> for Arc<LogService> {
    fn from_ref(s: &AppState) -> Self {
        s.logs.clone()
    }
}

impl axum::extract::FromRef<AppState> for Arc<DaySummaryService> {
    fn from_ref(s: &AppState) -> Self {
        s.day_summary.clone()
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
    // F5: the single seam between today's `food_log_entries` aggregate
    // and tomorrow's `user_food_summary` denorm table. Swap this one
    // constructor when the v2 reader lands (see
    // `loseit_core::service::user_food_summary` doc comment).
    let summary_reader: Arc<dyn UserFoodSummaryReader> =
        Arc::new(PgUserFoodSummaryReader::new(pool.clone()));

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
            let jwks =
                Arc::new(JwksVerifier::new(p.jwks_url.clone(), Duration::from_secs(600)).await?);
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

    let env_is_production = config.env_name == "production";
    Ok(AppState::from_ports(
        users,
        weights,
        goals,
        foods,
        servings,
        logs,
        summary_reader,
        authenticator,
        auth_service,
        oidc,
        local_login_enabled,
        env_is_production,
    ))
}

// ── router ────────────────────────────────────────────────────────────────────

/// Build the axum router for any application state. Pure function — no
/// I/O — so tests can swap in fakes and assert HTTP behaviour without a
/// network.
pub fn router(state: AppState) -> Router {
    let public = routes::health::router().merge(routes::auth::router());

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
        let authn: Arc<dyn Authenticator> = Arc::new(LocalAuthenticator::new(auth_service.clone()));
        return Ok((authn, Some(auth_service)));
    }

    // Should be unreachable — load_auth already enforced "at least one method".
    Err(anyhow!("no auth method configured"))
}
