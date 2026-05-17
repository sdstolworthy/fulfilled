use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::{Duration, NaiveDate, Utc};
use loseit_core::domain::{FoodLogEntry, FoodSource, PersistedLogEntry, PersistedLogPatch};
use loseit_core::repo::food::QUICK_ADD_SENTINEL_NAME;
use loseit_core::repo::{FoodRepository, LogRepository, ServingRepository};
use loseit_core::CoreResult;
use uuid::Uuid;

use crate::foods::InMemoryFoodRepository;
use crate::servings::InMemoryServingRepository;

#[derive(Default)]
pub struct InMemoryLogRepository {
    by_id: Mutex<HashMap<Uuid, FoodLogEntry>>,
    // Optional cross-wire: when set, `recent_food_ids` / `frequent_food_ids`
    // consult the food store to skip the per-user quick-add sentinel, matching
    // the SQL `JOIN foods … AND name <> '__quick_add__'` filter in the Pg
    // impl. Optional because most tests don't exercise the sentinel and don't
    // want the extra wiring.
    foods: Mutex<Option<Arc<InMemoryFoodRepository>>>,
    servings: Mutex<Option<Arc<InMemoryServingRepository>>>,
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

    /// Wire a serving repo so every `FoodLogEntry`-producing path populates
    /// `serving_name`. Optional — without it, `serving_name` stays `None`
    /// (matches Pg `LEFT JOIN` semantics when no serving is recorded).
    pub fn set_serving_repo(&self, servings: Arc<InMemoryServingRepository>) {
        *self.servings.lock().unwrap() = Some(servings);
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

    /// Populate `food_name` and `serving_name` on `entry` by looking up the
    /// injected repos. Silent on miss — leaves `food_name` empty /
    /// `serving_name` None, matching Pg's `COALESCE(f.name, '')` semantics.
    async fn resolve_names(&self, user_id: Uuid, entry: &mut FoodLogEntry) {
        let foods = { self.foods.lock().unwrap().clone() };
        if let Some(foods) = foods {
            if let Ok(Some(food)) = foods.find_by_id(user_id, entry.food_id).await {
                entry.food_name = food.name;
            }
        }
        if let Some(sid) = entry.serving_id {
            let servings = { self.servings.lock().unwrap().clone() };
            if let Some(servings) = servings {
                if let Ok(Some(serving)) = servings.find_by_id(sid).await {
                    entry.serving_name = serving.label;
                }
            }
        }
    }
}

#[async_trait]
impl LogRepository for InMemoryLogRepository {
    async fn create(&self, user_id: Uuid, entry: &PersistedLogEntry) -> CoreResult<FoodLogEntry> {
        let now = Utc::now();
        let mut stored = FoodLogEntry {
            id: Uuid::new_v4(),
            user_id,
            food_id: entry.food_id,
            food_name: String::new(),        // placeholder; resolved below
            serving_id: entry.serving_id,
            serving_name: None,              // placeholder; resolved below
            consumed_on: entry.consumed_on,
            meal: entry.meal,
            quantity: entry.quantity,
            entered_amount: entry.entered_amount,
            entered_unit: entry.entered_unit,
            snapshot: entry.snapshot.clone(),
            note: entry.note.clone(),
            created_at: now,
            updated_at: now,
        };
        self.by_id.lock().unwrap().insert(stored.id, stored.clone());
        self.resolve_names(user_id, &mut stored).await;
        Ok(stored)
    }

    async fn update(
        &self,
        user_id: Uuid,
        id: Uuid,
        patch: &PersistedLogPatch,
    ) -> CoreResult<FoodLogEntry> {
        let mut out = {
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
            if let Some(ref inner) = patch.note {
                entry.note = inner.clone();
            }
            if let Some(r) = &patch.recompute {
                entry.quantity = r.quantity;
                entry.entered_amount = r.entered_amount;
                entry.entered_unit = r.entered_unit;
                entry.snapshot = r.snapshot.clone();
            }
            entry.updated_at = Utc::now();
            entry.clone()
        };
        self.resolve_names(user_id, &mut out).await;
        Ok(out)
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
        let entry = {
            let store = self.by_id.lock().unwrap();
            store.get(&id).filter(|e| e.user_id == user_id).cloned()
        };
        let mut entry = match entry {
            Some(e) => e,
            None => return Ok(None),
        };
        self.resolve_names(user_id, &mut entry).await;
        Ok(Some(entry))
    }

    async fn list_in_range(
        &self,
        user_id: Uuid,
        from: NaiveDate,
        to: NaiveDate,
    ) -> CoreResult<Vec<FoodLogEntry>> {
        let mut out: Vec<FoodLogEntry> = {
            let store = self.by_id.lock().unwrap();
            store
                .values()
                .filter(|e| e.user_id == user_id)
                .filter(|e| e.consumed_on >= from && e.consumed_on <= to)
                .cloned()
                .collect()
        };
        out.sort_by(|a, b| {
            a.consumed_on
                .cmp(&b.consumed_on)
                .then(a.created_at.cmp(&b.created_at))
        });
        for entry in &mut out {
            self.resolve_names(user_id, entry).await;
        }
        Ok(out)
    }

    async fn list_for_day(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Vec<FoodLogEntry>> {
        let mut out: Vec<FoodLogEntry> = {
            let store = self.by_id.lock().unwrap();
            store
                .values()
                .filter(|e| e.user_id == user_id && e.consumed_on == on)
                .cloned()
                .collect()
        };
        out.sort_by_key(|e| e.created_at);
        for entry in &mut out {
            self.resolve_names(user_id, entry).await;
        }
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
        let mut out: Vec<FoodLogEntry> = {
            let store = self.by_id.lock().unwrap();
            store
                .values()
                .filter(|e| {
                    e.user_id == user_id
                        && from.map_or(true, |d| e.consumed_on >= d)
                        && to.map_or(true, |d| e.consumed_on <= d)
                })
                .cloned()
                .collect()
        };
        // Mirror the Postgres ORDER BY consumed_on DESC, created_at DESC, id DESC.
        out.sort_by(|a, b| {
            b.consumed_on
                .cmp(&a.consumed_on)
                .then(b.created_at.cmp(&a.created_at))
                .then(b.id.cmp(&a.id))
        });
        let skip = (offset as usize).min(out.len());
        let take = (limit as usize).min(out.len().saturating_sub(skip));
        let mut page = out[skip..skip + take].to_vec();
        for entry in &mut page {
            self.resolve_names(user_id, entry).await;
        }
        Ok(page)
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
