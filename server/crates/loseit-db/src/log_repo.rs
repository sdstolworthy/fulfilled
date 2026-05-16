use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use loseit_core::domain::{
    FoodLogEntry, Meal, NutritionSnapshot, PersistedLogEntry, PersistedLogPatch,
};
use loseit_core::repo::LogRepository;
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgLogRepository {
    pool: PgPool,
}

impl PgLogRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

/// Flat row mirror of the `food_log_entries` schema. The nutrition snapshot
/// is stored as discrete columns at the row level for indexability and
/// migration friendliness; we reassemble the `NutritionSnapshot` substructure
/// in the `From` impl so the domain layer sees a single cohesive value.
#[derive(sqlx::FromRow)]
struct LogEntryRow {
    id: Uuid,
    user_id: Uuid,
    food_id: Uuid,
    serving_id: Option<Uuid>,
    consumed_on: NaiveDate,
    // Stored as TEXT with a CHECK constraint; parsed through `Meal::from_str`
    // so the domain enum remains the single source of truth.
    meal: String,
    quantity: Decimal,
    grams_total: Decimal,
    calories_kcal: Decimal,
    protein_g: Option<Decimal>,
    carbs_g: Option<Decimal>,
    fat_g: Option<Decimal>,
    fiber_g: Option<Decimal>,
    sugar_g: Option<Decimal>,
    sodium_mg: Option<Decimal>,
    saturated_fat_g: Option<Decimal>,
    note: Option<String>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<LogEntryRow> for FoodLogEntry {
    fn from(row: LogEntryRow) -> Self {
        // The DB CHECK constraint guarantees `meal` is one of the four
        // valid variants. If a drift ever sneaks one through, default to
        // `Snack` rather than panicking — the entry is still useful and
        // the misclassification surfaces in the day summary.
        let meal = row.meal.parse::<Meal>().unwrap_or(Meal::Snack);
        FoodLogEntry {
            id: row.id,
            user_id: row.user_id,
            food_id: row.food_id,
            serving_id: row.serving_id,
            consumed_on: row.consumed_on,
            meal,
            quantity: row.quantity,
            grams_total: row.grams_total,
            snapshot: NutritionSnapshot {
                calories_kcal: row.calories_kcal,
                protein_g: row.protein_g,
                carbs_g: row.carbs_g,
                fat_g: row.fat_g,
                fiber_g: row.fiber_g,
                sugar_g: row.sugar_g,
                sodium_mg: row.sodium_mg,
                saturated_fat_g: row.saturated_fat_g,
            },
            note: row.note,
            created_at: row.created_at,
            updated_at: row.updated_at,
        }
    }
}

const SELECT_COLS: &str = "id, user_id, food_id, serving_id, consumed_on, meal, \
    quantity, grams_total, calories_kcal, protein_g, carbs_g, fat_g, fiber_g, \
    sugar_g, sodium_mg, saturated_fat_g, note, created_at, updated_at";

#[async_trait]
impl LogRepository for PgLogRepository {
    async fn create(&self, user_id: Uuid, entry: &PersistedLogEntry) -> CoreResult<FoodLogEntry> {
        let sql = format!(
            "INSERT INTO food_log_entries (\
                user_id, food_id, serving_id, consumed_on, meal, quantity, grams_total, \
                calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, \
                saturated_fat_g, note\
             ) VALUES (\
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16\
             ) RETURNING {SELECT_COLS}"
        );
        let row: LogEntryRow = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(entry.food_id)
            .bind(entry.serving_id)
            .bind(entry.consumed_on)
            .bind(entry.meal.as_str())
            .bind(entry.quantity)
            .bind(entry.grams_total)
            .bind(entry.snapshot.calories_kcal)
            .bind(entry.snapshot.protein_g)
            .bind(entry.snapshot.carbs_g)
            .bind(entry.snapshot.fat_g)
            .bind(entry.snapshot.fiber_g)
            .bind(entry.snapshot.sugar_g)
            .bind(entry.snapshot.sodium_mg)
            .bind(entry.snapshot.saturated_fat_g)
            .bind(entry.note.as_deref())
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn update(
        &self,
        user_id: Uuid,
        id: Uuid,
        patch: &PersistedLogPatch,
    ) -> CoreResult<FoodLogEntry> {
        // Patch shape: pass-through fields use COALESCE("set if Some, else
        // leave"). The `recompute` block is exploded into its constituent
        // numeric fields and bound the same way — `recompute = None` means
        // every numeric stays. For `note`, the `Option<Option<String>>`
        // semantics demand we tell SQL "is a new value provided?" separately
        // from the value itself, so we pass a boolean flag and use CASE.
        //
        // Caveat: for snapshot fields that are themselves nullable, COALESCE
        // with a `None` recompute value would leave the old column rather
        // than nulling it. In practice the service only triggers a recompute
        // when quantity/serving changes for the same food, so the nullable
        // pattern is stable across the rewrite. v1 accepts this trade-off
        // for the simpler SQL.
        let recompute_quantity = patch.recompute.as_ref().map(|r| r.quantity);
        let recompute_grams_total = patch.recompute.as_ref().map(|r| r.grams_total);
        let recompute_calories = patch.recompute.as_ref().map(|r| r.snapshot.calories_kcal);
        let recompute_protein = patch.recompute.as_ref().and_then(|r| r.snapshot.protein_g);
        let recompute_carbs = patch.recompute.as_ref().and_then(|r| r.snapshot.carbs_g);
        let recompute_fat = patch.recompute.as_ref().and_then(|r| r.snapshot.fat_g);
        let recompute_fiber = patch.recompute.as_ref().and_then(|r| r.snapshot.fiber_g);
        let recompute_sugar = patch.recompute.as_ref().and_then(|r| r.snapshot.sugar_g);
        let recompute_sodium = patch.recompute.as_ref().and_then(|r| r.snapshot.sodium_mg);
        let recompute_saturated = patch
            .recompute
            .as_ref()
            .and_then(|r| r.snapshot.saturated_fat_g);

        let note_provided = patch.note.is_some();
        let note_value: Option<&str> = patch.note.as_ref().and_then(|inner| inner.as_deref());

        let sql = format!(
            "UPDATE food_log_entries SET \
                serving_id      = COALESCE($3, serving_id), \
                consumed_on     = COALESCE($4, consumed_on), \
                meal            = COALESCE($5, meal), \
                quantity        = COALESCE($6, quantity), \
                grams_total     = COALESCE($7, grams_total), \
                calories_kcal   = COALESCE($8, calories_kcal), \
                protein_g       = COALESCE($9, protein_g), \
                carbs_g         = COALESCE($10, carbs_g), \
                fat_g           = COALESCE($11, fat_g), \
                fiber_g         = COALESCE($12, fiber_g), \
                sugar_g         = COALESCE($13, sugar_g), \
                sodium_mg       = COALESCE($14, sodium_mg), \
                saturated_fat_g = COALESCE($15, saturated_fat_g), \
                note            = CASE WHEN $16 THEN $17 ELSE note END \
             WHERE id = $1 AND user_id = $2 \
             RETURNING {SELECT_COLS}"
        );
        let row: LogEntryRow = sqlx::query_as(&sql)
            .bind(id)
            .bind(user_id)
            .bind(patch.serving_id)
            .bind(patch.consumed_on)
            .bind(patch.meal.map(|m| m.as_str()))
            .bind(recompute_quantity)
            .bind(recompute_grams_total)
            .bind(recompute_calories)
            .bind(recompute_protein)
            .bind(recompute_carbs)
            .bind(recompute_fat)
            .bind(recompute_fiber)
            .bind(recompute_sugar)
            .bind(recompute_sodium)
            .bind(recompute_saturated)
            .bind(note_provided)
            .bind(note_value)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        let result = sqlx::query("DELETE FROM food_log_entries WHERE id = $1 AND user_id = $2")
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

    async fn find_by_id(&self, user_id: Uuid, id: Uuid) -> CoreResult<Option<FoodLogEntry>> {
        let sql = format!(
            "SELECT {SELECT_COLS} FROM food_log_entries \
             WHERE id = $1 AND user_id = $2"
        );
        let row: Option<LogEntryRow> = sqlx::query_as(&sql)
            .bind(id)
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn list_in_range(
        &self,
        user_id: Uuid,
        from: NaiveDate,
        to: NaiveDate,
    ) -> CoreResult<Vec<FoodLogEntry>> {
        let sql = format!(
            "SELECT {SELECT_COLS} FROM food_log_entries \
             WHERE user_id = $1 AND consumed_on >= $2 AND consumed_on <= $3 \
             ORDER BY consumed_on DESC, created_at DESC"
        );
        let rows: Vec<LogEntryRow> = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(from)
            .bind(to)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn list_for_day(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Vec<FoodLogEntry>> {
        // ORDER BY meal then created_at so the day summary can stream
        // entries in meal-grouped, chronological order without resorting.
        let sql = format!(
            "SELECT {SELECT_COLS} FROM food_log_entries \
             WHERE user_id = $1 AND consumed_on = $2 \
             ORDER BY meal, created_at"
        );
        let rows: Vec<LogEntryRow> = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(on)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn recent_food_ids(&self, user_id: Uuid, limit: i64) -> CoreResult<Vec<Uuid>> {
        // GROUP BY + MAX(created_at) collapses repeat logs of the same food
        // into a single "most recent" entry per food_id, which is what the
        // suggestions service wants.
        let rows: Vec<(Uuid,)> = sqlx::query_as(
            "SELECT food_id FROM food_log_entries \
             WHERE user_id = $1 \
             GROUP BY food_id \
             ORDER BY MAX(created_at) DESC \
             LIMIT $2",
        )
        .bind(user_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(|(id,)| id).collect())
    }

    async fn frequent_food_ids(
        &self,
        user_id: Uuid,
        window_days: i64,
        limit: i64,
    ) -> CoreResult<Vec<(Uuid, i64)>> {
        // The interval math is done in SQL (`CURRENT_DATE - (N * '1 day'::interval)`)
        // so the database's clock is the single source of truth for "today".
        // The `::int` cast is required because we bind `window_days` as i32
        // — Postgres won't multiply an interval by a bigint without help.
        let window_days_i32 = i32::try_from(window_days).unwrap_or(i32::MAX);
        let rows: Vec<(Uuid, i64)> = sqlx::query_as(
            "SELECT food_id, COUNT(*) AS cnt \
               FROM food_log_entries \
              WHERE user_id = $1 \
                AND consumed_on >= (CURRENT_DATE - ($2::int * INTERVAL '1 day'))::date \
              GROUP BY food_id \
              ORDER BY cnt DESC, MAX(created_at) DESC \
              LIMIT $3",
        )
        .bind(user_id)
        .bind(window_days_i32)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(rows)
    }

    async fn any_entry_references_food(&self, food_id: Uuid) -> CoreResult<bool> {
        // EXISTS short-circuits at the first matching row; the food service
        // calls this before attempting a delete to surface a clean 409.
        let found: bool = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM food_log_entries WHERE food_id = $1)",
        )
        .bind(food_id)
        .fetch_one(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(found)
    }
}
