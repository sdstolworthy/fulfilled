use std::collections::HashMap;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use loseit_core::domain::{
    Food, FoodDraft, FoodKind, FoodPatch, FoodSearchHit, FoodSource, NutriscoreGrade, Serving,
    ServingDraft, ServingPreview, ServingSource,
};
use loseit_core::repo::food::{BatchWriteOutcome, FoodDraftWithServings, QUICK_ADD_SENTINEL_NAME};
use loseit_core::repo::FoodRepository;
use loseit_core::{CoreError, CoreResult};
use rust_decimal::Decimal;
use sqlx::{Error as SqlxError, PgPool, Row};
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgFoodRepository {
    pool: PgPool,
}

impl PgFoodRepository {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Phase 1.5: write a single external food + servings. Returns
    /// `Ok(true)` on success, `Ok(false)` when the food was skipped for
    /// non-error reasons (e.g. USDA data_type couldn't be normalised),
    /// and `Err(...)` on a true SQL error which the caller will log +
    /// count as skipped.
    async fn upsert_one_external(
        &self,
        batch_id: Uuid,
        rec: &FoodDraftWithServings,
    ) -> CoreResult<bool> {
        let draft = &rec.draft;

        // UPSERT the food row. The source identity invariant means OFF
        // foods conflict on `barcode` (partial unique index) and USDA
        // foods conflict on `fdc_id` (partial unique index). We fall back
        // to barcode as the conflict target since the batch is expected to
        // be homogeneous (OFF or USDA) and the caller normalizes this.
        let food_id: Uuid = if draft.barcode.is_some() {
            // OFF path: conflict on barcode partial unique index.
            let sql = "INSERT INTO foods ( \
                    source, barcode, name, brands, categories_tags, \
                    nutriscore_grade, quality_score, last_import_batch_id \
                 ) VALUES ( \
                    'off', $1, $2, $3, $4, $5, $6, $7 \
                 ) \
                 ON CONFLICT (barcode) WHERE barcode IS NOT NULL DO UPDATE SET \
                    name                 = EXCLUDED.name, \
                    brands               = EXCLUDED.brands, \
                    categories_tags      = EXCLUDED.categories_tags, \
                    nutriscore_grade     = EXCLUDED.nutriscore_grade, \
                    quality_score        = EXCLUDED.quality_score, \
                    last_import_batch_id = EXCLUDED.last_import_batch_id \
                 RETURNING id";
            sqlx::query_scalar::<_, Uuid>(sql)
                .bind(draft.barcode.as_deref())
                .bind(&draft.name)
                .bind(draft.brands.as_deref())
                .bind(&draft.categories_tags)
                .bind(draft.nutriscore_grade.map(|g| g.as_str()))
                .bind(rec.quality_score)
                .bind(batch_id)
                .fetch_one(&self.pool)
                .await
                .map_err(map_sqlx)?
        } else {
            // USDA path: conflict on fdc_id partial unique index.
            let fdc_id = match draft.fdc_id {
                Some(id) => id,
                None => {
                    return Err(CoreError::Validation(
                        "USDA upsert requires fdc_id but draft.fdc_id is None".into(),
                    ));
                }
            };
            let sql = "INSERT INTO foods ( \
                    source, fdc_id, data_type, name, brands, categories_tags, \
                    nutriscore_grade, quality_score, last_import_batch_id \
                 ) VALUES ( \
                    'usda', $1, $2, $3, $4, $5, $6, $7, $8 \
                 ) \
                 ON CONFLICT (fdc_id) WHERE fdc_id IS NOT NULL DO UPDATE SET \
                    name                 = EXCLUDED.name, \
                    brands               = EXCLUDED.brands, \
                    categories_tags      = EXCLUDED.categories_tags, \
                    data_type            = EXCLUDED.data_type, \
                    nutriscore_grade     = EXCLUDED.nutriscore_grade, \
                    quality_score        = EXCLUDED.quality_score, \
                    last_import_batch_id = EXCLUDED.last_import_batch_id \
                 RETURNING id";
            let db_data_type = match draft.data_type.as_deref().and_then(normalise_data_type) {
                Some(dt) => dt,
                None => {
                    tracing::warn!(
                        fdc_id = fdc_id,
                        raw_data_type = ?draft.data_type,
                        "skipping USDA food: data_type missing or unrecognised"
                    );
                    return Ok(false);
                }
            };
            sqlx::query_scalar::<_, Uuid>(sql)
                .bind(fdc_id)
                .bind(db_data_type)
                .bind(&draft.name)
                .bind(draft.brands.as_deref())
                .bind(&draft.categories_tags)
                .bind(draft.nutriscore_grade.map(|g| g.as_str()))
                .bind(rec.quality_score)
                .bind(batch_id)
                .fetch_one(&self.pool)
                .await
                .map_err(map_sqlx)?
        };

        // Atomic serving replace: delete all existing, insert new list.
        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;
        sqlx::query("DELETE FROM servings WHERE food_id = $1")
            .bind(food_id)
            .execute(&mut *tx)
            .await
            .map_err(map_sqlx)?;
        for s in &rec.servings {
            insert_serving_in_tx(&mut tx, food_id, s).await?;
        }
        tx.commit().await.map_err(map_sqlx)?;
        Ok(true)
    }
}

