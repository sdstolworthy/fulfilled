use std::collections::HashMap;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use loseit_core::domain::{
    Food, FoodDraft, FoodPatch, FoodSearchHit, FoodSource, NutriscoreGrade, NutritionPer100g,
    Serving, ServingPreview, ServingSource,
};
use loseit_core::repo::food::{OffFoodUpsert, UpsertStats, QUICK_ADD_SENTINEL_NAME};
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
}

#[derive(sqlx::FromRow)]
struct FoodRow {
    id: Uuid,
    source: String,
    owner_user_id: Option<Uuid>,
    barcode: Option<String>,
    fdc_id: Option<i64>,
    data_type: Option<String>,
    name: String,
    brands: Option<String>,
    categories_tags: Option<Vec<String>>,
    energy_kcal_100g: Option<Decimal>,
    protein_100g: Option<Decimal>,
    carbs_100g: Option<Decimal>,
    fat_100g: Option<Decimal>,
    fiber_100g: Option<Decimal>,
    sugar_100g: Option<Decimal>,
    sodium_100g: Option<Decimal>,
    saturated_fat_100g: Option<Decimal>,
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
            // rather than panic mid-request. (In practice `parse` always
            // succeeds.)
            source: FoodSource::parse(&r.source).unwrap_or(FoodSource::User),
            owner_user_id: r.owner_user_id,
            barcode: r.barcode,
            fdc_id: r.fdc_id,
            data_type: r.data_type,
            name: r.name,
            brands: r.brands,
            categories_tags: r.categories_tags.unwrap_or_default(),
            nutrition: NutritionPer100g {
                energy_kcal: r.energy_kcal_100g,
                protein_g: r.protein_100g,
                carbs_g: r.carbs_100g,
                fat_g: r.fat_100g,
                fiber_g: r.fiber_100g,
                sugar_g: r.sugar_100g,
                sodium_g: r.sodium_100g,
                saturated_fat_g: r.saturated_fat_100g,
            },
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

/// Columns selected for the full `Food` projection. Kept as a const so
/// every read path picks up new columns automatically when the schema
/// grows.
const SELECT_FOOD_COLS: &str = "id, source, owner_user_id, barcode, fdc_id, name, brands, \
    categories_tags, energy_kcal_100g, protein_100g, carbs_100g, fat_100g, fiber_100g, \
    sugar_100g, sodium_100g, saturated_fat_100g, nutriscore_grade, quality_score, \
    extra_nutrients, last_import_batch_id, created_at, updated_at, data_type";

/// Visibility predicate used by read paths. Implements the trait contract:
/// OFF and USDA foods are visible to everyone; user-custom foods are
/// visible only to their owner. Returning `None` for cross-tenant
/// lookups makes them indistinguishable from missing — the handler maps
/// to 404 either way.
const VISIBLE: &str = "(source IN ('off', 'usda') OR owner_user_id = $2)";

/// Pull the SQLSTATE code out of a sqlx error, if any. Used by
/// `delete_custom` to override the generic conflict message for the
/// food-referenced-by-log-entries case.
fn db_code(err: &SqlxError) -> Option<String> {
    match err {
        SqlxError::Database(db) => db.code().map(|c| c.into_owned()),
        _ => None,
    }
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
        // Production ranker (T11). Combines pg_trgm similarity, FTS rank,
        // and a small quality-score nudge inside a CTE so the ORDER BY can
        // reference the synthesized score without recomputing it.
        //
        // Visibility (`source = 'off' OR owner_user_id = $2`) and the match
        // predicate are duplicated in `search_count` so the totals line up
        // with the paginated results.
        //
        // Indexes that back this: pg_trgm GIN on `name` (0001) and on
        // `brands` (0002), plus the FTS expression-index (0001). Without
        // those `%` and `to_tsvector` operators would seq-scan.
        let trimmed = q.trim();
        // The sentinel exclusion (`f.name <> '__quick_add__'`) mirrors the
        // same filter on `list_mine`/`count_mine` so the per-user quick-add
        // food never surfaces in browse paths even to its owner.
        let sql = format!(
            "WITH scored AS ( \
                SELECT \
                    f.id, f.source::text AS source, f.name, f.brands, f.barcode, \
                    f.energy_kcal_100g, f.quality_score, \
                    similarity(f.name, $1) + 0.4 * similarity(coalesce(f.brands, ''), $1) AS sim, \
                    ts_rank( \
                        to_tsvector('simple', coalesce(f.name, '') || ' ' || coalesce(f.brands, '')), \
                        plainto_tsquery('simple', $1) \
                    ) AS ts, \
                    s.id AS default_serving_id, \
                    s.label AS default_serving_label, \
                    s.grams AS default_serving_grams \
                FROM foods f \
                LEFT JOIN servings s ON s.food_id = f.id AND s.is_default \
                WHERE (f.source IN ('off', 'usda') OR f.owner_user_id = $2) \
                  AND f.name <> '{sentinel}' \
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
            LIMIT $3 OFFSET $4",
            sentinel = QUICK_ADD_SENTINEL_NAME
        );

        let rows = sqlx::query(&sql)
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
            let energy: Option<Decimal> = row.try_get("energy_kcal_100g").map_err(map_sqlx)?;
            let serving_id: Option<Uuid> = row.try_get("default_serving_id").map_err(map_sqlx)?;
            let serving_label: Option<String> =
                row.try_get("default_serving_label").map_err(map_sqlx)?;
            let serving_grams: Option<Decimal> =
                row.try_get("default_serving_grams").map_err(map_sqlx)?;

            let default_serving = match (serving_id, serving_label, serving_grams) {
                (Some(sid), Some(label), Some(grams)) => Some(ServingPreview {
                    id: sid,
                    label,
                    grams,
                }),
                _ => None,
            };

            // calories_per_serving = round(energy_kcal_100g * grams / 100).
            // Done in Decimal arithmetic so we avoid float drift; rounded to
            // an integer because the kcal column is whole-kcal in the wire
            // contract.
            let calories_per_serving = match (energy, serving_grams) {
                (Some(e), Some(g)) => Some((e * g / Decimal::from(100)).round()),
                _ => None,
            };

            hits.push(FoodSearchHit {
                id,
                source: FoodSource::parse(&source_str).unwrap_or(FoodSource::User),
                name,
                brand,
                barcode,
                default_serving,
                calories_per_serving,
            });
        }
        Ok(hits)
    }

    async fn search_count(&self, viewer: Uuid, q: &str) -> CoreResult<i64> {
        // Same WHERE clause as `search` (sans LEFT JOIN, ORDER BY, LIMIT,
        // OFFSET) so `total` always matches the paginated result set.
        let trimmed = q.trim();
        let sql = format!(
            "SELECT count(*) FROM foods f \
                   WHERE (f.source IN ('off', 'usda') OR f.owner_user_id = $2) \
                     AND f.name <> '{sentinel}' \
                     AND ( \
                         f.name % $1 OR \
                         coalesce(f.brands, '') % $1 OR \
                         to_tsvector('simple', coalesce(f.name, '') || ' ' || coalesce(f.brands, '')) \
                             @@ plainto_tsquery('simple', $1) \
                     )",
            sentinel = QUICK_ADD_SENTINEL_NAME
        );
        let cnt: i64 = sqlx::query_scalar::<_, i64>(&sql)
            .bind(trimmed)
            .bind(viewer)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(cnt)
    }

    async fn create_custom(&self, owner: Uuid, draft: &FoodDraft) -> CoreResult<Food> {
        let sql = format!(
            "INSERT INTO foods ( \
                source, owner_user_id, barcode, name, brands, categories_tags, \
                energy_kcal_100g, protein_100g, carbs_100g, fat_100g, \
                fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g, \
                nutriscore_grade \
             ) VALUES ( \
                'user', $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14 \
             ) \
             RETURNING {SELECT_FOOD_COLS}"
        );
        let row: FoodRow = sqlx::query_as(&sql)
            .bind(owner)
            .bind(draft.barcode.as_deref())
            .bind(&draft.name)
            .bind(draft.brands.as_deref())
            .bind(&draft.categories_tags)
            .bind(draft.nutrition.energy_kcal)
            .bind(draft.nutrition.protein_g)
            .bind(draft.nutrition.carbs_g)
            .bind(draft.nutrition.fat_g)
            .bind(draft.nutrition.fiber_g)
            .bind(draft.nutrition.sugar_g)
            .bind(draft.nutrition.sodium_g)
            .bind(draft.nutrition.saturated_fat_g)
            .bind(draft.nutriscore_grade.map(|g| g.as_str()))
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn update_custom(&self, owner: Uuid, id: Uuid, patch: &FoodPatch) -> CoreResult<Food> {
        // Owner-scoped + source='user' WHERE means cross-tenant updates and
        // attempts to modify OFF foods both surface as NotFound — never a
        // 403/forbidden, which would leak existence.
        //
        // `patch.nutrition` is all-or-nothing per the domain model: callers
        // either send a full `NutritionPer100g` or nothing. Inside that
        // struct individual fields are `Option<Decimal>` and we COALESCE
        // each. When `patch.nutrition` is `None`, we bind NULL for every
        // nutrition arg and COALESCE preserves the existing value.
        let n = patch.nutrition.as_ref();
        let sql = format!(
            "UPDATE foods SET \
                name             = COALESCE($3, name), \
                brands           = COALESCE($4, brands), \
                barcode          = COALESCE($5, barcode), \
                categories_tags  = COALESCE($6, categories_tags), \
                energy_kcal_100g = COALESCE($7, energy_kcal_100g), \
                protein_100g     = COALESCE($8, protein_100g), \
                carbs_100g       = COALESCE($9, carbs_100g), \
                fat_100g         = COALESCE($10, fat_100g), \
                fiber_100g       = COALESCE($11, fiber_100g), \
                sugar_100g       = COALESCE($12, sugar_100g), \
                sodium_100g      = COALESCE($13, sodium_100g), \
                saturated_fat_100g = COALESCE($14, saturated_fat_100g), \
                nutriscore_grade = COALESCE($15, nutriscore_grade) \
             WHERE id = $1 AND owner_user_id = $2 AND source = 'user' \
             RETURNING {SELECT_FOOD_COLS}"
        );
        let row: FoodRow = sqlx::query_as(&sql)
            .bind(id)
            .bind(owner)
            .bind(patch.name.as_deref())
            .bind(patch.brands.as_deref())
            .bind(patch.barcode.as_deref())
            .bind(patch.categories_tags.as_ref())
            .bind(n.and_then(|x| x.energy_kcal))
            .bind(n.and_then(|x| x.protein_g))
            .bind(n.and_then(|x| x.carbs_g))
            .bind(n.and_then(|x| x.fat_g))
            .bind(n.and_then(|x| x.fiber_g))
            .bind(n.and_then(|x| x.sugar_g))
            .bind(n.and_then(|x| x.sodium_g))
            .bind(n.and_then(|x| x.saturated_fat_g))
            .bind(patch.nutriscore_grade.map(|g| g.as_str()))
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(row.into())
    }

    async fn delete_custom(&self, owner: Uuid, id: Uuid) -> CoreResult<()> {
        // FK from `food_log_entries.food_id` is RESTRICT — Postgres throws
        // 23503 when a referenced row is deleted. We override the generic
        // db message with a caller-friendly one for that specific case.
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

    async fn upsert_off_batch(
        &self,
        batch_id: Uuid,
        records: &[OffFoodUpsert],
    ) -> CoreResult<UpsertStats> {
        // Per-record loop using the `xmax = 0` trick: in the RETURNING
        // clause of an UPSERT, `xmax` is 0 for a freshly inserted row and
        // nonzero for an UPDATE. This lets us count inserts vs updates in
        // a single round-trip per row.
        //
        // Servings are NOT written here — the ingest service calls
        // `ServingRepository::create` for the OFF/system servings after
        // this returns. We only persist the food columns + stamp
        // last_import_batch_id.
        let mut inserted: u64 = 0;
        let mut updated: u64 = 0;

        let sql = "INSERT INTO foods ( \
                source, barcode, name, brands, categories_tags, \
                energy_kcal_100g, protein_100g, carbs_100g, fat_100g, \
                fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g, \
                nutriscore_grade, quality_score, last_import_batch_id \
             ) VALUES ( \
                'off', $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15 \
             ) \
             ON CONFLICT (barcode) WHERE barcode IS NOT NULL DO UPDATE SET \
                name             = EXCLUDED.name, \
                brands           = EXCLUDED.brands, \
                categories_tags  = EXCLUDED.categories_tags, \
                energy_kcal_100g = EXCLUDED.energy_kcal_100g, \
                protein_100g     = EXCLUDED.protein_100g, \
                carbs_100g       = EXCLUDED.carbs_100g, \
                fat_100g         = EXCLUDED.fat_100g, \
                fiber_100g       = EXCLUDED.fiber_100g, \
                sugar_100g       = EXCLUDED.sugar_100g, \
                sodium_100g      = EXCLUDED.sodium_100g, \
                saturated_fat_100g = EXCLUDED.saturated_fat_100g, \
                nutriscore_grade = EXCLUDED.nutriscore_grade, \
                quality_score    = EXCLUDED.quality_score, \
                last_import_batch_id = EXCLUDED.last_import_batch_id \
             RETURNING (xmax = 0) AS inserted";

        for rec in records {
            let draft = &rec.draft;
            let row = sqlx::query(sql)
                .bind(draft.barcode.as_deref())
                .bind(&draft.name)
                .bind(draft.brands.as_deref())
                .bind(&draft.categories_tags)
                .bind(draft.nutrition.energy_kcal)
                .bind(draft.nutrition.protein_g)
                .bind(draft.nutrition.carbs_g)
                .bind(draft.nutrition.fat_g)
                .bind(draft.nutrition.fiber_g)
                .bind(draft.nutrition.sugar_g)
                .bind(draft.nutrition.sodium_g)
                .bind(draft.nutrition.saturated_fat_g)
                .bind(draft.nutriscore_grade.map(|g| g.as_str()))
                .bind(rec.quality_score)
                .bind(batch_id)
                .fetch_one(&self.pool)
                .await
                .map_err(map_sqlx)?;
            let was_inserted: bool = row.try_get("inserted").map_err(map_sqlx)?;
            if was_inserted {
                inserted += 1;
            } else {
                updated += 1;
            }
        }

        Ok(UpsertStats {
            inserted,
            updated,
            skipped: 0,
        })
    }

    async fn list_mine(
        &self,
        owner: Uuid,
        q: Option<&str>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodSearchHit>> {
        // Index scan on foods_owner_idx to filter by owner; rows then sorted
        // created_at DESC, id DESC. $2::text IS NULL is the canonical
        // sqlx-friendly optional-filter pattern.
        let sql = format!(
            "SELECT \
                    f.id, f.source::text AS source, f.name, f.brands, f.barcode, \
                    f.energy_kcal_100g, \
                    s.id AS default_serving_id, \
                    s.label AS default_serving_label, \
                    s.grams AS default_serving_grams \
                   FROM foods f \
                   LEFT JOIN servings s ON s.food_id = f.id AND s.is_default \
                   WHERE f.owner_user_id = $1 \
                     AND f.source = 'user' \
                     AND ($2::text IS NULL OR f.name ILIKE '%' || $2 || '%' OR coalesce(f.brands,'') ILIKE '%' || $2 || '%') \
                     AND f.name <> '{}' \
                   ORDER BY f.created_at DESC, f.id DESC \
                   LIMIT $3 OFFSET $4",
            QUICK_ADD_SENTINEL_NAME
        );

        let q_trimmed = q.map(|s| s.trim()).filter(|s| !s.is_empty());

        let rows = sqlx::query(&sql)
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
            let energy: Option<Decimal> = row.try_get("energy_kcal_100g").map_err(map_sqlx)?;
            let serving_id: Option<Uuid> = row.try_get("default_serving_id").map_err(map_sqlx)?;
            let serving_label: Option<String> =
                row.try_get("default_serving_label").map_err(map_sqlx)?;
            let serving_grams: Option<Decimal> =
                row.try_get("default_serving_grams").map_err(map_sqlx)?;

            let default_serving = match (serving_id, serving_label, serving_grams) {
                (Some(sid), Some(label), Some(grams)) => Some(ServingPreview {
                    id: sid,
                    label,
                    grams,
                }),
                _ => None,
            };

            let calories_per_serving = match (energy, serving_grams) {
                (Some(e), Some(g)) => Some((e * g / Decimal::from(100)).round()),
                _ => None,
            };

            hits.push(FoodSearchHit {
                id,
                source: FoodSource::parse(&source_str).unwrap_or(FoodSource::User),
                name,
                brand,
                barcode,
                default_serving,
                calories_per_serving,
            });
        }
        Ok(hits)
    }

    async fn count_mine(&self, owner: Uuid, q: Option<&str>) -> CoreResult<i64> {
        let sql = format!(
            "SELECT count(*) \
                   FROM foods f \
                   WHERE f.owner_user_id = $1 \
                     AND f.source = 'user' \
                     AND ($2::text IS NULL OR f.name ILIKE '%' || $2 || '%' OR coalesce(f.brands,'') ILIKE '%' || $2 || '%') \
                     AND f.name <> '{}'",
            QUICK_ADD_SENTINEL_NAME
        );
        let q_trimmed = q.map(|s| s.trim()).filter(|s| !s.is_empty());
        let cnt: i64 = sqlx::query_scalar::<_, i64>(&sql)
            .bind(owner)
            .bind(q_trimmed)
            .fetch_one(&self.pool)
            .await
            .map_err(map_sqlx)?;
        Ok(cnt)
    }

    async fn find_or_create_quick_add(&self, owner: Uuid) -> CoreResult<(Food, Serving)> {
        // Two-step idempotent provisioning:
        //
        //   1. UPSERT the sentinel food against the `foods_quick_add_singleton`
        //      partial unique index. Concurrent first-uses both surface here
        //      — one inserts, the other takes the `DO UPDATE` branch — and
        //      both `RETURNING` the same row. The `updated_at = now()` touch
        //      is the cheapest possible no-op write that still produces a
        //      RETURNING row on conflict.
        //
        //   2. UPSERT the synthetic default 100 g serving against the
        //      `servings_one_default_per_food` partial unique index. On the
        //      first call the insert fires; on subsequent calls the existing
        //      row hits the partial index and gets a no-op touch. Either way
        //      we get the existing serving row back.
        //
        // Wrapped in a single transaction so a crash between the two steps
        // leaves no half-provisioned state.
        let mut tx = self.pool.begin().await.map_err(map_sqlx)?;

        let food_sql = format!(
            "INSERT INTO foods ( \
                source, owner_user_id, name, energy_kcal_100g, \
                quality_score, categories_tags \
             ) VALUES ('user', $1, '{sentinel}', 1, 0, ARRAY[]::text[]) \
             ON CONFLICT ON CONSTRAINT foods_quick_add_singleton \
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

        // The servings two-step upsert is required because there's no unique
        // constraint on (food_id, label) — only the `is_default` partial.
        // First call: insert succeeds. Repeat call: the existing default row
        // collides on the partial unique index and gets a no-op touch.
        let serving_sql = "INSERT INTO servings \
                (food_id, label, grams, is_default, source, sort_order) \
             VALUES ($1, 'kcal', 100, true, 'system', 0) \
             ON CONFLICT ON CONSTRAINT servings_one_default_per_food \
               DO UPDATE SET updated_at = now() \
             RETURNING id, food_id, label, grams, is_default, \
                       source::text AS source, sort_order, \
                       created_at, updated_at";
        let row = sqlx::query(serving_sql)
            .bind(food.id)
            .fetch_one(&mut *tx)
            .await
            .map_err(map_sqlx)?;
        let serving = Serving {
            id: row.try_get("id").map_err(map_sqlx)?,
            food_id: row.try_get("food_id").map_err(map_sqlx)?,
            label: row.try_get("label").map_err(map_sqlx)?,
            grams: row.try_get("grams").map_err(map_sqlx)?,
            is_default: row.try_get("is_default").map_err(map_sqlx)?,
            source: {
                let s: String = row.try_get("source").map_err(map_sqlx)?;
                ServingSource::parse(&s).unwrap_or(ServingSource::System)
            },
            sort_order: row.try_get("sort_order").map_err(map_sqlx)?,
            created_at: row.try_get("created_at").map_err(map_sqlx)?,
            updated_at: row.try_get("updated_at").map_err(map_sqlx)?,
        };

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
        // Bind the list as a `text[]` and join via `unnest(... )` so the
        // index on `barcode` can still be used. The visibility predicate
        // mirrors all other read paths.
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
