use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use loseit_core::domain::{ActivityLevel, ProfilePatch, Sex, User, UserIdentity};
use loseit_core::repo::UserRepository;
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgUserRepository {
    pool: PgPool,
}

impl PgUserRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct UserRow {
    id: Uuid,
    issuer: String,
    external_id: String,
    email: Option<String>,
    display_name: Option<String>,
    sex: Option<String>,
    birth_date: Option<NaiveDate>,
    height_cm: Option<Decimal>,
    activity_level: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<UserRow> for User {
    fn from(row: UserRow) -> Self {
        User {
            id: row.id,
            identity: UserIdentity {
                issuer: row.issuer,
                external_id: row.external_id,
                email: row.email,
                display_name: row.display_name,
            },
            sex: row.sex.as_deref().and_then(Sex::parse),
            birth_date: row.birth_date,
            height_cm: row.height_cm,
            activity_level: row.activity_level.as_deref().and_then(ActivityLevel::parse),
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

const SELECT_USER_COLUMNS: &str = "id, issuer, external_id, email, display_name, sex, \
    birth_date, height_cm, activity_level, created_at, updated_at";

#[async_trait]
impl UserRepository for PgUserRepository {
    async fn find_by_id(&self, id: Uuid) -> CoreResult<Option<User>> {
        let sql = format!("SELECT {SELECT_USER_COLUMNS} FROM users WHERE id = $1");
        let row: Option<UserRow> = sqlx::query_as(&sql)
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn find_by_identity(&self, identity: &UserIdentity) -> CoreResult<Option<User>> {
        let sql = format!(
            "SELECT {SELECT_USER_COLUMNS} FROM users \
             WHERE issuer = $1 AND external_id = $2"
        );
        let row: Option<UserRow> = sqlx::query_as(&sql)
            .bind(&identity.issuer)
            .bind(&identity.external_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn create(&self, identity: &UserIdentity) -> CoreResult<User> {
        let sql = format!(
            "INSERT INTO users (issuer, external_id, email, display_name) \
             VALUES ($1, $2, $3, $4) \
             RETURNING {SELECT_USER_COLUMNS}"
        );
        let row: UserRow = sqlx::query_as(&sql)
            .bind(&identity.issuer)
            .bind(&identity.external_id)
            .bind(identity.email.as_deref())
            .bind(identity.display_name.as_deref())
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn update_profile(&self, id: Uuid, patch: &ProfilePatch) -> CoreResult<User> {
        // COALESCE($n, column) means "set if provided, otherwise leave."
        // This keeps the patch idempotent without per-field SQL branches.
        let sql = format!(
            "UPDATE users SET \
                email          = COALESCE($2, email), \
                display_name   = COALESCE($3, display_name), \
                sex            = COALESCE($4, sex), \
                birth_date     = COALESCE($5, birth_date), \
                height_cm      = COALESCE($6, height_cm), \
                activity_level = COALESCE($7, activity_level) \
             WHERE id = $1 \
             RETURNING {SELECT_USER_COLUMNS}"
        );
        let row: UserRow = sqlx::query_as(&sql)
            .bind(id)
            .bind(patch.email.as_deref())
            .bind(patch.display_name.as_deref())
            .bind(patch.sex.map(|s| s.as_str()))
            .bind(patch.birth_date)
            .bind(patch.height_cm)
            .bind(patch.activity_level.map(|a| a.as_str()))
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn delete_user(&self, user_id: Uuid) -> CoreResult<()> {
        // Single transaction — order matters because food_log_entries.food_id
        // is ON DELETE RESTRICT, so log entries must be removed before
        // user-owned foods. export_jobs.user_id is ON DELETE CASCADE, so it
        // would be cleaned up automatically when the users row drops, but we
        // delete it explicitly to make the cascade order unambiguous.
        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;

        sqlx::query("DELETE FROM food_log_entries WHERE user_id = $1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(map_sqlx)?;

        sqlx::query("DELETE FROM weights WHERE user_id = $1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(map_sqlx)?;

        sqlx::query("DELETE FROM goals WHERE user_id = $1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(map_sqlx)?;

        sqlx::query("DELETE FROM foods WHERE owner_user_id = $1 AND source = 'user'")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(map_sqlx)?;

        sqlx::query("DELETE FROM export_jobs WHERE user_id = $1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(map_sqlx)?;

        sqlx::query("DELETE FROM users WHERE id = $1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(map_sqlx)?;

        tx.commit().await.map_err(map_sqlx)?;
        Ok(())
    }
}
