use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{NaiveDate, Utc};
use loseit_core::domain::{Goal, GoalDraft, GoalPatch};
use loseit_core::repo::GoalRepository;
use loseit_core::CoreResult;
use uuid::Uuid;

#[derive(Default)]
pub struct InMemoryGoalRepository {
    by_id: Mutex<HashMap<Uuid, Goal>>,
}

impl InMemoryGoalRepository {
    pub fn new() -> Self {
        Self::default()
    }
}

fn goal_from_draft(user_id: Uuid, draft: &GoalDraft) -> Goal {
    let now = Utc::now();
    Goal {
        id: Uuid::new_v4(),
        user_id,
        starts_on: draft.starts_on,
        ends_on: draft.ends_on,
        start_weight_kg: draft.start_weight_kg,
        target_weight_kg: draft.target_weight_kg,
        weekly_rate_kg: draft.weekly_rate_kg,
        daily_calorie_target: draft.daily_calorie_target,
        protein_g_target: draft.protein_g_target,
        carbs_g_target: draft.carbs_g_target,
        fat_g_target: draft.fat_g_target,
        created_at: now,
        updated_at: now,
    }
}

#[async_trait]
impl GoalRepository for InMemoryGoalRepository {
    async fn create(&self, user_id: Uuid, draft: &GoalDraft) -> CoreResult<Goal> {
        let goal = goal_from_draft(user_id, draft);
        self.by_id.lock().unwrap().insert(goal.id, goal.clone());
        Ok(goal)
    }

    async fn create_succeeding(
        &self,
        user_id: Uuid,
        closes_on: NaiveDate,
        draft: &GoalDraft,
    ) -> CoreResult<Goal> {
        let mut store = self.by_id.lock().unwrap();
        for goal in store.values_mut() {
            if goal.user_id == user_id && goal.ends_on.is_none() {
                goal.ends_on = Some(closes_on);
                goal.updated_at = Utc::now();
            }
        }
        let new_goal = goal_from_draft(user_id, draft);
        store.insert(new_goal.id, new_goal.clone());
        Ok(new_goal)
    }

    async fn list_for_user(&self, user_id: Uuid) -> CoreResult<Vec<Goal>> {
        let store = self.by_id.lock().unwrap();
        let mut out: Vec<Goal> = store
            .values()
            .filter(|g| g.user_id == user_id)
            .cloned()
            .collect();
        out.sort_by_key(|g| std::cmp::Reverse(g.starts_on));
        Ok(out)
    }

    async fn find_active_on(&self, user_id: Uuid, on: NaiveDate) -> CoreResult<Option<Goal>> {
        let store = self.by_id.lock().unwrap();
        Ok(store
            .values()
            .filter(|g| g.user_id == user_id)
            .filter(|g| g.starts_on <= on)
            .filter(|g| g.ends_on.map_or(true, |e| e >= on))
            .max_by_key(|g| g.starts_on)
            .cloned())
    }

    async fn update(&self, user_id: Uuid, id: Uuid, patch: &GoalPatch) -> CoreResult<Goal> {
        let mut store = self.by_id.lock().unwrap();
        let goal = store
            .get_mut(&id)
            .filter(|g| g.user_id == user_id)
            .ok_or(loseit_core::CoreError::NotFound)?;
        if let Some(v) = patch.starts_on {
            goal.starts_on = v;
        }
        if let Some(v) = patch.ends_on {
            goal.ends_on = Some(v);
        }
        if let Some(v) = patch.start_weight_kg {
            goal.start_weight_kg = Some(v);
        }
        if let Some(v) = patch.target_weight_kg {
            goal.target_weight_kg = Some(v);
        }
        if let Some(v) = patch.weekly_rate_kg {
            goal.weekly_rate_kg = Some(v);
        }
        if let Some(v) = patch.daily_calorie_target {
            goal.daily_calorie_target = Some(v);
        }
        if let Some(v) = patch.protein_g_target {
            goal.protein_g_target = Some(v);
        }
        if let Some(v) = patch.carbs_g_target {
            goal.carbs_g_target = Some(v);
        }
        if let Some(v) = patch.fat_g_target {
            goal.fat_g_target = Some(v);
        }
        goal.updated_at = Utc::now();
        Ok(goal.clone())
    }

    async fn delete(&self, user_id: Uuid, id: Uuid) -> CoreResult<()> {
        let mut store = self.by_id.lock().unwrap();
        match store.get(&id) {
            Some(g) if g.user_id == user_id => {
                store.remove(&id);
                Ok(())
            }
            _ => Err(loseit_core::CoreError::NotFound),
        }
    }
}
