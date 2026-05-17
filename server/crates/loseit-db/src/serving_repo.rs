use async_trait::async_trait;
use chrono::{DateTime, Utc};
use loseit_core::domain::{Serving, ServingDraft, ServingPatch, ServingSource};
use loseit_core::domain::unit::Unit;
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
    label: Option<String>,
    amount: Decimal,
    // Stored as TEXT with a CHECK constraint in the DB; we keep it as
    // String here and convert through `Unit::parse` so the domain enum
    // stays the single source of truth.
    unit: String,
    kcal: Decimal,
    protein_g: Option<Decimal>,
    carbs_g: Option<Decimal>,
    fat_g: Option<Decimal>,
    fiber_g: Option<Decimal>,
    sugar_g: Option<Decimal>,
    sodium_mg: Option<Decimal>,
    saturated_fat_g: Option<Decimal>,
    is_default: bool,
    // Stored as TEXT with a CHECK constraint; convert via ServingSource::parse.
    source: String,
    sort_order: i32,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<ServingRow> for Serving {
    fn from(row: ServingRow) -> Self {
        // DB CHECK constraint guarantees the string is a valid unit variant.
        let unit = Unit::parse(&row.unit)
            .expect("DB CHECK ensures unit invariant");
        // DB CHECK constraint guarantees the string is a valid source variant.
        let source = ServingSource::parse(&row.source).unwrap_or(ServingSource::System);
        Serving {
            id: row.id,
            food_id: row.food_id,
            label: row.label,
            amount: row.amount,
            unit,
            kcal: row.kcal,
            protein_g: row.protein_g,
            carbs_g: row.carbs_g,
            fat_g: row.fat_g,
            fiber_g: row.fiber_g,
            sugar_g: row.sugar_g,
            sodium_mg: row.sodium_mg,
            saturated_fat_g: row.saturated_fat_g,
            is_default: row.is_default,
            source,
            sort_order: row.sort_order,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

const SELECT_COLS: &str =
    "id, food_id, label, amount, unit, kcal, protein_g, carbs_g, fat_g, \
     fiber_g, sugar_g, sodium_mg, saturated_fat_g, is_default, source, \
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
                (food_id, label, amount, unit, kcal, protein_g, carbs_g, fat_g, \
                 fiber_g, sugar_g, sodium_mg, saturated_fat_g, is_default, source, sort_order) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15) \
             RETURNING {SELECT_COLS}"
        );
        let row: ServingRow = sqlx::query_as(&sql)
            .bind(food_id)
            .bind(&draft.label)
            .bind(draft.amount)
            .bind(draft.unit.as_str())
            .bind(draft.kcal)
            .bind(draft.protein_g)
            .bind(draft.carbs_g)
            .bind(draft.fat_g)
            .bind(draft.fiber_g)
            .bind(draft.sugar_g)
            .bind(draft.sodium_mg)
            .bind(draft.saturated_fat_g)
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
        //
        // Double-Option fields (nullable patch): outer None = don't touch,
        // inner None = set to NULL. We can't use COALESCE for those because
        // COALESCE($n, col) can't distinguish "caller passed NULL to clear the
        // field" from "caller passed no value". Instead we use the pattern:
        //   col = CASE WHEN $n_flag THEN $n_value ELSE col END
        // where $n_flag is a bool bound from patch.field.is_some().
        let sql = format!(
            "UPDATE servings SET \
                label           = CASE WHEN $2  THEN $3  ELSE label           END, \
                amount          = COALESCE($4,  amount), \
                unit            = COALESCE($5,  unit), \
                kcal            = COALESCE($6,  kcal), \
                protein_g       = CASE WHEN $7  THEN $8  ELSE protein_g       END, \
                carbs_g         = CASE WHEN $9  THEN $10 ELSE carbs_g         END, \
                fat_g           = CASE WHEN $11 THEN $12 ELSE fat_g           END, \
                fiber_g         = CASE WHEN $13 THEN $14 ELSE fiber_g         END, \
                sugar_g         = CASE WHEN $15 THEN $16 ELSE sugar_g         END, \
                sodium_mg       = CASE WHEN $17 THEN $18 ELSE sodium_mg       END, \
                saturated_fat_g = CASE WHEN $19 THEN $20 ELSE saturated_fat_g END, \
                sort_order      = COALESCE($21, sort_order) \
             WHERE id = $1 \
             RETURNING {SELECT_COLS}"
        );
        let row: ServingRow = sqlx::query_as(&sql)
            .bind(id)
            // label: double-Option nullable patch
            .bind(patch.label.is_some())
            .bind(patch.label.as_ref().and_then(|o| o.as_deref()))
            // amount, unit, kcal: simple COALESCE
            .bind(patch.amount)
            .bind(patch.unit.map(|u| u.as_str()))
            .bind(patch.kcal)
            // nullable macro fields
            .bind(patch.protein_g.is_some())
            .bind(patch.protein_g.flatten())
            .bind(patch.carbs_g.is_some())
            .bind(patch.carbs_g.flatten())
            .bind(patch.fat_g.is_some())
            .bind(patch.fat_g.flatten())
            .bind(patch.fiber_g.is_some())
            .bind(patch.fiber_g.flatten())
            .bind(patch.sugar_g.is_some())
            .bind(patch.sugar_g.flatten())
            .bind(patch.sodium_mg.is_some())
            .bind(patch.sodium_mg.flatten())
            .bind(patch.saturated_fat_g.is_some())
            .bind(patch.saturated_fat_g.flatten())
            // sort_order: simple COALESCE
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
