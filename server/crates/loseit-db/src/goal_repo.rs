use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use loseit_core::domain::{Goal, GoalDraft, GoalPatch};
use loseit_core::repo::GoalRepository;
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgGoalRepository {
    pool: PgPool,
}

impl PgGoalRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[derive(sqlx::FromRow)]
struct GoalRow {
    id: Uuid,
    user_id: Uuid,
    starts_on: NaiveDate,
    ends_on: Option<NaiveDate>,
    start_weight_kg: Option<Decimal>,
    target_weight_kg: Option<Decimal>,
    weekly_rate_kg: Option<Decimal>,
    daily_calorie_target: Option<i32>,
    protein_g_target: Option<Decimal>,
    carbs_g_target: Option<Decimal>,
    fat_g_target: Option<Decimal>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<GoalRow> for Goal {
    fn from(r: GoalRow) -> Self {
        Goal {
            id: r.id,
            user_id: r.user_id,
            starts_on: r.starts_on,
            ends_on: r.ends_on,
            start_weight_kg: r.start_weight_kg,
            target_weight_kg: r.target_weight_kg,
            weekly_rate_kg: r.weekly_rate_kg,
            daily_calorie_target: r.daily_calorie_target,
            protein_g_target: r.protein_g_target,
            carbs_g_target: r.carbs_g_target,
            fat_g_target: r.fat_g_target,
            created_at: r.created_at,
            updated_at: r.updated_at,
        }
    }
}

const SELECT_COLS: &str = "id, user_id, starts_on, ends_on, start_weight_kg, \
    target_weight_kg, weekly_rate_kg, daily_calorie_target, protein_g_target, \
    carbs_g_target, fat_g_target, created_at, updated_at";

#[async_trait]
impl GoalRepository for PgGoalRepository {
    async fn create(&self, user_id: Uuid, draft: &GoalDraft) -> CoreResult<Goal> {
        let row: GoalRow = sqlx::query_as(&insert_sql())
            .bind(user_id)
            .bind(draft.starts_on)
            .bind(draft.ends_on)
            .bind(draft.start_weight_kg)
            .bind(draft.target_weight_kg)
            .bind(draft.weekly_rate_kg)
            .bind(draft.daily_calorie_target)
            .bind(draft.protein_g_target)
            .bind(draft.carbs_g_target)
            .bind(draft.fat_g_target)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn create_succeeding(
        &self,
        user_id: Uuid,
        closes_on: NaiveDate,
        draft: &GoalDraft,
    ) -> CoreResult<Goal> {
        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;

        sqlx::query(
            "UPDATE goals SET ends_on = $2 \
             WHERE user_id = $1 AND ends_on IS NULL",
        )
        .bind(user_id)
        .bind(closes_on)
        .execute(&mut *tx)
        .await
        .map_err(map_sqlx)?;

        let row: GoalRow = sqlx::query_as(&insert_sql())
            .bind(user_id)
            .bind(draft.starts_on)
            .bind(draft.ends_on)
            .bind(draft.start_weight_kg)
            .bind(draft.target_weight_kg)
            .bind(draft.weekly_rate_kg)
            .bind(draft.daily_calorie_target)
            .bind(draft.protein_g_target)
            .bind(draft.carbs_g_target)
            .bind(draft.fat_g_target)
            .fetch_one(&mut *tx)
            .await
            .map_err(map_sqlx)?;

        tx.commit().await.map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn list_for_user(&self, user_id: Uuid) -> CoreResult<Vec<Goal>> {
        let sql = format!(
            "SELECT {SELECT_COLS} FROM goals \
             WHERE user_id = $1 ORDER BY starts_on DESC"
        );
        let rows: Vec<GoalRow> = sqlx::query_as(&sql)
            .bind(user_id)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn find_active_on(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Option<Goal>> {
        let sql = format!(
            "SELECT {SELECT_COLS} FROM goals \
             WHERE user_id = $1 \
               AND starts_on <= $2 \
               AND (ends_on IS NULL OR ends_on >= $2) \
             ORDER BY starts_on DESC \
             LIMIT 1"
        );
        let row: Option<GoalRow> = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(on)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn update(&self, user_id: Uuid, id: Uuid, patch: &GoalPatch) -> CoreResult<Goal> {
        let sql = format!(
            "UPDATE goals SET \
                starts_on            = COALESCE($3, starts_on), \
                ends_on              = COALESCE($4, ends_on), \
                start_weight_kg      = COALESCE($5, start_weight_kg), \
                target_weight_kg     = COALESCE($6, target_weight_kg), \
                weekly_rate_kg       = COALESCE($7, weekly_rate_kg), \
                daily_calorie_target = COALESCE($8, daily_calorie_target), \
                protein_g_target     = COALESCE($9, protein_g_target), \
                carbs_g_target       = COALESCE($10, carbs_g_target), \
                fat_g_target         = COALESCE($11, fat_g_target) \
             WHERE id = $1 AND user_id = $2 \
             RETURNING {SELECT_COLS}"
        );
        let row: GoalRow = sqlx::query_as(&sql)
            .bind(id)
            .bind(user_id)
            .bind(patch.starts_on)
            .bind(patch.ends_on)
            .bind(patch.start_weight_kg)
            .bind(patch.target_weight_kg)
            .bind(patch.weekly_rate_kg)
            .bind(patch.daily_calorie_target)
            .bind(patch.protein_g_target)
            .bind(patch.carbs_g_target)
            .bind(patch.fat_g_target)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        let result = sqlx::query("DELETE FROM goals WHERE id = $1 AND user_id = $2")
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

fn insert_sql() -> String {
    format!(
        "INSERT INTO goals (user_id, starts_on, ends_on, start_weight_kg, target_weight_kg, \
            weekly_rate_kg, daily_calorie_target, protein_g_target, carbs_g_target, fat_g_target) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) \
         RETURNING {SELECT_COLS}"
    )
}
