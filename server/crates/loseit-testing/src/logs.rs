use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{Duration, NaiveDate, Utc};
use loseit_core::domain::{FoodLogEntry, FoodSource, PersistedLogEntry, PersistedLogPatch};
use loseit_core::repo::food::QUICK_ADD_SENTINEL_NAME;
use loseit_core::repo::{FoodRepository, LogRepository};
use loseit_core::CoreResult;
use uuid::Uuid;

use crate::foods::InMemoryFoodRepository;

#[derive(Default)]
pub struct InMemoryLogRepository {
    by_id: Mutex<HashMap<Uuid, FoodLogEntry>>,
    // Optional cross-wire: when set, `recent_food_ids` / `frequent_food_ids`
    // consult the food store to skip the per-user quick-add sentinel, matching
    // the SQL `JOIN foods … AND name <> '__quick_add__'` filter in the Pg
    // impl. Optional because most tests don't exercise the sentinel and don't
    // want the extra wiring.
    foods: Mutex<Option<Arc<InMemoryFoodRepository>>>,
}

impl InMemoryLogRepository {
    pub fn new() -> Self {
        Self::default()
    }

    /// Wire a food repo so `recent_food_ids` / `frequent_food_ids` can skip
    /// the per-user quick-add sentinel. Optional — without it, all logged
    /// food_ids are returned (legacy behaviour).
    pub fn set_food_repo_for_sentinel_filter(&self, foods: Arc<InMemoryFoodRepository>) {
        *self.foods.lock().unwrap() = Some(foods);
    }

    /// Returns the set of food_ids belonging to this `user_id` whose food
    /// record is the quick-add sentinel. Used by the recent/frequent paths
    /// to exclude those ids. If no food repo is wired in, returns an empty
    /// set (no filtering applied).
    async fn sentinel_food_ids(&self, user_id: Uuid) -> std::collections::HashSet<Uuid> {
        let foods = self.foods.lock().unwrap().clone();
        let Some(foods) = foods else {
            return std::collections::HashSet::new();
        };
        // Collect the food_ids referenced by this user's log entries first
        // so we only inspect a bounded set on the food store side.
        let referenced: std::collections::HashSet<Uuid> = {
            let store = self.by_id.lock().unwrap();
            store
                .values()
                .filter(|e| e.user_id == user_id)
                .map(|e| e.food_id)
                .collect()
        };
        let mut out = std::collections::HashSet::new();
        for id in referenced {
            if let Ok(Some(food)) = foods.find_by_id(user_id, id).await {
                if food.source == FoodSource::User && food.name == QUICK_ADD_SENTINEL_NAME {
                    out.insert(id);
                }
            }
        }
        out
    }
}

#[async_trait]
impl LogRepository for InMemoryLogRepository {
    async fn create(&self, user_id: Uuid, entry: &PersistedLogEntry) -> CoreResult<FoodLogEntry> {
        let now = Utc::now();
        let stored = FoodLogEntry {
            id: Uuid::new_v4(),
            user_id,
            food_id: entry.food_id,
            serving_id: entry.serving_id,
            consumed_on: entry.consumed_on,
            meal: entry.meal,
            quantity: entry.quantity,
            grams_total: entry.grams_total,
            snapshot: entry.snapshot.clone(),
            note: entry.note.clone(),
            created_at: now,
            updated_at: now,
        };
        self.by_id.lock().unwrap().insert(stored.id, stored.clone());
        Ok(stored)
    }

