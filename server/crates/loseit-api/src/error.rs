//! HTTP-shaped error type for the API layer.
//!
//! Handlers and middleware never return [`loseit_core::CoreError`] directly
//! from axum; they go through [`ApiError`] which is the one place we
//! decide how a domain failure becomes an HTTP response. Keeping this
//! translation in one file is what lets the rest of the routes read as
//! plain business calls.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use loseit_core::auth::AuthError;
use loseit_core::CoreError;
use serde::Serialize;

#[derive(Debug)]
pub struct ApiError {
    pub status: StatusCode,
    pub code: &'static str,
    pub message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }

    pub fn bad_request(msg: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "bad_request", msg)
    }

    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, "unauthorized", msg)
    }

    pub fn not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", "resource not found")
    }
}

#[derive(Serialize)]
struct WireError<'a> {
    code: &'a str,
    message: &'a str,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = Json(WireError {
            code: self.code,
            message: &self.message,
        });
        (self.status, body).into_response()
    }
}

impl From<CoreError> for ApiError {
    fn from(err: CoreError) -> Self {
        match err {
            CoreError::NotFound => Self::not_found(),
            CoreError::Conflict(msg) => Self::new(StatusCode::CONFLICT, "conflict", msg),
            CoreError::Validation(msg) => Self::bad_request(msg),
            CoreError::Forbidden => Self::new(StatusCode::FORBIDDEN, "forbidden", "forbidden"),
            CoreError::Upstream(msg) => Self::new(StatusCode::BAD_GATEWAY, "upstream_error", msg),
            CoreError::Internal(inner) => {
                tracing::error!(error = %inner, "internal error");
                Self::new(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal_error",
                    "something went wrong",
                )
            }
        }
    }
}

impl From<AuthError> for ApiError {
    fn from(err: AuthError) -> Self {
        match err {
            AuthError::Missing => Self::unauthorized("missing credential"),
            AuthError::Invalid => Self::unauthorized("invalid credential"),
            AuthError::Upstream(msg) => {
                tracing::error!(error = %msg, "auth upstream failure");
                Self::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "auth_unavailable",
                    "authentication temporarily unavailable",
                )
            }
        }
    }
}
