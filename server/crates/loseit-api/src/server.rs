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

use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use axum::middleware;
use axum::Router;
use loseit_core::auth::Authenticator;
use loseit_core::domain::UserIdentity;
use loseit_core::repo::{
    FoodRepository, GoalRepository, LocalAuthRepository, LogRepository, ServingRepository,
    UserRepository, WeightRepository,
};
use loseit_core::service::{
    AuthService, FoodService, GoalService, LogService, ServingService, UserService, WeightService,
};
use loseit_db::{
    PgFoodRepository, PgGoalRepository, PgLocalAuthRepository, PgLogRepository, PgPool,
    PgServingRepository, PgUserRepository, PgWeightRepository,
};
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use crate::auth::{
    dev::DevAuthenticator, jwks::JwksAuthenticator, local::LocalAuthenticator, require_auth,
    DynAuthenticator,
};
use crate::config::{AppConfig, AuthConfig};
use crate::routes;

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
        }
    }
}

/// Production wiring: Postgres repositories + the authenticator selected
/// from config.
///
/// Async because the JWKS authenticator warms its cache via an initial
/// HTTP fetch at construction. Failing that fetch means the configured
/// idP is unreachable; we'd rather refuse to start than 503 every
/// request.
pub async fn build_state(pool: PgPool, config: &AppConfig) -> Result<AppState> {
    let users: Arc<dyn UserRepository> = Arc::new(PgUserRepository::new(pool.clone()));
    let weights: Arc<dyn WeightRepository> = Arc::new(PgWeightRepository::new(pool.clone()));
    let goals: Arc<dyn GoalRepository> = Arc::new(PgGoalRepository::new(pool.clone()));
    let foods: Arc<dyn FoodRepository> = Arc::new(PgFoodRepository::new(pool.clone()));
    let servings: Arc<dyn ServingRepository> = Arc::new(PgServingRepository::new(pool.clone()));
    let logs: Arc<dyn LogRepository> = Arc::new(PgLogRepository::new(pool.clone()));
    let authenticator = build_authenticator(&config.auth, &config.env_name, pool).await?;
    Ok(AppState::from_ports(
        users,
        weights,
        goals,
        foods,
        servings,
        logs,
        authenticator,
    ))
}

/// Build the axum router for any application state. Pure function — no
/// I/O — so tests can swap in fakes and assert HTTP behaviour without a
/// network.
pub fn router(state: AppState) -> Router {
    let public = routes::health::router();

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

async fn build_authenticator(
    cfg: &AuthConfig,
    env_name: &str,
    pool: PgPool,
) -> Result<DynAuthenticator> {
    match cfg {
        AuthConfig::DevBypass {
            token,
            issuer,
            external_id,
            email,
            display_name,
        } => {
            if env_name == "production" {
                return Err(anyhow!("dev auth bypass cannot be used in production"));
            }
            let identity = UserIdentity {
                issuer: issuer.clone(),
                external_id: external_id.clone(),
                email: email.clone(),
                display_name: display_name.clone(),
            };
            let authn: Arc<dyn Authenticator> =
                Arc::new(DevAuthenticator::new(token.clone(), identity));
            Ok(authn)
        }
        AuthConfig::Jwks {
            issuer,
            audience,
            jwks_url,
            cache_ttl_secs,
        } => {
            let auth = JwksAuthenticator::new(
                issuer.clone(),
                audience.clone(),
                jwks_url.clone(),
                Duration::from_secs(*cache_ttl_secs),
            )
            .await?;
            let authn: Arc<dyn Authenticator> = Arc::new(auth);
            Ok(authn)
        }
        AuthConfig::Local => {
            let users: Arc<dyn UserRepository> = Arc::new(PgUserRepository::new(pool.clone()));
            let local: Arc<dyn LocalAuthRepository> =
                Arc::new(PgLocalAuthRepository::new(pool.clone()));
            let auth_service = Arc::new(AuthService::new(users, local));
            let authn: Arc<dyn Authenticator> = Arc::new(LocalAuthenticator::new(auth_service));
            Ok(authn)
        }
    }
}
