use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use loseit_core::domain::{Weight, WeightDraft};
use loseit_core::repo::WeightRepository;
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgWeightRepository {
    pool: PgPool,
}

impl PgWeightRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct WeightRow {
    id: Uuid,
    user_id: Uuid,
    recorded_on: NaiveDate,
    recorded_at_local: Option<NaiveTime>,
    weight_kg: Decimal,
    note: Option<String>,
    created_at: DateTime<Utc>,
}

impl From<WeightRow> for Weight {
    fn from(row: WeightRow) -> Self {
        Weight {
            id: row.id,
            user_id: row.user_id,
            recorded_on: row.recorded_on,
            recorded_at_local: row.recorded_at_local,
            weight_kg: row.weight_kg,
            note: row.note,
            created_at: row.created_at,
        }
    }
}

const SELECT_COLS: &str =
    "id, user_id, recorded_on, recorded_at_local, weight_kg, note, created_at";

#[async_trait]
impl WeightRepository for PgWeightRepository {
    async fn create(&self, user_id: Uuid, draft: &WeightDraft) -> CoreResult<Weight> {
        let sql = format!(
            "INSERT INTO weights (user_id, recorded_on, recorded_at_local, weight_kg, note) \
             VALUES ($1, $2, $3, $4, $5) \
             RETURNING {SELECT_COLS}"
        );
        let row: WeightRow = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(draft.recorded_on)
            .bind(draft.recorded_at_local)
            .bind(draft.weight_kg)
            .bind(draft.note.as_deref())
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn list_for_user(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<Vec<Weight>> {
        let sql = format!(
            "SELECT {SELECT_COLS} FROM weights \
             WHERE user_id = $1 \
               AND ($2::date IS NULL OR recorded_on >= $2) \
               AND ($3::date IS NULL OR recorded_on <= $3) \
             ORDER BY recorded_on DESC, created_at DESC"
        );
        let rows: Vec<WeightRow> = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(from)
            .bind(to)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        let result = sqlx::query("DELETE FROM weights WHERE id = $1 AND user_id = $2")
            .bind(id)
            .bind(user_id)
            .execute(&self.pool)
            .await
            .map_err(map_sqlx)?;
        if result.rows_affected() == 0 {
            return Err(loseit_core::CoreError::NotFound);
        }
        Ok(())
    }
}