/// Format the best-available external identifier for log messages.
fn external_id_of(draft: &FoodDraft) -> String {
    if let Some(bc) = draft.barcode.as_deref() {
        format!("barcode={bc}")
    } else if let Some(fid) = draft.fdc_id {
        format!("fdc_id={fid}")
    } else {
        "unknown".to_string()
    }
}

/// Row shape for the `foods` table (post-Ask10 schema — no `*_100g` columns).
#[derive(sqlx::FromRow)]
struct FoodRow {
    id: Uuid,
    source: String,
    kind: String,
    owner_user_id: Option<Uuid>,
    barcode: Option<String>,
    fdc_id: Option<i64>,
    data_type: Option<String>,
    name: String,
    brands: Option<String>,
    categories_tags: Option<Vec<String>>,
    nutriscore_grade: Option<String>,
    quality_score: i16,
    extra_nutrients: Option<serde_json::Value>,
    last_import_batch_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

impl From<FoodRow> for Food {
    fn from(r: FoodRow) -> Self {
        Food {
            id: r.id,
            // The DB CHECK constraint enforces the source domain — anything
            // unrecognized is data corruption and we default to `User`
            // rather than panic mid-request.
            source: FoodSource::parse(&r.source).unwrap_or(FoodSource::User),
            kind: FoodKind::parse(&r.kind).unwrap_or(FoodKind::Normal),
            owner_user_id: r.owner_user_id,
            barcode: r.barcode,
            fdc_id: r.fdc_id,
            data_type: r.data_type,
            name: r.name,
            brands: r.brands,
            categories_tags: r.categories_tags.unwrap_or_default(),
            nutriscore_grade: r
                .nutriscore_grade
                .as_deref()
                .and_then(NutriscoreGrade::parse),
            quality_score: r.quality_score,
            extra_nutrients: r.extra_nutrients,
            last_import_batch_id: r.last_import_batch_id,
            created_at: r.created_at,
            updated_at: r.updated_at,
        }
    }
}

/// Columns selected for the full `Food` projection. No `*_100g` columns —
/// nutrition now lives on the `servings` table.
const SELECT_FOOD_COLS: &str = "id, source, owner_user_id, barcode, fdc_id, name, brands, \
    categories_tags, nutriscore_grade, quality_score, \
    extra_nutrients, last_import_batch_id, created_at, updated_at, data_type, kind";

/// Visibility predicate used by read paths. OFF and USDA foods are visible to
/// everyone; user-custom foods are visible only to their owner.
const VISIBLE: &str = "(source IN ('off', 'usda') OR owner_user_id = $2)";

/// Normalise a raw USDA `dataType` string (e.g. from the FDC JSON export) into
/// the DB-accepted enum value. Returns `None` for unrecognised inputs so the
/// `foods_data_type_source_check` constraint is not violated.
fn normalise_data_type(raw: &str) -> Option<&'static str> {
    match raw.trim().to_lowercase().as_str() {
        "foundation" | "foundation_food" => Some("foundation_food"),
        "sr legacy" | "sr_legacy" | "sr_legacy_food" => Some("sr_legacy_food"),
        "survey (fndds)" | "survey_fndds_food" | "fndds" => Some("survey_fndds_food"),
        "branded" | "branded_food" => Some("branded_food"),
        _ => None,
    }
}

/// Pull the SQLSTATE code out of a sqlx error, if any.
fn db_code(err: &SqlxError) -> Option<String> {
    match err {
        SqlxError::Database(db) => db.code().map(|c| c.into_owned()),
        _ => None,
    }
}

