use async_trait::async_trait;
use loseit_core::auth::{AuthError, Authenticator};
use loseit_core::domain::UserIdentity;

/// Authenticator that accepts a single configured token and resolves it
/// to a fixed identity. Same shape as the production dev-bypass, but
/// without any of the env wiring — useful for HTTP-level tests.
pub struct FakeAuthenticator {
    token: String,
    identity: UserIdentity,
}

impl FakeAuthenticator {
    pub fn new(token: impl Into<String>, identity: UserIdentity) -> Self {
        Self {
            token: token.into(),
            identity,
        }
    }
}

#[async_trait]
impl Authenticator for FakeAuthenticator {
    async fn authenticate(&self, token: &str) -> Result<UserIdentity, AuthError> {
        if token == self.token {
            Ok(self.identity.clone())
        } else {
            Err(AuthError::Invalid)
        }
    }
}
