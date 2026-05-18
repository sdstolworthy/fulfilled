use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use loseit_core::domain::{ServingPreview, UserFoodSummary};
use loseit_core::repo::{LogRepository, ServingRepository};
use loseit_core::service::UserFoodSummaryReader;
use loseit_core::CoreResult;
use uuid::Uuid;

use crate::logs::InMemoryLogRepository;
use crate::servings::InMemoryServingRepository;

/// In-memory implementation of [`UserFoodSummaryReader`]. Backed by an
/// [`InMemoryLogRepository`] so the signals it returns stay consistent
/// with whatever the test seeded into the log store.
///
/// Mirrors the production aggregation: for each requested `food_id`,
/// counts every log entry the user owns and reports the most recent
/// `consumed_on` + a full `last_serving` preview when an
/// [`InMemoryServingRepository`] has been wired via [`Self::with_servings`].
/// Without one, `last_serving` is always `None` — fine for tests that
/// don't care about the preview.
pub struct InMemoryUserFoodSummaryReader {
    logs: Arc<InMemoryLogRepository>,
    servings: Option<Arc<InMemoryServingRepository>>,
}

impl InMemoryUserFoodSummaryReader {
    pub fn new(logs: Arc<InMemoryLogRepository>) -> Self {
        Self {
            logs,
            servings: None,
        }
    }

    /// Wire a serving repo so the reader can populate `last_serving`
    /// with `{id, label, amount, unit, kcal}` — matches the production
    /// reader's `LEFT JOIN servings`. Tests that assert the serving
    /// preview is non-null must call this.
    pub fn with_servings(mut self, servings: Arc<InMemoryServingRepository>) -> Self {
        self.servings = Some(servings);
        self
    }
}

#[async_trait]
impl UserFoodSummaryReader for InMemoryUserFoodSummaryReader {
    async fn summarize(
        &self,
        user_id: Uuid,
        food_ids: &[Uuid],
    ) -> CoreResult<HashMap<Uuid, UserFoodSummary>> {
        if food_ids.is_empty() {
            return Ok(HashMap::new());
        }

        // Pull every entry the user owns. The fake log repo doesn't
        // offer a "filter by food_id list" method, but for tests this
        // is fine — the data is small.
        //
        // We use `list_in_range` with a huge window because that's the
        // simplest "all rows for user" API on the trait. NaiveDate::MIN
        // and NaiveDate::MAX bound the universe.
        let all = self
            .logs
            .list_in_range(user_id, chrono::NaiveDate::MIN, chrono::NaiveDate::MAX)
            .await?;

        let mut out: HashMap<Uuid, UserFoodSummary> = HashMap::new();
        for fid in food_ids {
            let entries: Vec<_> = all.iter().filter(|e| e.food_id == *fid).collect();
            if entries.is_empty() {
                continue;
            }
            // Most-recent entry: tie-break on created_at DESC.
            let latest = entries
                .iter()
                .max_by(|a, b| {
                    a.consumed_on
                        .cmp(&b.consumed_on)
                        .then(a.created_at.cmp(&b.created_at))
                })
                .expect("non-empty");
            let count = i32::try_from(entries.len()).unwrap_or(i32::MAX);

            // Resolve the preview when a serving repo is wired AND the
            // entry referenced a serving. Missing serving (deleted FK
            // or no repo) → None, matching the prod LEFT JOIN.
            let last_serving = match (self.servings.as_ref(), latest.serving_id) {
                (Some(repo), Some(sid)) => repo.find_by_id(sid).await?.map(|s| ServingPreview {
                    id: s.id,
                    label: s.label,
                    amount: s.amount,
                    unit: s.unit,
                    kcal: s.kcal,
                }),
                _ => None,
            };

            out.insert(
                *fid,
                UserFoodSummary {
                    log_count: count,
                    last_logged_at: Some(latest.consumed_on),
                    last_serving,
                },
            );
        }
        Ok(out)
    }
}
