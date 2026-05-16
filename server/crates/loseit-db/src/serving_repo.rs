use async_trait::async_trait;
use chrono::{DateTime, Utc};
use loseit_core::domain::{Serving, ServingDraft, ServingPatch, ServingSource};
use loseit_core::repo::ServingRepository;
use loseit_core::{CoreError, CoreResult};
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgServingRepository {
    pool: PgPool,
}

impl PgServingRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct ServingRow {
    id: Uuid,
    food_id: Uuid,
    label: String,
    grams: Decimal,
    is_default: bool,
    // Stored as TEXT with a CHECK constraint in the DB; we keep it as
    // String here and convert through `ServingSource::parse` so the
    // domain enum stays the single source of truth.
    source: String,
    sort_order: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<ServingRow> for Serving {
    fn from(row: ServingRow) -> Self {
        // The CHECK constraint guarantees the string is one of the three
        // valid variants. If it isn't (e.g., a migration drift), fall back
        // to `System` rather than panicking — the row is still useful.
        let source = ServingSource::parse(&row.source).unwrap_or(ServingSource::System);
        Serving {
            id: row.id,
            food_id: row.food_id,
            label: row.label,
            grams: row.grams,
            is_default: row.is_default,
            source,
            sort_order: row.sort_order,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

const SELECT_COLS: &str = "id, food_id, label, grams, is_default, source, \
    sort_order, created_at, updated_at";

#[async_trait]
impl ServingRepository for PgServingRepository {
    async fn list_for_food(&self, food_id: Uuid) -> CoreResult<Vec<Serving>> {
        let sql = format!(
            "SELECT {SELECT_COLS} FROM servings \
             WHERE food_id = $1 \
             ORDER BY sort_order ASC, label ASC"
        );
        let rows: Vec<ServingRow> = sqlx::query_as(&sql)
            .bind(food_id)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn find_by_id(&self, id: Uuid) -> CoreResult<Option<Serving>> {
        let sql = format!("SELECT {SELECT_COLS} FROM servings WHERE id = $1");
        let row: Option<ServingRow> = sqlx::query_as(&sql)
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn create(&self, food_id: Uuid, draft: &ServingDraft) -> CoreResult<Serving> {
        let sql = format!(
            "INSERT INTO servings \
                (food_id, label, grams, is_default, source, sort_order) \
             VALUES ($1, $2, $3, $4, $5, $6) \
             RETURNING {SELECT_COLS}"
        );
        let row: ServingRow = sqlx::query_as(&sql)
            .bind(food_id)
            .bind(&draft.label)
            .bind(draft.grams)
            .bind(draft.is_default)
            .bind(draft.source.as_str())
            .bind(draft.sort_order)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn update(&self, id: Uuid, patch: &ServingPatch) -> CoreResult<Serving> {
        // `is_default` is intentionally absent from the patch: flipping the
        // default is an atomic operation handled by `set_default` so the
        // partial unique index invariant always holds.
        let sql = format!(
            "UPDATE servings SET \
                label      = COALESCE($2, label), \
                grams      = COALESCE($3, grams), \
                sort_order = COALESCE($4, sort_order) \
             WHERE id = $1 \
             RETURNING {SELECT_COLS}"
        );
        let row: ServingRow = sqlx::query_as(&sql)
            .bind(id)
            .bind(patch.label.as_deref())
            .bind(patch.grams)
            .bind(patch.sort_order)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn set_default(&self, food_id: Uuid, serving_id: Uuid) -> CoreResult<()> {
        // Single transaction: clear the existing default, then flip the
        // chosen row on. The schema's partial unique index requires this
        // ordering — flipping the new one on first would briefly produce
        // two defaults and abort.
        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;

        sqlx::query(
            "UPDATE servings SET is_default = false \
             WHERE food_id = $1 AND is_default = true",
        )
        .bind(food_id)
        .execute(&mut *tx)
        .await
        .map_err(map_sqlx)?;

        let res = sqlx::query(
            "UPDATE servings SET is_default = true \
             WHERE id = $1 AND food_id = $2",
        )
        .bind(serving_id)
        .bind(food_id)
        .execute(&mut *tx)
        .await
        .map_err(map_sqlx)?;

        if res.rows_affected() == 0 {
            // No commit: dropping `tx` rolls back the earlier UPDATE so we
            // don't leave the food without a default.
            return Err(CoreError::NotFound);
        }

        tx.commit().await.map_err(map_sqlx)?;
        Ok(())
    }

    async fn delete(&self, id: Uuid) -> CoreResult<()> {
        // Two-step so the caller distinguishes "doesn't exist" (404) from
        // "exists but is the default" (409). A single DELETE … WHERE
        // is_default = false RETURNING can't disambiguate the two.
        let row: Option<(bool,)> = sqlx::query_as("SELECT is_default FROM servings WHERE id = $1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;

        let is_default = match row {
            Some((flag,)) => flag,
            None => return Err(CoreError::NotFound),
        };

        if is_default {
            return Err(CoreError::Conflict(
                "cannot delete the default serving".to_string(),
            ));
        }

        let result = sqlx::query("DELETE FROM servings WHERE id = $1")
            .bind(id)
            .execute(&self.pool)
            .await
            .map_err(map_sqlx)?;
        if result.rows_affected() == 0 {
            // Race: row was removed between the SELECT and the DELETE.
            return Err(CoreError::NotFound);
        }
        Ok(())
    }
}
