use axum::routing::get;
use axum::Json;
use axum::Router;
use serde::Serialize;

use crate::server::AppState;

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

pub fn router() -> Router<AppState> {
    Router::new().route(
        "/health",
        get(|| async { Json(HealthResponse { status: "ok" }) }),
    )
}
