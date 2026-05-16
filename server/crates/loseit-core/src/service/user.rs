use std::sync::Arc;

use uuid::Uuid;

use crate::domain::{ProfilePatch, User, UserIdentity};
use crate::repo::UserRepository;
use crate::CoreResult;

/// Owns the rules around user identity and profile changes. Holds the
/// repository as a trait object so any storage backend can satisfy it.
pub struct UserService {
    users: Arc<dyn UserRepository>,
}

impl UserService {
    pub fn new(users: Arc<dyn UserRepository>) -> Self {
        Self { users }
    }

    /// Idempotently resolve an external identity to a local user row. Used
    /// by the auth middleware on every authenticated request — the first
    /// time a person signs in their row is provisioned here.
    #[tracing::instrument(skip(self, identity), fields(issuer = %identity.issuer, external_id = %identity.external_id))]
    pub async fn ensure_user(&self, identity: &UserIdentity) -> CoreResult<User> {
        if let Some(existing) = self.users.find_by_identity(identity).await? {
            return Ok(existing);
        }
        self.users.create(identity).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn get(&self, id: Uuid) -> CoreResult<User> {
        self.users
            .find_by_id(id)
            .await?
            .ok_or(crate::CoreError::NotFound)
    }

    #[tracing::instrument(skip(self, patch))]
    pub async fn update_profile(&self, id: Uuid, patch: ProfilePatch) -> CoreResult<User> {
        self.users.update_profile(id, &patch).await
    }

    #[tracing::instrument(skip(self))]
    pub async fn delete_self(&self, user_id: Uuid) -> CoreResult<()> {
        self.users.delete_user(user_id).await
    }
}
