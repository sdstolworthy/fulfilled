use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::{get, patch};
use axum::{Json, Router};
use chrono::{DateTime, NaiveDate, Utc};
use loseit_core::domain::{ActivityLevel, ProfilePatch, Sex, User};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthenticatedUser;
use crate::error::ApiError;
use crate::server::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/me", get(get_me))
        .route("/me", patch(patch_me).delete(delete_me))
}

#[derive(Serialize)]
struct UserResponse {
    id: Uuid,
    issuer: String,
    external_id: String,
    email: Option<String>,
    display_name: Option<String>,
    sex: Option<String>,
    birth_date: Option<NaiveDate>,
    height_cm: Option<Decimal>,
    activity_level: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<User> for UserResponse {
    fn from(u: User) -> Self {
        Self {
            id: u.id,
            issuer: u.identity.issuer,
            external_id: u.identity.external_id,
            email: u.identity.email,
            display_name: u.identity.display_name,
            sex: u.sex.map(|s| s.as_str().to_string()),
            birth_date: u.birth_date,
            height_cm: u.height_cm,
            activity_level: u.activity_level.map(|a| a.as_str().to_string()),
            created_at: u.created_at,
            updated_at: u.updated_at,
        }
    }
}

#[derive(Deserialize, Default)]
struct ProfilePatchBody {
    email: Option<String>,
    display_name: Option<String>,
    sex: Option<String>,
    birth_date: Option<NaiveDate>,
    height_cm: Option<Decimal>,
    activity_level: Option<String>,
}

impl ProfilePatchBody {
    fn into_domain(self) -> Result<ProfilePatch, ApiError> {
        let sex = match self.sex.as_deref() {
            None => None,
            Some(s) => Some(Sex::parse(s).ok_or_else(|| ApiError::bad_request("invalid sex"))?),
        };
        let activity_level = match self.activity_level.as_deref() {
            None => None,
            Some(s) => Some(
                ActivityLevel::parse(s)
                    .ok_or_else(|| ApiError::bad_request("invalid activity_level"))?,
            ),
        };
        Ok(ProfilePatch {
            email: self.email,
            display_name: self.display_name,
            sex,
            birth_date: self.birth_date,
            height_cm: self.height_cm,
            activity_level,
        })
    }
}

async fn get_me(AuthenticatedUser(user): AuthenticatedUser) -> Json<UserResponse> {
    Json(user.into())
}

async fn patch_me(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<ProfilePatchBody>,
) -> Result<Json<UserResponse>, ApiError> {
    let patch = body.into_domain()?;
    let updated = state.users.update_profile(user.id, patch).await?;
    Ok(Json(updated.into()))
}

async fn delete_me(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
) -> Result<StatusCode, ApiError> {
    state.users.delete_self(user.id).await?;
    Ok(StatusCode::NO_CONTENT)
}
