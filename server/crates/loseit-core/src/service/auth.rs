use std::sync::Arc;

use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{Duration, Utc};
use rand::{rngs::OsRng, RngCore};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::auth::AuthError;
use crate::domain::{LocalAuthToken, User, Username};
use crate::error::{CoreError, CoreResult};
use crate::repo::{LocalAuthRepository, UserRepository};

pub const TOKEN_TTL: Duration = Duration::days(30);

pub struct AuthService {
    users: Arc<dyn UserRepository>,
    local: Arc<dyn LocalAuthRepository>,
    /// argon2id hash of "unused", pre-computed at construction so the
    /// "username unknown" branch runs the same verify cost as the
    /// "wrong password" branch. Constant-time-equivalent timing.
    dummy_hash: String,
}

impl AuthService {
    pub fn new(users: Arc<dyn UserRepository>, local: Arc<dyn LocalAuthRepository>) -> Self {
        let dummy_hash = hash_password("unused").expect("argon2 default must succeed");
        Self { users, local, dummy_hash }
    }

    pub async fn login(&self, username_raw: &str, password: &str) -> Result<LocalAuthToken, AuthError> {
        let username = match Username::parse(username_raw) {
            Some(u) => u,
            None => {
                // Timing parity: run the verify cost even for malformed usernames.
                verify_password(password, &self.dummy_hash);
                return Err(AuthError::Invalid);
            }
        };

        let cred = self
            .local
            .find_by_username(&username)
            .await
            .map_err(|e| AuthError::Upstream(format!("local-auth db: {e}")))?;

        let cred = match cred {
            Some(c) => c,
            None => {
                verify_password(password, &self.dummy_hash);
                return Err(AuthError::Invalid);
            }
        };

        if !verify_password(password, &cred.password_hash) {
            return Err(AuthError::Invalid);
        }

        let raw_token = mint_raw_token();
        let token_hash = sha256_hex(&raw_token);
        let expires_at = Utc::now() + TOKEN_TTL;

        self.local
            .insert_token(&token_hash, cred.user_id, expires_at)
            .await
            .map_err(|e| AuthError::Upstream(format!("local-auth db: {e}")))?;

        Ok(LocalAuthToken {
            raw: raw_token,
            user_id: cred.user_id,
            expires_at,
        })
    }

    pub async fn verify_token(&self, raw: &str) -> Result<User, AuthError> {
        let token_hash = sha256_hex(raw);
        let new_expires_at = Utc::now() + TOKEN_TTL;

        let user_id = self
            .local
            .touch_token(&token_hash, new_expires_at)
            .await
            .map_err(|e| AuthError::Upstream(format!("local-auth db: {e}")))?;

        let user_id = match user_id {
            Some(id) => id,
            None => return Err(AuthError::Invalid),
        };

        self.users
            .find_by_id(user_id)
            .await
            .map_err(|e| AuthError::Upstream(format!("local-auth db: {e}")))?
            .ok_or(AuthError::Invalid)
    }

    pub async fn seed_credential(
        &self,
        user_id: Uuid,
        username_raw: &str,
        password: &str,
    ) -> CoreResult<()> {
        let username = Username::parse(username_raw)
            .ok_or_else(|| CoreError::Validation("invalid username".into()))?;

        let hash = hash_password(password)
            .map_err(|e| CoreError::internal(format!("hash: {e}")))?;

        self.local.upsert_credential(user_id, &username, &hash).await?;

        Ok(())
    }
}

fn hash_password(plain: &str) -> Result<String, argon2::password_hash::Error> {
    let salt = SaltString::generate(&mut OsRng);
    Ok(Argon2::default()
        .hash_password(plain.as_bytes(), &salt)?
        .to_string())
}

fn verify_password(plain: &str, encoded: &str) -> bool {
    let hash = match PasswordHash::new(encoded) {
        Ok(h) => h,
        Err(_) => return false,
    };
    Argon2::default().verify_password(plain.as_bytes(), &hash).is_ok()
}

fn mint_raw_token() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn sha256_hex(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    digest.iter().map(|b| format!("{:02x}", b)).collect()
}
