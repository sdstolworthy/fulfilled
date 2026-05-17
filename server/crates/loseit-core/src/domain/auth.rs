use chrono::{DateTime, Utc};
use uuid::Uuid;

/// Always lower-cased; constructor enforces this. Empty / >64-char
/// input is rejected by returning `None`. Malformed-username failures
/// land as 401 (not 400) at the API layer so "user does not exist" and
/// "user exists but wrong password" are wire-indistinguishable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Username(String);

impl Username {
    pub fn parse(raw: &str) -> Option<Self> {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.len() > 64 {
            return None;
        }
        Some(Self(trimmed.to_ascii_lowercase()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Newly-minted token. `raw` is only seen at issue time; persistence
/// is by sha256(raw).
#[derive(Debug, Clone)]
pub struct LocalAuthToken {
    pub raw: String,
    pub user_id: Uuid,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct LocalAuthCredential {
    pub user_id: Uuid,
    pub username: Username,
    pub password_hash: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
