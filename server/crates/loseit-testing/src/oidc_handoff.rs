use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use loseit_core::error::CoreResult;
use loseit_core::repo::oidc_handoff::HandoffClaim;
use loseit_core::repo::OidcHandoffRepository;

struct HandoffRow {
    user_id: Uuid,
    raw_token: String,
    token_expires_at: DateTime<Utc>,
    expires_at: DateTime<Utc>,
}

#[derive(Default)]
pub struct InMemoryOidcHandoffRepository {
    rows: Mutex<HashMap<String, HandoffRow>>,
}

impl InMemoryOidcHandoffRepository {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl OidcHandoffRepository for InMemoryOidcHandoffRepository {
    async fn insert(
        &self,
        code_hash: &str,
        user_id: Uuid,
        raw_token: &str,
        token_expires_at: DateTime<Utc>,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        self.rows.lock().unwrap().insert(
            code_hash.to_string(),
            HandoffRow {
                user_id,
                raw_token: raw_token.to_string(),
                token_expires_at,
                expires_at,
            },
        );
        Ok(())
    }

    async fn claim(&self, code_hash: &str) -> CoreResult<Option<HandoffClaim>> {
        let mut rows = self.rows.lock().unwrap();
        let now = Utc::now();

        match rows.get(code_hash) {
            Some(row) if row.expires_at > now => {
                let claim = HandoffClaim {
                    user_id: row.user_id,
                    raw_token: row.raw_token.clone(),
                    token_expires_at: row.token_expires_at,
                };
                rows.remove(code_hash);
                Ok(Some(claim))
            }
            Some(_) => {
                // Expired — remove the stale row.
                rows.remove(code_hash);
                Ok(None)
            }
            None => Ok(None),
        }
    }
}
