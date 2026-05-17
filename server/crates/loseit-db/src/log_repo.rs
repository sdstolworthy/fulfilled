use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use loseit_core::domain::{
    FoodLogEntry, Meal, NutritionSnapshot, PersistedLogEntry, PersistedLogPatch,
};
use loseit_core::repo::food::QUICK_ADD_SENTINEL_NAME;
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
    food_name: String,
    serving_name: Option<String>,
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
            food_name: row.food_name,
            serving_name: row.serving_name,
        }
    }
}

const SELECT_COLS: &str = "\
    le.id, le.user_id, le.food_id, le.serving_id, le.consumed_on, le.meal, \
    le.quantity, le.grams_total, le.calories_kcal, le.protein_g, le.carbs_g, le.fat_g, \
    le.fiber_g, le.sugar_g, le.sodium_mg, le.saturated_fat_g, le.note, \
    le.created_at, le.updated_at, \
    COALESCE(f.name, '') AS food_name, \
    s.label AS serving_name";

const FROM_CLAUSE: &str = "\
    food_log_entries le \
    LEFT JOIN foods    f ON f.id = le.food_id \
    LEFT JOIN servings s ON s.id = le.serving_id";

#[async_trait]
impl LogRepository for PgLogRepository {
    async fn create(&self, user_id: Uuid, entry: &PersistedLogEntry) -> CoreResult<FoodLogEntry> {
        let id: Uuid = sqlx::query_scalar(
            "INSERT INTO food_log_entries (\
                user_id, food_id, serving_id, consumed_on, meal, quantity, grams_total, \
                calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, \
                saturated_fat_g, note\
             ) VALUES (\
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16\
             ) RETURNING id",
        )
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
        self.find_by_id(user_id, id)
            .await?
            .ok_or(loseit_core::CoreError::NotFound)
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

        let updated_id: Uuid = sqlx::query_scalar(
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
             RETURNING id",
        )
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
        self.find_by_id(user_id, updated_id)
            .await?
            .ok_or(loseit_core::CoreError::NotFound)
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
            "SELECT {SELECT_COLS} FROM {FROM_CLAUSE} \
             WHERE le.id = $1 AND le.user_id = $2"
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
            "SELECT {SELECT_COLS} FROM {FROM_CLAUSE} \
             WHERE le.user_id = $1 AND le.consumed_on >= $2 AND le.consumed_on <= $3 \
             ORDER BY le.consumed_on DESC, le.created_at DESC"
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
            "SELECT {SELECT_COLS} FROM {FROM_CLAUSE} \
             WHERE le.user_id = $1 AND le.consumed_on = $2 \
             ORDER BY le.meal, le.created_at"
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
        //
        // The inner JOIN to `foods` + `name <> '__quick_add__'` filter hides
        // the per-user sentinel from the recents list even when the user has
        // logged calories via /log/quick_add.
        let sql = format!(
            "SELECT e.food_id FROM food_log_entries e \
             JOIN foods f ON f.id = e.food_id \
             WHERE e.user_id = $1 \
               AND f.name <> '{sentinel}' \
             GROUP BY e.food_id \
             ORDER BY MAX(e.created_at) DESC \
             LIMIT $2",
            sentinel = QUICK_ADD_SENTINEL_NAME
        );
        let rows: Vec<(Uuid,)> = sqlx::query_as(&sql)
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
        //
        // Same sentinel exclusion as `recent_food_ids` — joined via foods.
        let window_days_i32 = i32::try_from(window_days).unwrap_or(i32::MAX);
        let sql = format!(
            "SELECT e.food_id, COUNT(*) AS cnt \
               FROM food_log_entries e \
               JOIN foods f ON f.id = e.food_id \
              WHERE e.user_id = $1 \
                AND e.consumed_on >= (CURRENT_DATE - ($2::int * INTERVAL '1 day'))::date \
                AND f.name <> '{sentinel}' \
              GROUP BY e.food_id \
              ORDER BY cnt DESC, MAX(e.created_at) DESC \
              LIMIT $3",
            sentinel = QUICK_ADD_SENTINEL_NAME
        );
        let rows: Vec<(Uuid, i64)> = sqlx::query_as(&sql)
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

    async fn list_paginated(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodLogEntry>> {
        // The `$2::date IS NULL OR consumed_on >= $2` pattern lets the Postgres
        // planner skip the date filter entirely when `from`/`to` are NULL while
        // still hitting `log_user_date_idx` on the `user_id` prefix.
        let sql = format!(
            "SELECT {SELECT_COLS} FROM {FROM_CLAUSE} \
             WHERE le.user_id = $1 \
               AND ($2::date IS NULL OR le.consumed_on >= $2) \
               AND ($3::date IS NULL OR le.consumed_on <= $3) \
             ORDER BY le.consumed_on DESC, le.created_at DESC, le.id DESC \
             LIMIT $4 OFFSET $5"
        );
        let rows: Vec<LogEntryRow> = sqlx::query_as(&sql)
            .bind(user_id)
            .bind(from)
            .bind(to)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    async fn count_in_range(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<i64> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*)::BIGINT FROM food_log_entries \
             WHERE user_id = $1 \
               AND ($2::date IS NULL OR consumed_on >= $2) \
               AND ($3::date IS NULL OR consumed_on <= $3)",
        )
        .bind(user_id)
        .bind(from)
        .bind(to)
        .fetch_one(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(count)
    }

    async fn create_many(
        &self,
        user_id: Uuid,
        entries: &[PersistedLogEntry],
    ) -> CoreResult<Vec<FoodLogEntry>> {
        if entries.is_empty() {
            return Ok(vec![]);
        }

        // Pack each per-column slice for the UNNEST call. nullable columns use
        // Vec<Option<_>> so sqlx can encode NULLs without extra casts.
        let mut food_ids: Vec<Uuid> = Vec::with_capacity(entries.len());
        let mut serving_ids: Vec<Option<Uuid>> = Vec::with_capacity(entries.len());
        let mut consumed_ons: Vec<NaiveDate> = Vec::with_capacity(entries.len());
        let mut meals: Vec<String> = Vec::with_capacity(entries.len());
        let mut quantities: Vec<Decimal> = Vec::with_capacity(entries.len());
        let mut grams_totals: Vec<Decimal> = Vec::with_capacity(entries.len());
        let mut calories_kcals: Vec<Decimal> = Vec::with_capacity(entries.len());
        let mut protein_gs: Vec<Option<Decimal>> = Vec::with_capacity(entries.len());
        let mut carbs_gs: Vec<Option<Decimal>> = Vec::with_capacity(entries.len());
        let mut fat_gs: Vec<Option<Decimal>> = Vec::with_capacity(entries.len());
        let mut fiber_gs: Vec<Option<Decimal>> = Vec::with_capacity(entries.len());
        let mut sugar_gs: Vec<Option<Decimal>> = Vec::with_capacity(entries.len());
        let mut sodium_mgs: Vec<Option<Decimal>> = Vec::with_capacity(entries.len());
        let mut saturated_fat_gs: Vec<Option<Decimal>> = Vec::with_capacity(entries.len());
        let mut notes: Vec<Option<String>> = Vec::with_capacity(entries.len());

        for e in entries {
            food_ids.push(e.food_id);
            serving_ids.push(e.serving_id);
            consumed_ons.push(e.consumed_on);
            meals.push(e.meal.as_str().to_string());
            quantities.push(e.quantity);
            grams_totals.push(e.grams_total);
            calories_kcals.push(e.snapshot.calories_kcal);
            protein_gs.push(e.snapshot.protein_g);
            carbs_gs.push(e.snapshot.carbs_g);
            fat_gs.push(e.snapshot.fat_g);
            fiber_gs.push(e.snapshot.fiber_g);
            sugar_gs.push(e.snapshot.sugar_g);
            sodium_mgs.push(e.snapshot.sodium_mg);
            saturated_fat_gs.push(e.snapshot.saturated_fat_g);
            // clone() rather than as_deref(): sqlx requires owned element types
            // when binding a Vec<Option<T>> for UNNEST — &str won't work here.
            notes.push(e.note.clone());
        }

        // WITH ORDINALITY attaches a row-number to each UNNEST element so we
        // can ORDER BY it before RETURNING. Without it, Postgres does not
        // guarantee that RETURNING rows come back in the same order as the
        // input arrays — the trait contract promises input order, and T10
        // relies on that promise.
        //
        // INSERT … SELECT … FROM UNNEST … RETURNING supports column aliases on
        // the inserted table but cannot JOIN to other tables inline. Per design
        // §4 R2 we return only the new ids here, then re-fetch with the full
        // LEFT JOIN SELECT in a single WHERE id = ANY($1) round-trip.
        let insert_sql =
            "INSERT INTO food_log_entries (\
                user_id, food_id, serving_id, consumed_on, meal, \
                quantity, grams_total, \
                calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g, \
                note\
             ) \
             SELECT \
                $1, x.food_id, x.serving_id, x.consumed_on, x.meal, \
                x.quantity, x.grams_total, \
                x.calories_kcal, x.protein_g, x.carbs_g, x.fat_g, x.fiber_g, x.sugar_g, x.sodium_mg, x.saturated_fat_g, \
                x.note \
             FROM UNNEST(\
                $2::uuid[], \
                $3::uuid[], \
                $4::date[], \
                $5::text[], \
                $6::numeric[], \
                $7::numeric[], \
                $8::numeric[], \
                $9::numeric[], \
                $10::numeric[], \
                $11::numeric[], \
                $12::numeric[], \
                $13::numeric[], \
                $14::numeric[], \
                $15::numeric[], \
                $16::text[] \
             ) WITH ORDINALITY \
               AS x(\
                food_id, serving_id, consumed_on, meal, \
                quantity, grams_total, \
                calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g, \
                note, ord\
             ) \
             ORDER BY x.ord \
             RETURNING id";

        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;
        let inserted_ids: Vec<Uuid> = sqlx::query_scalar(insert_sql)
            .bind(user_id)
            .bind(&food_ids)
            .bind(&serving_ids)
            .bind(&consumed_ons)
            .bind(&meals)
            .bind(&quantities)
            .bind(&grams_totals)
            .bind(&calories_kcals)
            .bind(&protein_gs)
            .bind(&carbs_gs)
            .bind(&fat_gs)
            .bind(&fiber_gs)
            .bind(&sugar_gs)
            .bind(&sodium_mgs)
            .bind(&saturated_fat_gs)
            .bind(&notes)
            .fetch_all(&mut *tx)
            .await
            .map_err(map_sqlx)?;
        tx.commit().await.map_err(map_sqlx)?;

        // Re-fetch with LEFT JOIN to populate food_name + serving_name.
        // ORDER BY array position to preserve input order (T10 contract).
        let fetch_sql = format!(
            "SELECT {SELECT_COLS} FROM {FROM_CLAUSE} \
             WHERE le.id = ANY($1) AND le.user_id = $2 \
             ORDER BY array_position($1, le.id)"
        );
        let rows: Vec<LogEntryRow> = sqlx::query_as(&fetch_sql)
            .bind(&inserted_ids)
            .bind(user_id)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;

        Ok(rows.into_iter().map(Into::into).collect())
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn create_many_sql_has_no_inline_comments() {
        // The create_many SQL is built with Rust line-continuation (\).
        // If an inline SQL comment (--) exists, Postgres will treat it as
        // a line comment and consume the rest of the string as a comment,
        // causing "syntax error at end of input". This test catches that
        // regression by asserting the final SQL has no -- substring.
        //
        // We reconstruct the INSERT SQL the same way the impl does. The
        // follow-up SELECT uses SELECT_COLS/FROM_CLAUSE (tested separately);
        // the insert itself now returns only `id` — one plain identifier,
        // no risk of line-continuation comment injection.
        let sql =
            "INSERT INTO food_log_entries (\
                user_id, food_id, serving_id, consumed_on, meal, \
                quantity, grams_total, \
                calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g, \
                note\
             ) \
             SELECT \
                $1, x.food_id, x.serving_id, x.consumed_on, x.meal, \
                x.quantity, x.grams_total, \
                x.calories_kcal, x.protein_g, x.carbs_g, x.fat_g, x.fiber_g, x.sugar_g, x.sodium_mg, x.saturated_fat_g, \
                x.note \
             FROM UNNEST(\
                $2::uuid[], \
                $3::uuid[], \
                $4::date[], \
                $5::text[], \
                $6::numeric[], \
                $7::numeric[], \
                $8::numeric[], \
                $9::numeric[], \
                $10::numeric[], \
                $11::numeric[], \
                $12::numeric[], \
                $13::numeric[], \
                $14::numeric[], \
                $15::numeric[], \
                $16::text[] \
             ) WITH ORDINALITY \
               AS x(\
                food_id, serving_id, consumed_on, meal, \
                quantity, grams_total, \
                calories_kcal, protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, saturated_fat_g, \
                note, ord\
             ) \
             ORDER BY x.ord \
             RETURNING id";
        assert!(!sql.contains("--"), "SQL must not contain inline comments (--) to avoid comment-swallowing due to Rust line-continuation");
    }
}
