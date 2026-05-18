//! Per-user log signals attached to food list/search results.
//!
//! # Why a trait
//!
//! Today this is fulfilled by `PgUserFoodSummaryReader` (in `loseit-db`)
//! running an aggregate query against `food_log_entries`. Tomorrow it will
//! be fulfilled by a reader against a denormalized `user_food_summary`
//! table maintained by triggers (or an outbox + worker) on log writes. The
//! contract here — given `(user_id, food_ids)`, return a map keyed by
//! `food_id` — is identical across both implementations. The
//! `FoodService` / `LogService` enrichment code, the wire-shape struct
//! (`FoodSearchHitResponse`), the OpenAPI schema, and the Flutter
//! decoder all remain identical when we swap the impl.
//!
//! # Future #3 migration — body-swap notes (do not implement now)
//!
//! When we adopt the denormalized table:
//!
//! ```sql
//! CREATE TABLE user_food_summary (
//!     user_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
//!     food_id          UUID NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
//!     log_count        INTEGER NOT NULL DEFAULT 0,
//!     last_logged_at   DATE,
//!     last_serving_id  UUID REFERENCES servings(id) ON DELETE SET NULL,
//!     updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
//!     PRIMARY KEY (user_id, food_id)
//! );
//! ```
//!
//! Maintained via trigger on `food_log_entries` INSERT/UPDATE/DELETE
//! (or async via the outbox). The new impl is then a pure
//! `SELECT … WHERE user_id = $1 AND food_id = ANY($2)` against
//! `user_food_summary` — no aggregation, no join. The wiring change is
//! one line in `loseit_api::server::build_state`: swap
//! `PgUserFoodSummaryReader::new(pool)` for the v2 type. No FE change,
//! no OpenAPI change, no service change, no handler change, no
//! wire-shape change. **The trait is the seam.**

use std::collections::HashMap;

use async_trait::async_trait;
use uuid::Uuid;

use crate::domain::{FoodSearchHit, FoodSearchHitWithSignals, UserFoodSummary};
use crate::CoreResult;

/// Port for resolving per-user log signals over a batch of food ids.
///
/// Implementations:
///
/// * `loseit_db::PgUserFoodSummaryReader` — production; one aggregate
///   query against `food_log_entries`.
/// * `loseit_testing::InMemoryUserFoodSummaryReader` — in-memory fake
///   used by service- and HTTP-level tests.
///
/// See the module doc for the future v2 implementation against a
/// denormalized table — that is a single-line wiring change.
#[async_trait]
pub trait UserFoodSummaryReader: Send + Sync + 'static {
    /// Return per-food signals for `user_id` across the given `food_ids`.
    ///
    /// Foods the user has never logged are omitted from the map (callers
    /// treat absence as "no logs"). The slice may be empty; the impl must
    /// return `Ok(HashMap::new())` without hitting the database.
    async fn summarize(
        &self,
        user_id: Uuid,
        food_ids: &[Uuid],
    ) -> CoreResult<HashMap<Uuid, UserFoodSummary>>;
}

/// Attach per-user log signals to a slice of search hits in place. Used
/// by all four `/foods/*` service entry points (`FoodService::search`,
/// `FoodService::list_mine`, `LogService::recent_foods`,
/// `LogService::frequent_foods`) so the wire shape is uniform.
///
/// Mutates `hits` directly — callers don't need to allocate a second vec.
/// On empty input the function short-circuits and never touches the
/// reader.
pub async fn enrich_hits(
    reader: &dyn UserFoodSummaryReader,
    user_id: Uuid,
    hits: &mut [FoodSearchHitWithSignals],
) -> CoreResult<()> {
    if hits.is_empty() {
        return Ok(());
    }
    let ids: Vec<Uuid> = hits.iter().map(|h| h.hit.id).collect();
    let map = reader.summarize(user_id, &ids).await?;
    for h in hits.iter_mut() {
        if let Some(s) = map.get(&h.hit.id) {
            h.signals = Some(s.clone());
        }
    }
    Ok(())
}

/// Convenience wrap: turn a `Vec<FoodSearchHit>` from a repo into a
/// `Vec<FoodSearchHitWithSignals>` with `signals: None` on each entry.
/// Service entry points use this just before calling [`enrich_hits`].
pub fn wrap_hits(hits: Vec<FoodSearchHit>) -> Vec<FoodSearchHitWithSignals> {
    hits.into_iter()
        .map(|hit| FoodSearchHitWithSignals { hit, signals: None })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::FoodSource;
    use chrono::NaiveDate;
    use std::sync::Mutex;

    /// Minimal fake `UserFoodSummaryReader` for unit testing the composer.
    /// Returns whatever was preloaded and records the calls it received.
    struct StubReader {
        preloaded: HashMap<Uuid, UserFoodSummary>,
        calls: Mutex<Vec<(Uuid, Vec<Uuid>)>>,
    }

    impl StubReader {
        fn new(preloaded: HashMap<Uuid, UserFoodSummary>) -> Self {
            Self {
                preloaded,
                calls: Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait]
    impl UserFoodSummaryReader for StubReader {
        async fn summarize(
            &self,
            user_id: Uuid,
            food_ids: &[Uuid],
        ) -> CoreResult<HashMap<Uuid, UserFoodSummary>> {
            self.calls
                .lock()
                .unwrap()
                .push((user_id, food_ids.to_vec()));
            let mut out = HashMap::new();
            for id in food_ids {
                if let Some(s) = self.preloaded.get(id) {
                    out.insert(*id, s.clone());
                }
            }
            Ok(out)
        }
    }

    fn make_hit(id: Uuid, name: &str) -> FoodSearchHit {
        FoodSearchHit {
            id,
            source: FoodSource::Off,
            name: name.into(),
            brand: None,
            barcode: None,
            default_serving: None,
        }
    }

    #[tokio::test]
    async fn enrich_hits_attaches_signals_for_known_food() {
        let logged = Uuid::new_v4();
        let unlogged = Uuid::new_v4();
        let user = Uuid::new_v4();
        let date = NaiveDate::from_ymd_opt(2026, 5, 14).unwrap();

        let mut preloaded = HashMap::new();
        preloaded.insert(
            logged,
            UserFoodSummary {
                log_count: 3,
                last_logged_at: Some(date),
                last_serving: None,
            },
        );
        let reader = StubReader::new(preloaded);

        let mut hits = wrap_hits(vec![make_hit(logged, "Logged"), make_hit(unlogged, "Cold")]);
        enrich_hits(&reader, user, &mut hits).await.unwrap();

        // Known food gets signals.
        let logged_hit = hits.iter().find(|h| h.hit.id == logged).unwrap();
        let s = logged_hit.signals.as_ref().unwrap();
        assert_eq!(s.log_count, 3);
        assert_eq!(s.last_logged_at, Some(date));

        // Unknown food stays signals = None.
        let cold_hit = hits.iter().find(|h| h.hit.id == unlogged).unwrap();
        assert!(cold_hit.signals.is_none());

        // The reader was called exactly once with the right ids.
        let calls = reader.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, user);
        assert_eq!(calls[0].1, vec![logged, unlogged]);
    }

    #[tokio::test]
    async fn enrich_hits_short_circuits_on_empty_input() {
        let reader = StubReader::new(HashMap::new());
        let mut hits: Vec<FoodSearchHitWithSignals> = Vec::new();
        enrich_hits(&reader, Uuid::new_v4(), &mut hits)
            .await
            .unwrap();
        assert!(reader.calls.lock().unwrap().is_empty());
    }
}
