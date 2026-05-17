use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::CoreResult;

#[async_trait]
pub trait OidcHandoffRepository: Send + Sync + 'static {
    async fn insert(
        &self,
        code_hash: &str,
        user_id: Uuid,
        raw_token: &str,
        token_expires_at: DateTime<Utc>,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()>;

    /// Atomic claim: returns (user_id, raw_token, token_expires_at) and
    /// deletes the row in the same statement. Returns `Ok(None)` for
    /// missing/expired codes.
    async fn claim(&self, code_hash: &str) -> CoreResult<Option<HandoffClaim>>;
}

#[derive(Debug, Clone)]
pub struct HandoffClaim {
    pub user_id: Uuid,
    pub raw_token: String,
    pub token_expires_at: DateTime<Utc>,
}
