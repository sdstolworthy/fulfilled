use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{Duration, NaiveDate, Utc};
use loseit_core::domain::{FoodLogEntry, PersistedLogEntry, PersistedLogPatch};
use loseit_core::repo::LogRepository;
use loseit_core::CoreResult;
use uuid::Uuid;

#[derive(Default)]
pub struct InMemoryLogRepository {
    by_id: Mutex<HashMap<Uuid, FoodLogEntry>>,
}

impl InMemoryLogRepository {
    pub fn new() -> Self {
        Self::default()
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
        let store = self.by_id.lock().unwrap();
        // Compute max created_at per food_id for this user, then sort desc.
        let mut by_food: HashMap<Uuid, chrono::DateTime<chrono::Utc>> = HashMap::new();
        for e in store.values().filter(|e| e.user_id == user_id) {
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
        for e in store
            .values()
            .filter(|e| e.user_id == user_id && e.consumed_on >= cutoff)
        {
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
}
