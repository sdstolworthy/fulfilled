//! Postgres implementation of [`UserFoodSummaryReader`].
//!
//! Today this aggregates against `food_log_entries`. When the future
//! denormalized `user_food_summary` table lands (see the trait's module
//! doc in `loseit-core`), the v2 reader is a body-swap: same trait, same
//! return shape, different SQL.

use async_trait::async_trait;
use chrono::NaiveDate;
use loseit_core::domain::UserFoodSummary;
use loseit_core::service::UserFoodSummaryReader;
use loseit_core::CoreResult;
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
        // exposes `last_logged_at` and `last_serving_id` in one pass;
        // the lifetime `log_count` is computed in parallel via a window
        // aggregate (`COUNT(*) OVER (PARTITION BY food_id)`). Single
        // index seek per food_id given the `(user_id, food_id)`
        // composite added by migration 0002.
        //
        // The `consumed_on DESC, created_at DESC` tie-break mirrors
        // `LogRepository::list_paginated` so users see the
        // most-recently-saved entry first when two share a date.
        let rows: Vec<(Uuid, i64, NaiveDate, Option<Uuid>)> = sqlx::query_as(
            r#"
            SELECT
                food_id,
                cnt::bigint AS log_count,
                last_logged_at,
                last_serving_id
            FROM (
                SELECT DISTINCT ON (food_id)
                    food_id,
                    COUNT(*)    OVER (PARTITION BY food_id) AS cnt,
                    consumed_on                              AS last_logged_at,
                    serving_id                               AS last_serving_id
                FROM food_log_entries
                WHERE user_id = $1
                  AND food_id = ANY($2)
                ORDER BY food_id, consumed_on DESC, created_at DESC
            ) ranked
            "#,
        )
        .bind(user_id)
        .bind(food_ids)
        .fetch_all(&self.pool)
        .await
        .map_err(map_sqlx)?;

        let mut out = HashMap::with_capacity(rows.len());
        for (food_id, log_count, last_logged_at, last_serving_id) in rows {
            // Saturating conversion: i32::MAX is ~2.1B logs for a single
            // (user, food) pair, which is unreachable in practice. We
            // prefer saturation over wrap to stay monotonically increasing.
            out.insert(
                food_id,
                UserFoodSummary {
                    log_count: i32::try_from(log_count).unwrap_or(i32::MAX),
                    last_logged_at: Some(last_logged_at),
                    last_serving_id,
                },
            );
        }
        Ok(out)
    }
}
