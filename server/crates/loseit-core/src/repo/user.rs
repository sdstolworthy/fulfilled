use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::{ProfilePatch, User, UserIdentity};
use crate::CoreResult;

#[async_trait]
pub trait UserRepository: Send + Sync + 'static {
    /// Fetch a user by their internal id.
    async fn find_by_id(&self, id: Uuid) -> CoreResult<Option<User>>;

    /// Fetch a user by their external (issuer, external_id) handle.
    async fn find_by_identity(&self, identity: &UserIdentity) -> CoreResult<Option<User>>;

    /// Insert a new user with the given identity, returning the row.
    async fn create(&self, identity: &UserIdentity) -> CoreResult<User>;

    /// Apply a profile patch to an existing user, returning the updated row.
    async fn update_profile(&self, id: Uuid, patch: &ProfilePatch) -> CoreResult<User>;
}
