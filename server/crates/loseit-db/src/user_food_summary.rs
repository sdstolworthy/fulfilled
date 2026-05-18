//! Postgres implementation of [`UserFoodSummaryReader`].
//!
//! Today this aggregates against `food_log_entries`. When the future
//! denormalized `user_food_summary` table lands (see the trait's module
//! doc in `loseit-core`), the v2 reader is a body-swap: same trait, same
//! return shape, different SQL.

use async_trait::async_trait;
use chrono::NaiveDate;
use loseit_core::domain::unit::Unit;
use loseit_core::domain::{ServingPreview, UserFoodSummary};
use loseit_core::service::UserFoodSummaryReader;
use loseit_core::CoreResult;
use rust_decimal::Decimal;
use sqlx::PgPool;
use std::collections::HashMap;
use uuid::Uuid;

use crate::error::map_sqlx;

pub struct PgUserFoodSummaryReader {
    pool: PgPool,
}

impl PgUserFoodSummaryReader {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl UserFoodSummaryReader for PgUserFoodSummaryReader {
    async fn summarize(
        &self,
        user_id: Uuid,
        food_ids: &[Uuid],
    ) -> CoreResult<HashMap<Uuid, UserFoodSummary>> {
        if food_ids.is_empty() {
            return Ok(HashMap::new());
        }

        // DISTINCT ON (food_id) over the caller's entries, ordered so
        // the first row per food_id is the most recent. That row
        // exposes `last_logged_at` plus a full `last_serving` preview
        // (id/label/amount/unit/kcal) in one pass; the lifetime
        // `log_count` is computed in parallel via a window aggregate
        // (`COUNT(*) OVER (PARTITION BY food_id)`). Single index seek
        // per food_id given the `(user_id, food_id)` composite added
        // by migration 0002.
        //
        // The LEFT JOIN to `servings` lets the row carry the kcal/label
        // of the serving the caller last used — eliminating a per-row
        // `/foods/:id` round-trip from the FE. Join may produce NULLs
        // when the serving was deleted (FK is ON DELETE SET NULL).
        //
        // The `consumed_on DESC, created_at DESC` tie-break mirrors
        // `LogRepository::list_paginated` so users see the
        // most-recently-saved entry first when two share a date.
        let rows: Vec<(
            Uuid,
            i64,
            NaiveDate,
            Option<Uuid>,
            Option<String>,
            Option<Decimal>,
            Option<String>,
            Option<Decimal>,
        )> = sqlx::query_as(
            r#"
            SELECT
                food_id,
                cnt::bigint AS log_count,
                last_logged_at,
                last_serving_id,
                last_serving_label,
                last_serving_amount,
                last_serving_unit,
                last_serving_kcal
            FROM (
                SELECT DISTINCT ON (l.food_id)
                    l.food_id,
                    COUNT(*)     OVER (PARTITION BY l.food_id) AS cnt,
                    l.consumed_on                              AS last_logged_at,
                    l.serving_id                               AS last_serving_id,
                    s.label                                    AS last_serving_label,
                    s.amount                                   AS last_serving_amount,
                    s.unit::text                               AS last_serving_unit,
                    s.kcal                                     AS last_serving_kcal
                FROM food_log_entries l
                LEFT JOIN servings s ON s.id = l.serving_id
                WHERE l.user_id = $1
                  AND l.food_id = ANY($2)
                ORDER BY l.food_id, l.consumed_on DESC, l.created_at DESC
            ) ranked
            "#,
        )
        .bind(user_id)
        .bind(food_ids)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx)?;

        let mut out = HashMap::with_capacity(rows.len());
        for (
            food_id,
            log_count,
            last_logged_at,
            last_serving_id,
            last_serving_label,
            last_serving_amount,
            last_serving_unit,
            last_serving_kcal,
        ) in rows
        {
            // Build the preview only when every required column is
            // present. `serving_id` being NULL means either the log
            // entry had no serving or the FK was nulled by a delete;
            // in both cases we have nothing to render. We also defend
            // against half-NULL rows (amount/unit/kcal missing) by
            // requiring all of (id, amount, unit, kcal) — label is
            // optional in the source table.
            let last_serving = match (
                last_serving_id,
                last_serving_amount,
                last_serving_unit,
                last_serving_kcal,
            ) {
                (Some(sid), Some(amount), Some(unit_str), Some(kcal)) => {
                    Unit::parse(&unit_str).map(|unit| ServingPreview {
                        id: sid,
                        label: last_serving_label,
                        amount,
                        unit,
                        kcal,
                    })
                }
                _ => None,
            };

            // Saturating conversion: i32::MAX is ~2.1B logs for a single
            // (user, food) pair, which is unreachable in practice. We
            // prefer saturation over wrap to stay monotonically increasing.
            out.insert(
                food_id,
                UserFoodSummary {
                    log_count: i32::try_from(log_count).unwrap_or(i32::MAX),
                    last_logged_at: Some(last_logged_at),
                    last_serving,
                },
            );
        }
        Ok(out)
    }
}
