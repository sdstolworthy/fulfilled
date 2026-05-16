use async_trait::async_trait;
use loseit_core::auth::{AuthError, Authenticator};
use loseit_core::domain::UserIdentity;

/// Static-token authenticator for local development. Accepts a single
/// configured token and always resolves to the same identity. The
/// composition root refuses to build this in production.
pub struct DevAuthenticator {
    expected_token: String,
    identity: UserIdentity,
}

impl DevAuthenticator {
    pub fn new(expected_token: String, identity: UserIdentity) -> Self {
        Self {
            expected_token,
            identity,
        }
    }
}

#[async_trait]
impl Authenticator for DevAuthenticator {
    async fn authenticate(&self, token: &str) -> Result<UserIdentity, AuthError> {
        if token == self.expected_token {
            Ok(self.identity.clone())
        } else {
            Err(AuthError::Invalid)
        }
    }
}
