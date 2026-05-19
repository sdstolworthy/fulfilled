use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{delete, post};
use axum::{Json, Router};
use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use loseit_core::domain::{Weight, WeightDraft};
use loseit_core::service::WeightService;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthenticatedUser;
use crate::error::ApiError;
use crate::routes::pagination::PaginatedResponse;
use crate::server::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/weights", post(create).get(list))
        .route("/weights/:id", delete(remove))
}

#[derive(Deserialize)]
struct CreateBody {
    recorded_on: NaiveDate,
    recorded_at_local: Option<NaiveTime>,
    weight_kg: Decimal,
    note: Option<String>,
}

#[derive(Deserialize)]
struct ListQuery {
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
    limit: Option<i64>,
    offset: Option<i64>,
}

#[derive(Serialize)]
struct WeightResponse {
    id: Uuid,
    recorded_on: NaiveDate,
    recorded_at_local: Option<NaiveTime>,
    weight_kg: Decimal,
    note: Option<String>,
    created_at: DateTime<Utc>,
}

impl From<Weight> for WeightResponse {
    fn from(w: Weight) -> Self {
        Self {
            id: w.id,
            recorded_on: w.recorded_on,
            recorded_at_local: w.recorded_at_local,
            weight_kg: w.weight_kg,
            note: w.note,
            created_at: w.created_at,
        }
    }
}

async fn create(
    State(weights): State<Arc<WeightService>>,
    AuthenticatedUser(user): AuthenticatedUser,
    Json(body): Json<CreateBody>,
) -> Result<(StatusCode, Json<WeightResponse>), ApiError> {
    let draft = WeightDraft {
        recorded_on: body.recorded_on,
        recorded_at_local: body.recorded_at_local,
        weight_kg: body.weight_kg,
        note: body.note,
    };
    let weight = weights.record(user.id, draft).await?;
    Ok((StatusCode::CREATED, Json(weight.into())))
}

async fn list(
    State(weights): State<Arc<WeightService>>,
    AuthenticatedUser(user): AuthenticatedUser,
    Query(q): Query<ListQuery>,
) -> Result<Json<PaginatedResponse<WeightResponse>>, ApiError> {
    let page = weights
        .list(user.id, q.from, q.to, q.limit, q.offset)
        .await?;
    Ok(Json(page.into()))
}

async fn remove(
    State(weights): State<Arc<WeightService>>,
    AuthenticatedUser(user): AuthenticatedUser,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    weights.delete(user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
