use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use loseit_core::domain::{LocalAuthCredential, Username};
use loseit_core::error::CoreResult;
use loseit_core::repo::LocalAuthRepository;

struct TokenRow {
    user_id: Uuid,
    expires_at: DateTime<Utc>,
}

#[derive(Default)]
pub struct InMemoryLocalAuthRepository {
    creds: Mutex<HashMap<Username, LocalAuthCredential>>,
    tokens: Mutex<HashMap<String, TokenRow>>,
}

impl InMemoryLocalAuthRepository {
    pub fn new() -> Self {
        Self::default()
    }

    /// Test-only helper to peek at a token's expiration time.
    pub fn peek_expires_at(&self, token_hash: &str) -> Option<DateTime<Utc>> {
        let tokens = self.tokens.lock().unwrap();
        tokens.get(token_hash).map(|row| row.expires_at)
    }

    /// Test-only helper that back-dates a token so it appears expired.
    pub fn force_expire(&self, token_hash: &str) {
        let mut tokens = self.tokens.lock().unwrap();
        if let Some(row) = tokens.get_mut(token_hash) {
            row.expires_at = chrono::Utc::now() - chrono::Duration::seconds(1);
        }
    }
}

#[async_trait]
impl LocalAuthRepository for InMemoryLocalAuthRepository {
    async fn find_by_username(
        &self,
        username: &Username,
    ) -> CoreResult<Option<LocalAuthCredential>> {
        Ok(self.creds.lock().unwrap().get(username).cloned())
    }

    async fn upsert_credential(
        &self,
        user_id: Uuid,
        username: &Username,
        password_hash: &str,
    ) -> CoreResult<LocalAuthCredential> {
        let mut creds = self.creds.lock().unwrap();
        let now = Utc::now();

        // Scan for existing entry with same user_id and remove it (it may have a different username key).
        let old_created_at = creds
            .values()
            .find(|c| c.user_id == user_id)
            .map(|c| c.created_at);

        if let Some(old_cred) = creds.values().find(|c| c.user_id == user_id) {
            let old_un = old_cred.username.clone();
            creds.remove(&old_un);
        }

        // Determine created_at: preserve if this user_id already existed, otherwise use now.
        let credential = LocalAuthCredential {
            user_id,
            username: username.clone(),
            password_hash: password_hash.to_string(),
            created_at: old_created_at.unwrap_or(now),
            updated_at: now,
        };

        creds.insert(username.clone(), credential.clone());
        Ok(credential)
    }

    async fn insert_token(
        &self,
        token_hash: &str,
        user_id: Uuid,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        self.tokens.lock().unwrap().insert(
            token_hash.to_string(),
            TokenRow {
                user_id,
                expires_at,
            },
        );
        Ok(())
    }

    async fn touch_token(
        &self,
        token_hash: &str,
        new_expires_at: DateTime<Utc>,
    ) -> CoreResult<Option<Uuid>> {
        let mut tokens = self.tokens.lock().unwrap();
        let now = Utc::now();

        // Look up the token and check expiration.
        if let Some(row) = tokens.get(token_hash) {
            if row.expires_at <= now {
                // Token is expired; remove it and return None.
                tokens.remove(token_hash);
                return Ok(None);
            }

            // Token is valid; update expires_at to the max of current and new.
            let user_id = row.user_id;
            let updated_expires_at = row.expires_at.max(new_expires_at);
            tokens.insert(
                token_hash.to_string(),
                TokenRow {
                    user_id,
                    expires_at: updated_expires_at,
                },
            );
            Ok(Some(user_id))
        } else {
            // Token not found.
            Ok(None)
        }
    }

    async fn delete_token(&self, token_hash: &str) -> CoreResult<()> {
        self.tokens.lock().unwrap().remove(token_hash);
        Ok(())
    }
}