    async fn update(
        &self,
        user_id: Uuid,
        id: Uuid,
        patch: &PersistedLogPatch,
    ) -> CoreResult<FoodLogEntry> {
        let mut store = self.by_id.lock().unwrap();
        let entry = store
            .get_mut(&id)
            .filter(|e| e.user_id == user_id)
            .ok_or(loseit_core::CoreError::NotFound)?;
        if let Some(v) = patch.serving_id {
            entry.serving_id = Some(v);
        }
        if let Some(v) = patch.consumed_on {
            entry.consumed_on = v;
        }
        if let Some(v) = patch.meal {
            entry.meal = v;
        }
        if let Some(v) = &patch.note {
            entry.note = v.clone();
        }
        if let Some(r) = &patch.recompute {
            entry.quantity = r.quantity;
            entry.grams_total = r.grams_total;
            entry.snapshot = r.snapshot.clone();
        }
        entry.updated_at = Utc::now();
        Ok(entry.clone())
    }

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        match store.get(&id) {
            Some(e) if e.user_id == user_id => {
                store.remove(&id);
                Ok(())
            }
            _ => Err(loseit_core::CoreError::NotFound),
        }
    }

    async fn find_by_id(&self, user_id: Uuid, id: Uuid) -> CoreResult<Option<FoodLogEntry>> {
        let store = self.by_id.lock().unwrap();
        Ok(store.get(&id).filter(|e| e.user_id == user_id).cloned())
    }

    async fn list_in_range(
        &self,
        user_id: Uuid,
        from: NaiveDate,
        to: NaiveDate,
    ) -> CoreResult<Vec<FoodLogEntry>> {
        let store = self.by_id.lock().unwrap();
        let mut out: Vec<FoodLogEntry> = store
            .values()
            .filter(|e| e.user_id == user_id)
            .filter(|e| e.consumed_on >= from && e.consumed_on <= to)
            .cloned()
            .collect();
        out.sort_by(|a, b| {
            a.consumed_on
                .cmp(&b.consumed_on)
                .then(a.created_at.cmp(&b.created_at))
        });
        Ok(out)
    }

    async fn list_for_day(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Vec<FoodLogEntry>> {
        let store = self.by_id.lock().unwrap();
        let mut out: Vec<FoodLogEntry> = store
            .values()
            .filter(|e| e.user_id == user_id && e.consumed_on == on)
            .cloned()
            .collect();
        out.sort_by_key(|e| e.created_at);
        Ok(out)
    }

    async fn recent_food_ids(&self, user_id: Uuid, limit: i64) -> CoreResult<Vec<Uuid>> {
        // Exclude the per-user quick-add sentinel food when a food repo has
        // been wired in. Mirrors the Pg `JOIN foods ... AND name <> '__quick_add__'`.
        let excluded = self.sentinel_food_ids(user_id).await;
        let store = self.by_id.lock().unwrap();
        // Compute max created_at per food_id for this user, then sort desc.
        let mut by_food: HashMap<Uuid, chrono::DateTime<chrono::Utc>> = HashMap::new();
        for e in store
            .values()
            .filter(|e| e.user_id == user_id && !excluded.contains(&e.food_id))
        {
            by_food
                .entry(e.food_id)
                .and_modify(|t| {
                    if e.created_at > *t {
                        *t = e.created_at;
                    }
                })
                .or_insert(e.created_at);
        }
        let mut pairs: Vec<(Uuid, chrono::DateTime<chrono::Utc>)> = by_food.into_iter().collect();
        pairs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let take = limit.max(0) as usize;
        Ok(pairs.into_iter().take(take).map(|(id, _)| id).collect())
    }

    async fn frequent_food_ids(
        &self,
        user_id: Uuid,
        window_days: i64,
        limit: i64,
    ) -> CoreResult<Vec<(Uuid, i64)>> {
        let excluded = self.sentinel_food_ids(user_id).await;
        let store = self.by_id.lock().unwrap();
        // Use the most recent consumed_on in the store as the anchor.
        let today = match store
            .values()
            .filter(|e| e.user_id == user_id)
            .map(|e| e.consumed_on)
            .max()
        {
            Some(d) => d,
            None => return Ok(Vec::new()),
        };
        let cutoff = today - Duration::days(window_days);
        let mut counts: HashMap<Uuid, i64> = HashMap::new();
        for e in store.values().filter(|e| {
            e.user_id == user_id && e.consumed_on >= cutoff && !excluded.contains(&e.food_id)
        }) {
            *counts.entry(e.food_id).or_insert(0) += 1;
        }
        let mut pairs: Vec<(Uuid, i64)> = counts.into_iter().collect();
        pairs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        let take = limit.max(0) as usize;
        pairs.truncate(take);
        Ok(pairs)
    }

    async fn any_entry_references_food(&self, food_id: Uuid) -> CoreResult<bool> {
        let store = self.by_id.lock().unwrap();
        Ok(store.values().any(|e| e.food_id == food_id))
    }

    async fn list_paginated(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
        limit: i64,
        offset: i64,
    ) -> CoreResult<Vec<FoodLogEntry>> {
        let store = self.by_id.lock().unwrap();
        let mut out: Vec<FoodLogEntry> = store
            .values()
            .filter(|e| {
                e.user_id == user_id
                    && from.map_or(true, |d| e.consumed_on >= d)
                    && to.map_or(true, |d| e.consumed_on <= d)
            })
            .cloned()
            .collect();
        // Mirror the Postgres ORDER BY consumed_on DESC, created_at DESC, id DESC.
        out.sort_by(|a, b| {
            b.consumed_on
                .cmp(&a.consumed_on)
                .then(b.created_at.cmp(&a.created_at))
                .then(b.id.cmp(&a.id))
        });
        let skip = (offset as usize).min(out.len());
        let take = (limit as usize).min(out.len().saturating_sub(skip));
        Ok(out[skip..skip + take].to_vec())
    }

    async fn count_in_range(
        &self,
        user_id: Uuid,
        from: Option<NaiveDate>,
        to: Option<NaiveDate>,
    ) -> CoreResult<i64> {
        let store = self.by_id.lock().unwrap();
        let count = store
            .values()
            .filter(|e| {
                e.user_id == user_id
                    && from.map_or(true, |d| e.consumed_on >= d)
                    && to.map_or(true, |d| e.consumed_on <= d)
            })
            .count();
        Ok(count as i64)
    }

    async fn create_many(
        &self,
        user_id: Uuid,
        entries: &[PersistedLogEntry],
    ) -> CoreResult<Vec<FoodLogEntry>> {
        let mut out = Vec::with_capacity(entries.len());
        for entry in entries {
            let stored = self.create(user_id, entry).await?;
            out.push(stored);
        }
        Ok(out)
    }
}