/// INSERT a single serving row inside an already-open transaction.
/// Returns the generated serving id so the caller can assemble the `Food`
/// return value if needed (currently unused — callers re-fetch the food row).
async fn insert_serving_in_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    food_id: Uuid,
    s: &ServingDraft,
) -> CoreResult<Serving> {
    let sql = "INSERT INTO servings \
        (food_id, label, amount, unit, kcal, protein_g, carbs_g, fat_g, \
         fiber_g, sugar_g, sodium_mg, saturated_fat_g, \
         is_default, source, sort_order) \
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15) \
        RETURNING id, food_id, label, amount, unit::text AS unit, kcal, \
                  protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, \
                  saturated_fat_g, is_default, source::text AS source, \
                  sort_order, created_at, updated_at";
    let row = sqlx::query(sql)
        .bind(food_id)
        .bind(s.label.as_deref())
        .bind(s.amount)
        .bind(s.unit.as_str())
        .bind(s.kcal)
        .bind(s.protein_g)
        .bind(s.carbs_g)
        .bind(s.fat_g)
        .bind(s.fiber_g)
        .bind(s.sugar_g)
        .bind(s.sodium_mg)
        .bind(s.saturated_fat_g)
        .bind(s.is_default)
        .bind(s.source.as_str())
        .bind(s.sort_order)
        .fetch_one(&mut **tx)
        .await
        .map_err(map_sqlx)?;
    row_to_serving(&row)
}

/// Map a raw sqlx `Row` into a `Serving`. Column aliases expected:
/// `unit::text AS unit`, `source::text AS source`.
fn row_to_serving(row: &sqlx::postgres::PgRow) -> CoreResult<Serving> {
    let unit_str: String = row.try_get("unit").map_err(map_sqlx)?;
    let source_str: String = row.try_get("source").map_err(map_sqlx)?;
    Ok(Serving {
        id: row.try_get("id").map_err(map_sqlx)?,
        food_id: row.try_get("food_id").map_err(map_sqlx)?,
        label: row.try_get("label").map_err(map_sqlx)?,
        amount: row.try_get("amount").map_err(map_sqlx)?,
        unit: loseit_core::domain::unit::Unit::parse(&unit_str)
            .ok_or_else(|| CoreError::internal(format!("unknown unit: {unit_str}")))?,
        kcal: row.try_get("kcal").map_err(map_sqlx)?,
        protein_g: row.try_get("protein_g").map_err(map_sqlx)?,
        carbs_g: row.try_get("carbs_g").map_err(map_sqlx)?,
        fat_g: row.try_get("fat_g").map_err(map_sqlx)?,
        fiber_g: row.try_get("fiber_g").map_err(map_sqlx)?,
        sugar_g: row.try_get("sugar_g").map_err(map_sqlx)?,
        sodium_mg: row.try_get("sodium_mg").map_err(map_sqlx)?,
        saturated_fat_g: row.try_get("saturated_fat_g").map_err(map_sqlx)?,
        is_default: row.try_get("is_default").map_err(map_sqlx)?,
        source: ServingSource::parse(&source_str).unwrap_or(ServingSource::User),
        sort_order: row.try_get("sort_order").map_err(map_sqlx)?,
        created_at: row.try_get("created_at").map_err(map_sqlx)?,
        updated_at: row.try_get("updated_at").map_err(map_sqlx)?,
    })
}

