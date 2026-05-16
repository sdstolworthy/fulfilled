//! Authentication port.
//!
//! Validating a credential and producing a [`UserIdentity`] is a domain
//! concern: the rest of the business layer wants to know *who* is calling,
//! not *how* their token was checked. Concrete validators (JWKS, dev
//! bypass, future API keys) implement this trait and are injected at the
//! composition root.

use async_trait::async_trait;
use thiserror::Error;

use crate::domain::UserIdentity;

#[derive(Debug, Error)]
pub enum AuthError {
    #[error("missing credential")]
    Missing,

    #[error("invalid credential")]
    Invalid,

    #[error("upstream verifier unavailable: {0}")]
    Upstream(String),
}

#[async_trait]
pub trait Authenticator: Send + Sync + 'static {
    /// Validate a raw bearer-token string and return the asserted identity.
    async fn authenticate(&self, token: &str) -> Result<UserIdentity, AuthError>;
}
