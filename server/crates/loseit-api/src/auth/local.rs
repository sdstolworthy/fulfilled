use std::sync::Arc;

use async_trait::async_trait;
use loseit_core::auth::{AuthError, Authenticator};
use loseit_core::domain::UserIdentity;
use loseit_core::service::AuthService;

pub struct LocalAuthenticator {
    auth: Arc<AuthService>,
}

impl LocalAuthenticator {
    pub fn new(auth: Arc<AuthService>) -> Self {
        Self { auth }
    }
}

#[async_trait]
impl Authenticator for LocalAuthenticator {
    async fn authenticate(&self, token: &str) -> Result<UserIdentity, AuthError> {
        let user = self.auth.verify_token(token).await?;
        Ok(user.identity)
    }
}