#[async_trait]
impl FoodRepository for PgFoodRepository {
    async fn find_by_id(&self, viewer: Uuid, id: Uuid) -> CoreResult<Option<Food>> {
        let sql = format!(
            "SELECT {SELECT_FOOD_COLS} FROM foods \
             WHERE id = $1 AND {VISIBLE}"
        );
        let row: Option<FoodRow> = sqlx::query_as(&sql)
            .bind(id)
            .bind(viewer)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn find_by_barcode(&self, viewer: Uuid, barcode: &str) -> CoreResult<Option<Food>> {
        let sql = format!(
            "SELECT {SELECT_FOOD_COLS} FROM foods \
             WHERE barcode = $1 AND {VISIBLE}"
        );
        let row: Option<FoodRow> = sqlx::query_as(&sql)
            .bind(barcode)
            .bind(viewer)
            .fetch_optional(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.map(Into::into))
    }

    async fn search(
        &self,
        viewer: Uuid,
        q: &str,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodSearchHit>> {
        // Production ranker: pg_trgm similarity + FTS rank + quality-score nudge.
        // Sentinel exclusion uses `kind <> 'quick_add'` (index discriminator from
        // the new schema; mirrors the partial unique index `foods_quick_add_singleton`).
        let trimmed = q.trim();
        let sql = "WITH scored AS ( \
                SELECT \
                    f.id, f.source::text AS source, f.name, f.brands, f.barcode, \
                    f.quality_score, \
                    similarity(f.name, $1) + 0.4 * similarity(coalesce(f.brands, ''), $1) AS sim, \
                    ts_rank( \
                        to_tsvector('simple', coalesce(f.name, '') || ' ' || coalesce(f.brands, '')), \
                        plainto_tsquery('simple', $1) \
                    ) AS ts, \
                    s.id AS default_serving_id, \
                    s.label AS default_serving_label, \
                    s.amount AS default_serving_amount, \
                    s.unit::text AS default_serving_unit, \
                    s.kcal AS default_serving_kcal \
                FROM foods f \
                LEFT JOIN servings s ON s.food_id = f.id AND s.is_default \
                WHERE (f.source IN ('off', 'usda') OR f.owner_user_id = $2) \
                  AND f.kind <> 'quick_add' \
                  AND ( \
                      f.name % $1 OR \
                      coalesce(f.brands, '') % $1 OR \
                      to_tsvector('simple', coalesce(f.name, '') || ' ' || coalesce(f.brands, '')) \
                          @@ plainto_tsquery('simple', $1) \
                  ) \
            ) \
            SELECT * FROM scored \
            ORDER BY (0.5 * sim + 0.3 * ts + 0.2 * (quality_score::float / 100.0)) DESC, \
                     name ASC \
            LIMIT $3 OFFSET $4";

        let rows = sqlx::query(sql)
            .bind(trimmed)
            .bind(viewer)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;

        let mut hits = Vec::with_capacity(rows.len());
        for row in rows {
            let id: Uuid = row.try_get("id").map_err(map_sqlx)?;
            let source_str: String = row.try_get("source").map_err(map_sqlx)?;
            let name: String = row.try_get("name").map_err(map_sqlx)?;
            let brand: Option<String> = row.try_get("brands").map_err(map_sqlx)?;
            let barcode: Option<String> = row.try_get("barcode").map_err(map_sqlx)?;
            let serving_id: Option<Uuid> = row.try_get("default_serving_id").map_err(map_sqlx)?;
            let serving_label: Option<String> =
                row.try_get("default_serving_label").map_err(map_sqlx)?;
            let serving_amount: Option<Decimal> =
                row.try_get("default_serving_amount").map_err(map_sqlx)?;
            let serving_unit_str: Option<String> =
                row.try_get("default_serving_unit").map_err(map_sqlx)?;
            let serving_kcal: Option<Decimal> =
                row.try_get("default_serving_kcal").map_err(map_sqlx)?;

            let default_serving = match (serving_id, serving_amount, serving_unit_str, serving_kcal)
            {
                (Some(sid), Some(amount), Some(unit_str), Some(kcal)) => {
                    loseit_core::domain::unit::Unit::parse(&unit_str).map(|unit| ServingPreview {
                        id: sid,
                        label: serving_label,
                        amount,
                        unit,
                        kcal,
                    })
                }
                _ => None,
            };

            hits.push(FoodSearchHit {
                id,
                source: FoodSource::parse(&source_str).unwrap_or(FoodSource::User),
                name,
                brand,
                barcode,
                default_serving,
            });
        }
        Ok(hits)
    }

    async fn search_count(&self, viewer: Uuid, q: &str) -> CoreResult<i64> {
        let trimmed = q.trim();
        let cnt: i64 = sqlx::query_scalar::<_, i64>(
            "SELECT count(*) FROM foods f \
                   WHERE (f.source IN ('off', 'usda') OR f.owner_user_id = $2) \
                     AND f.kind <> 'quick_add' \
                     AND ( \
                         f.name % $1 OR \
                         coalesce(f.brands, '') % $1 OR \
                         to_tsvector('simple', coalesce(f.name, '') || ' ' || coalesce(f.brands, '')) \
                             @@ plainto_tsquery('simple', $1) \
                     )",
        )
        .bind(trimmed)
        .bind(viewer)
        .fetch_one(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(cnt)
    }

    /// Create a user-custom food together with its initial servings in a single
    /// transaction. At least one serving is required (caller is expected to
    /// validate before calling this).
    async fn create_custom_with_servings(
        &self,
        owner: Uuid,
        draft: &FoodDraft,
        servings: Vec<ServingDraft>,
    ) -> CoreResult<Food> {
        if servings.is_empty() {
            return Err(CoreError::Validation(
                "at least one serving required".into(),
            ));
        }

        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;

        // INSERT the food row (no *_100g binds).
        let food_sql = format!(
            "INSERT INTO foods ( \
                source, owner_user_id, barcode, name, brands, categories_tags, \
                nutriscore_grade \
             ) VALUES ( \
                'user', $1, $2, $3, $4, $5, $6 \
             ) \
             RETURNING {SELECT_FOOD_COLS}"
        );
        let food_row: FoodRow = sqlx::query_as(&food_sql)
            .bind(owner)
            .bind(draft.barcode.as_deref())
            .bind(&draft.name)
            .bind(draft.brands.as_deref())
            .bind(&draft.categories_tags)
            .bind(draft.nutriscore_grade.map(|g| g.as_str()))
            .fetch_one(&mut *tx)
            .await
            .map_err(map_sqlx)?;
        let food: Food = food_row.into();

        // INSERT each serving in the transaction.
        for s in &servings {
            insert_serving_in_tx(&mut tx, food.id, s).await?;
        }

        tx.commit().await.map_err(map_sqlx)?;
        Ok(food)
    }

    /// Update a user-custom food. When `servings` is `Some`, the existing
    /// serving list is replaced atomically (DELETE + INSERT in one txn).
    /// When `servings` is `None`, only the food metadata is patched.
    async fn update_custom_with_servings(
        &self,
        owner: Uuid,
        id: Uuid,
        patch: &FoodPatch,
        servings: Option<Vec<ServingDraft>>,
    ) -> CoreResult<Food> {
        // Owner-scoped + source='user' WHERE means cross-tenant updates and
        // attempts to modify OFF foods both surface as NotFound.
        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;

        let food_sql = format!(
            "UPDATE foods SET \
                name             = COALESCE($3, name), \
                brands           = COALESCE($4, brands), \
                barcode          = COALESCE($5, barcode), \
                categories_tags  = COALESCE($6, categories_tags), \
                nutriscore_grade = COALESCE($7, nutriscore_grade) \
             WHERE id = $1 AND owner_user_id = $2 AND source = 'user' \
             RETURNING {SELECT_FOOD_COLS}"
        );
        let food_row: FoodRow = sqlx::query_as(&food_sql)
            .bind(id)
            .bind(owner)
            .bind(patch.name.as_deref())
            .bind(patch.brands.as_deref())
            .bind(patch.barcode.as_deref())
            .bind(patch.categories_tags.as_ref())
            .bind(patch.nutriscore_grade.map(|g| g.as_str()))
            .fetch_one(&mut *tx)
            .await
            .map_err(map_sqlx)?;
        let food: Food = food_row.into();

        // Full-list serving replace: DELETE existing, INSERT new list.
        if let Some(new_servings) = servings {
            if new_servings.is_empty() {
                return Err(CoreError::Validation(
                    "at least one serving required".into(),
                ));
            }
            sqlx::query("DELETE FROM servings WHERE food_id = $1")
                .bind(id)
                .execute(&mut *tx)
                .await
                .map_err(map_sqlx)?;
            for s in &new_servings {
                insert_serving_in_tx(&mut tx, food.id, s).await?;
            }
        }

        tx.commit().await.map_err(map_sqlx)?;
        Ok(food)
    }

    async fn delete_custom(&self, owner: Uuid, id: Uuid) -> CoreResult<()> {
        // FK from `food_log_entries.food_id` is RESTRICT — Postgres throws
        // 23503 when a referenced row is deleted.
        let result = sqlx::query(
            "DELETE FROM foods \
             WHERE id = $1 AND owner_user_id = $2 AND source = 'user'",
        )
        .bind(id)
        .bind(owner)
        .execute(&self.pool)
        .await
        .map_err(|e| match db_code(&e).as_deref() {
            Some("23503") => CoreError::Conflict("food is referenced by log entries".into()),
            _ => map_sqlx(e),
        })?;

        if result.rows_affected() == 0 {
            return Err(CoreError::NotFound);
        }
        Ok(())
    }

    /// Upsert a batch of external (OFF / USDA) food records. Per-food: UPSERT
    /// the food row on `(barcode)` conflict, then atomically replace the serving
    /// list (DELETE + INSERT). The `batch_id` is stamped on every upserted food
    /// row for import tracing via `food_import_batches`.
    ///
    /// Phase 1.5: per-food failures (FK violation, CHECK constraint, etc.)
    /// are logged at WARN with the external id (barcode / fdc_id) and
    /// counted as `skipped`; they no longer `?`-bubble and abort the
    /// remainder of the batch.
    async fn upsert_external_food_batch(
        &self,
        batch_id: Uuid,
        batch: Vec<FoodDraftWithServings>,
    ) -> CoreResult<BatchWriteOutcome> {
        let mut outcome = BatchWriteOutcome::default();
        for rec in &batch {
            match self.upsert_one_external(batch_id, rec).await {
                Ok(true) => outcome.upserted += 1,
                Ok(false) => outcome.skipped += 1,
                Err(err) => {
                    outcome.skipped += 1;
                    tracing::warn!(
                        external_id = %external_id_of(&rec.draft),
                        error = %err,
                        "skipping external food: per-row write failed"
                    );
                }
            }
        }
        Ok(outcome)
    }

    async fn list_mine(
        &self,
        owner: Uuid,
        q: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodSearchHit>> {
        let sql = "SELECT \
                    f.id, f.source::text AS source, f.name, f.brands, f.barcode, \
                    s.id AS default_serving_id, \
                    s.label AS default_serving_label, \
                    s.amount AS default_serving_amount, \
                    s.unit::text AS default_serving_unit, \
                    s.kcal AS default_serving_kcal \
                   FROM foods f \
                   LEFT JOIN servings s ON s.food_id = f.id AND s.is_default \
                   WHERE f.owner_user_id = $1 \
                     AND f.source = 'user' \
                     AND ($2::text IS NULL OR f.name ILIKE '%' || $2 || '%' OR coalesce(f.brands,'') ILIKE '%' || $2 || '%') \
                     AND f.kind <> 'quick_add' \
                   ORDER BY f.created_at DESC, f.id DESC \
                   LIMIT $3 OFFSET $4";

        let q_trimmed = q.map(|s| s.trim()).filter(|s| !s.is_empty());

        let rows = sqlx::query(sql)
            .bind(owner)
            .bind(q_trimmed)
            .bind(limit)
            .bind(offset)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;

        let mut hits = Vec::with_capacity(rows.len());
        for row in rows {
            let id: Uuid = row.try_get("id").map_err(map_sqlx)?;
            let source_str: String = row.try_get("source").map_err(map_sqlx)?;
            let name: String = row.try_get("name").map_err(map_sqlx)?;
            let brand: Option<String> = row.try_get("brands").map_err(map_sqlx)?;
            let barcode: Option<String> = row.try_get("barcode").map_err(map_sqlx)?;
            let serving_id: Option<Uuid> = row.try_get("default_serving_id").map_err(map_sqlx)?;
            let serving_label: Option<String> =
                row.try_get("default_serving_label").map_err(map_sqlx)?;
            let serving_amount: Option<Decimal> =
                row.try_get("default_serving_amount").map_err(map_sqlx)?;
            let serving_unit_str: Option<String> =
                row.try_get("default_serving_unit").map_err(map_sqlx)?;
            let serving_kcal: Option<Decimal> =
                row.try_get("default_serving_kcal").map_err(map_sqlx)?;

            let default_serving = match (serving_id, serving_amount, serving_unit_str, serving_kcal)
            {
                (Some(sid), Some(amount), Some(unit_str), Some(kcal)) => {
                    loseit_core::domain::unit::Unit::parse(&unit_str).map(|unit| ServingPreview {
                        id: sid,
                        label: serving_label,
                        amount,
                        unit,
                        kcal,
                    })
                }
                _ => None,
            };

            hits.push(FoodSearchHit {
                id,
                source: FoodSource::parse(&source_str).unwrap_or(FoodSource::User),
                name,
                brand,
                barcode,
                default_serving,
            });
        }
        Ok(hits)
    }

    async fn count_mine(&self, owner: Uuid, q: Option<&str>) -> CoreResult<i64> {
        let q_trimmed = q.map(|s| s.trim()).filter(|s| !s.is_empty());
        let cnt: i64 = sqlx::query_scalar::<_, i64>(
            "SELECT count(*) \
                   FROM foods f \
                   WHERE f.owner_user_id = $1 \
                     AND f.source = 'user' \
                     AND ($2::text IS NULL OR f.name ILIKE '%' || $2 || '%' OR coalesce(f.brands,'') ILIKE '%' || $2 || '%') \
                     AND f.kind <> 'quick_add'",
        )
        .bind(owner)
        .bind(q_trimmed)
        .fetch_one(&self.pool)
        .await
        .map_err(map_sqlx)?;
        Ok(cnt)
    }

    async fn find_or_create_quick_add(&self, owner: Uuid) -> CoreResult<(Food, Serving)> {
        // Two-step idempotent provisioning in one transaction:
        //
        //   1. UPSERT the sentinel food against the `foods_quick_add_singleton`
        //      partial unique index (keyed on `kind = 'quick_add'` since the
        //      new schema uses `kind` as the discriminator, not `name`).
        //
        //   2. UPSERT the synthetic default sentinel serving:
        //      {amount: 1, unit: 'serving', kcal: 1.0, source: 'system',
        //       is_default: true, sort_order: 0} per D1 / §6.2.
        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;

        let food_sql = format!(
            "INSERT INTO foods ( \
                source, owner_user_id, name, quality_score, categories_tags, kind \
             ) VALUES ('user', $1, '{sentinel}', 0, ARRAY[]::text[], 'quick_add') \
             ON CONFLICT (owner_user_id) WHERE source = 'user' AND kind = 'quick_add' \
               DO UPDATE SET updated_at = now() \
             RETURNING {SELECT_FOOD_COLS}",
            sentinel = QUICK_ADD_SENTINEL_NAME
        );
        let food_row: FoodRow = sqlx::query_as(&food_sql)
            .bind(owner)
            .fetch_one(&mut *tx)
            .await
            .map_err(map_sqlx)?;
        let food: Food = food_row.into();

        // Sentinel serving: {amount: 1, unit: 'serving', kcal: 1.0, source: 'system'}.
        // Same partial-index inference form as before — the partial unique index
        // `servings_one_default_per_food` is ON servings(food_id) WHERE is_default.
        let serving_sql = "INSERT INTO servings \
                (food_id, label, amount, unit, kcal, is_default, source, sort_order) \
             VALUES ($1, NULL, 1, 'serving', 1.0, true, 'system', 0) \
             ON CONFLICT (food_id) WHERE is_default \
               DO UPDATE SET updated_at = now() \
             RETURNING id, food_id, label, amount, unit::text AS unit, kcal, \
                       protein_g, carbs_g, fat_g, fiber_g, sugar_g, sodium_mg, \
                       saturated_fat_g, is_default, source::text AS source, \
                       sort_order, created_at, updated_at";
        let row = sqlx::query(serving_sql)
            .bind(food.id)
            .fetch_one(&mut *tx)
            .await
            .map_err(map_sqlx)?;
        let serving = row_to_serving(&row)?;

        tx.commit().await.map_err(map_sqlx)?;
        Ok((food, serving))
    }

    async fn find_ids_by_barcodes(
        &self,
        viewer: Uuid,
        barcodes: &[&str],
    ) -> CoreResult<HashMap<String, Uuid>> {
        if barcodes.is_empty() {
            return Ok(HashMap::new());
        }
        let owned: Vec<String> = barcodes.iter().map(|s| (*s).to_string()).collect();
        let sql = "SELECT barcode, id FROM foods \
                   WHERE barcode = ANY($1) AND (source IN ('off', 'usda') OR owner_user_id = $2)";
        let rows = sqlx::query(sql)
            .bind(&owned)
            .bind(viewer)
            .fetch_all(&self.pool)
            .await
            .map_err(map_sqlx)?;

        let mut out = HashMap::with_capacity(rows.len());
        for row in rows {
            let bc: Option<String> = row.try_get("barcode").map_err(map_sqlx)?;
            let id: Uuid = row.try_get("id").map_err(map_sqlx)?;
            if let Some(bc) = bc {
                out.insert(bc, id);
            }
        }
        Ok(out)
    }
}
