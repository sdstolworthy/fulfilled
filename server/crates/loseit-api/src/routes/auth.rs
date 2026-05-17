use axum::extract::State;
use axum::routing::post;
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

pub fn router() -> Router<AppState> {
    Router::new().route("/auth/login", post(login))
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
