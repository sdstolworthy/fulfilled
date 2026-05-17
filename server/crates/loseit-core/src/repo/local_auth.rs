use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::{LocalAuthCredential, Username};
use crate::CoreResult;

#[async_trait]
pub trait LocalAuthRepository: Send + Sync + 'static {
    /// Fetch the credential row for a username, if any. Returns
    /// `Ok(None)` for unknown usernames — caller must still perform
    /// a constant-time argon2 verify against a dummy hash to avoid
    /// user-enumeration via timing.
    async fn find_by_username(
        &self,
        username: &Username,
    ) -> CoreResult<Option<LocalAuthCredential>>;

    /// Upsert a credential row. Used by the runtime seed and any
    /// future password-change flow. `(user_id, username,
    /// password_hash)` overwrite each other.
    async fn upsert_credential(
        &self,
        user_id: Uuid,
        username: &Username,
        password_hash: &str,
    ) -> CoreResult<LocalAuthCredential>;

    /// Persist an opaque token. `token_hash` is sha256(raw) hex-
    /// encoded; the raw token is never sent to the repo.
    async fn insert_token(
        &self,
        token_hash: &str,
        user_id: Uuid,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()>;

    /// Resolve a token hash to a user id, refreshing `expires_at`
    /// under the sliding-window policy. Returns `Ok(None)` if the
    /// token does not exist or is expired.
    async fn touch_token(
        &self,
        token_hash: &str,
        new_expires_at: DateTime<Utc>,
    ) -> CoreResult<Option<Uuid>>;

    /// Drop a single token. Used by an eventual `POST /auth/logout`;
    /// not wired by this ticket but the trait method ships now so the
    /// route is a pure handler-side addition.
    async fn delete_token(&self, token_hash: &str) -> CoreResult<()>;
}
