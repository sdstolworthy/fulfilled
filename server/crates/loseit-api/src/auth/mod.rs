//! HTTP-side of authentication. The actual token-validation logic lives
//! behind [`loseit_core::auth::Authenticator`] — this module is just
//! responsible for:
//!
//!   1. Pulling the bearer token off the `Authorization` header.
//!   2. Calling the injected authenticator.
//!   3. Resolving the asserted identity to a local user row.
//!   4. Handing that user to handlers as an extractor.

pub mod dev;
pub mod jwks;
pub mod local;
pub mod oidc;

use std::sync::Arc;

use axum::async_trait;
use axum::extract::{FromRequestParts, State};
use axum::http::request::Parts;
use axum::http::{header, HeaderMap};
use axum::middleware::Next;
use axum::response::Response;
use loseit_core::auth::{AuthError, Authenticator};
use loseit_core::domain::User;

use crate::error::ApiError;
use crate::server::AppState;

/// Marker inserted into the request extensions once a request has been
/// authenticated. Handlers pull this out via the [`AuthenticatedUser`]
/// extractor instead of touching the header directly.
#[derive(Clone)]
pub struct AuthenticatedUser(pub User);

pub async fn require_auth(
    State(state): State<AppState>,
    mut req: axum::extract::Request,
    next: Next,
) -> Result<Response, ApiError> {
    let token = extract_bearer(req.headers())?;
    let identity = state
        .authenticator
        .authenticate(&token)
        .await
        .map_err(ApiError::from)?;
    let user = state.users.ensure_user(&identity).await?;
    req.extensions_mut().insert(AuthenticatedUser(user));
    Ok(next.run(req).await)
}

fn extract_bearer(headers: &HeaderMap) -> Result<String, ApiError> {
    let value = headers
        .get(header::AUTHORIZATION)
        .ok_or_else(|| ApiError::from(AuthError::Missing))?
        .to_str()
        .map_err(|_| ApiError::from(AuthError::Invalid))?;
    let token = value
        .strip_prefix("Bearer ")
        .or_else(|| value.strip_prefix("bearer "))
        .ok_or_else(|| ApiError::from(AuthError::Invalid))?
        .trim();
    if token.is_empty() {
        return Err(ApiError::from(AuthError::Missing));
    }
    Ok(token.to_string())
}

#[async_trait]
impl<S> FromRequestParts<S> for AuthenticatedUser
where
    S: Send + Sync,
{
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<AuthenticatedUser>()
            .cloned()
            .ok_or_else(|| ApiError::unauthorized("not authenticated"))
    }
}

/// Anything constructible as a trait object satisfies the injected port.
pub type DynAuthenticator = Arc<dyn Authenticator>;
