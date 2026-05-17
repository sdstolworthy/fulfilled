use axum::extract::State;
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::ApiError;
use crate::server::AppState;

#[derive(Deserialize)]
struct LoginBody {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct LoginResponse {
    token: String,
    expires_at: DateTime<Utc>,
}

#[derive(Serialize)]
struct ProvidersResponse {
    local: LocalProviderDescriptor,
    oidc: Vec<OidcProviderDescriptor>,
}

#[derive(Serialize)]
struct LocalProviderDescriptor {
    enabled: bool,
}

#[derive(Serialize)]
struct OidcProviderDescriptor {
    id: String,
    display_name: String,
    icon_url: Option<String>,
    start_url: String,
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/auth/providers", get(providers))
        .route("/auth/login", post(login))
}

async fn login(
    State(state): State<AppState>,
    Json(body): Json<LoginBody>,
) -> Result<Json<LoginResponse>, ApiError> {
    let Some(auth) = state.auth.clone() else {
        // Defensive: route is normally not mounted when auth is None,
        // but guard against state-level confusion.
        return Err(ApiError::not_found());
    };
    let token = auth.login(&body.username, &body.password).await?;
    Ok(Json(LoginResponse {
        token: token.raw,
        expires_at: token.expires_at,
    }))
}

async fn providers(State(state): State<AppState>) -> Json<ProvidersResponse> {
    let local = LocalProviderDescriptor {
        enabled: state.local_login_enabled,
    };
    let oidc = state
        .oidc
        .as_ref()
        .map(|r| {
            r.providers
                .values()
                .map(|p| OidcProviderDescriptor {
                    id: p.config.id.clone(),
                    display_name: p.config.display_name.clone(),
                    icon_url: p.config.icon_url.clone(),
                    start_url: format!("/api/v1/auth/oidc/{}/start", p.config.id),
                })
                .collect()
        })
        .unwrap_or_default();
    Json(ProvidersResponse { local, oidc })
}
