use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use loseit_core::domain::{LocalAuthCredential, Username};
use loseit_core::repo::LocalAuthRepository;
use loseit_core::CoreResult;

use crate::error::map_sqlx;

pub struct PgLocalAuthRepository {
    pool: PgPool,
}

impl PgLocalAuthRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct CredRow {
    user_id: Uuid,
    username: String,
    password_hash: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<CredRow> for LocalAuthCredential {
    fn from(row: CredRow) -> Self {
        Self {
            user_id: row.user_id,
            username: Username::parse(&row.username)
                .expect("DB CHECK ensures username invariants"),
            password_hash: row.password_hash,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

const SELECT_CRED_COLUMNS: &str =
    "user_id, username, password_hash, created_at, updated_at";

#[async_trait]
impl LocalAuthRepository for PgLocalAuthRepository {
    async fn find_by_username(
        &self,
        username: &Username,
    ) -> CoreResult<Option<LocalAuthCredential>> {
        let sql = format!(
            "SELECT {SELECT_CRED_COLUMNS} FROM users_local_auth WHERE username = $1"
        );
        let row: Option<CredRow> = sqlx::query_as(&sql)
            .bind(username.as_str())
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn upsert_credential(
        &self,
        user_id: Uuid,
        username: &Username,
        password_hash: &str,
    ) -> CoreResult<LocalAuthCredential> {
        let sql = format!(
            "INSERT INTO users_local_auth (user_id, username, password_hash) \
             VALUES ($1, $2, $3) \
             ON CONFLICT (user_id) DO UPDATE SET \
                 username = EXCLUDED.username, \
                 password_hash = EXCLUDED.password_hash, \
                 updated_at = now() \
             RETURNING {SELECT_CRED_COLUMNS}"
        );
        let row: CredRow = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(username.as_str())
            .bind(password_hash)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn insert_token(
        &self,
        token_hash: &str,
        user_id: Uuid,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        sqlx::query(
            "INSERT INTO local_auth_tokens (token_hash, user_id, expires_at) \
             VALUES ($1, $2, $3)",
        )
        .bind(token_hash)
        .bind(user_id)
        .bind(expires_at)
        .execute(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(())
    }

    async fn touch_token(
        &self,
        token_hash: &str,
        new_expires_at: DateTime<Utc>,
    ) -> CoreResult<Option<Uuid>> {
        let user_id: Option<Uuid> = sqlx::query_scalar(
            "UPDATE local_auth_tokens \
             SET last_seen_at = now(), \
                 expires_at = greatest(expires_at, $2) \
             WHERE token_hash = $1 AND expires_at > now() \
             RETURNING user_id",
        )
        .bind(token_hash)
        .bind(new_expires_at)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(user_id)
    }

    async fn delete_token(&self, token_hash: &str) -> CoreResult<()> {
        sqlx::query("DELETE FROM local_auth_tokens WHERE token_hash = $1")
            .bind(token_hash)
            .execute(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(())
    }
}
