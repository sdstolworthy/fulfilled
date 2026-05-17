use async_trait::async_trait;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use loseit_core::error::CoreResult;
use loseit_core::repo::{HandoffClaim, OidcHandoffRepository};

use crate::error::map_sqlx;

pub struct PgOidcHandoffRepository {
    pool: PgPool,
}

impl PgOidcHandoffRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct HandoffRow {
    user_id: Uuid,
    raw_token: String,
    token_expires_at: DateTime<Utc>,
}

impl From<HandoffRow> for HandoffClaim {
    fn from(row: HandoffRow) -> Self {
        Self {
            user_id: row.user_id,
            raw_token: row.raw_token,
            token_expires_at: row.token_expires_at,
        }
    }
}

#[async_trait]
impl OidcHandoffRepository for PgOidcHandoffRepository {
    async fn insert(
        &self,
        code_hash: &str,
        user_id: Uuid,
        raw_token: &str,
        token_expires_at: DateTime<Utc>,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        sqlx::query(
            "INSERT INTO oidc_handoff_codes (code_hash, user_id, raw_token, token_expires_at, expires_at) \
             VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(code_hash)
        .bind(user_id)
        .bind(raw_token)
        .bind(token_expires_at)
        .bind(expires_at)
        .execute(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(())
    }

    async fn claim(&self, code_hash: &str) -> CoreResult<Option<HandoffClaim>> {
        let row: Option<HandoffRow> = sqlx::query_as(
            "DELETE FROM oidc_handoff_codes \
             WHERE code_hash = $1 AND expires_at > now() \
             RETURNING user_id, raw_token, token_expires_at",
        )
        .bind(code_hash)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }
}
