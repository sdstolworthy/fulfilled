use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use chrono::{DateTime, NaiveDate, Utc};
use loseit_core::domain::{Goal, GoalDraft, GoalPatch};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthenticatedUser;
use crate::error::ApiError;
use crate::server::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/goals", post(create).get(list))
        .route("/goals/active", get(active))
        .route("/goals/:id", patch(update).delete(remove))
}

#[derive(Deserialize)]
struct CreateBody {
    starts_on: NaiveDate,
    ends_on: Option<NaiveDate>,
    start_weight_kg: Option<Decimal>,
    target_weight_kg: Option<Decimal>,
    weekly_rate_kg: Option<Decimal>,
    daily_calorie_target: Option<i32>,
    protein_g_target: Option<Decimal>,
    carbs_g_target: Option<Decimal>,
    fat_g_target: Option<Decimal>,
}

#[derive(Deserialize, Default)]
struct PatchBody {
    starts_on: Option<NaiveDate>,
    ends_on: Option<NaiveDate>,
    start_weight_kg: Option<Decimal>,
    target_weight_kg: Option<Decimal>,
    weekly_rate_kg: Option<Decimal>,
    daily_calorie_target: Option<i32>,
    protein_g_target: Option<Decimal>,
    carbs_g_target: Option<Decimal>,
    fat_g_target: Option<Decimal>,
}

#[derive(Deserialize)]
struct ActiveQuery {
    on: Option<NaiveDate>,
}

#[derive(Serialize)]
pub(crate) struct GoalResponse {
    pub(crate) id: Uuid,
    pub(crate) starts_on: NaiveDate,
    pub(crate) ends_on: Option<NaiveDate>,
    pub(crate) start_weight_kg: Option<Decimal>,
    pub(crate) target_weight_kg: Option<Decimal>,
    pub(crate) weekly_rate_kg: Option<Decimal>,
    pub(crate) daily_calorie_target: Option<i32>,
    pub(crate) protein_g_target: Option<Decimal>,
    pub(crate) carbs_g_target: Option<Decimal>,
    pub(crate) fat_g_target: Option<Decimal>,
    pub(crate) created_at: DateTime<Utc>,
    pub(crate) updated_at: DateTime<Utc>,
}

impl From<Goal> for GoalResponse {
    fn from(g: Goal) -> Self {
        Self {
            id: g.id,
            starts_on: g.starts_on,
            ends_on: g.ends_on,
            start_weight_kg: g.start_weight_kg,
            target_weight_kg: g.target_weight_kg,
            weekly_rate_kg: g.weekly_rate_kg,
            daily_calorie_target: g.daily_calorie_target,
            protein_g_target: g.protein_g_target,
            carbs_g_target: g.carbs_g_target,
            fat_g_target: g.fat_g_target,
            created_at: g.created_at,
            updated_at: g.updated_at,
        }
    }
}

async fn create(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<CreateBody>,
) -> Result<(StatusCode, Json<GoalResponse>), ApiError> {
    let draft = GoalDraft {
        starts_on: body.starts_on,
        ends_on: body.ends_on,
        start_weight_kg: body.start_weight_kg,
        target_weight_kg: body.target_weight_kg,
        weekly_rate_kg: body.weekly_rate_kg,
        daily_calorie_target: body.daily_calorie_target,
        protein_g_target: body.protein_g_target,
        carbs_g_target: body.carbs_g_target,
        fat_g_target: body.fat_g_target,
    };
    let goal = state.goals.create(user.id, draft).await?;
    Ok((StatusCode::CREATED, Json(goal.into())))
}

async fn list(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
) -> Result<Json<Vec<GoalResponse>>, ApiError> {
    let goals = state.goals.list(user.id).await?;
    Ok(Json(goals.into_iter().map(Into::into).collect()))
}

async fn active(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<ActiveQuery>,
) -> Result<Json<GoalResponse>, ApiError> {
    let on = q.on.unwrap_or_else(|| Utc::now().date_naive());
    let goal = state.goals.active_on(user.id, on).await?;
    Ok(Json(goal.into()))
}

async fn update(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
    Json(body): Json<PatchBody>,
) -> Result<Json<GoalResponse>, ApiError> {
    let patch = GoalPatch {
        starts_on: body.starts_on,
        ends_on: body.ends_on,
        start_weight_kg: body.start_weight_kg,
        target_weight_kg: body.target_weight_kg,
        weekly_rate_kg: body.weekly_rate_kg,
        daily_calorie_target: body.daily_calorie_target,
        protein_g_target: body.protein_g_target,
        carbs_g_target: body.carbs_g_target,
        fat_g_target: body.fat_g_target,
    };
    let goal = state.goals.update(user.id, id, patch).await?;
    Ok(Json(goal.into()))
}

async fn remove(
    State(state): State<AppState>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    state.goals.delete(user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
