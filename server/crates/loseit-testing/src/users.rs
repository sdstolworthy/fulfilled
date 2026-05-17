use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::Utc;
use loseit_core::domain::{HeightUnit, ProfilePatch, User, UserIdentity, WeightUnit};
use loseit_core::repo::UserRepository;
use loseit_core::CoreResult;
use uuid::Uuid;

#[derive(Default)]
pub struct InMemoryUserRepository {
    by_id: Mutex<HashMap<Uuid, User>>,
}

impl InMemoryUserRepository {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.by_id.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[async_trait]
impl UserRepository for InMemoryUserRepository {
    async fn find_by_id(&self, id: Uuid) -> CoreResult<Option<User>> {
        Ok(self.by_id.lock().unwrap().get(&id).cloned())
    }

    async fn find_by_identity(&self, identity: &UserIdentity) -> CoreResult<Option<User>> {
        let store = self.by_id.lock().unwrap();
        Ok(store
            .values()
            .find(|u| {
                u.identity.issuer == identity.issuer
                    && u.identity.external_id == identity.external_id
            })
            .cloned())
    }

    async fn create(&self, identity: &UserIdentity) -> CoreResult<User> {
        let now = Utc::now();
        let user = User {
            id: Uuid::new_v4(),
            identity: identity.clone(),
            sex: None,
            birth_date: None,
            height_cm: None,
            activity_level: None,
            weight_unit: WeightUnit::Kg,
            height_unit: HeightUnit::Cm,
            created_at: now,
            updated_at: now,
        };
        self.by_id.lock().unwrap().insert(user.id, user.clone());
        Ok(user)
    }

    async fn update_profile(&self, id: Uuid, patch: &ProfilePatch) -> CoreResult<User> {
        let mut store = self.by_id.lock().unwrap();
        let user = store.get_mut(&id).ok_or(loseit_core::CoreError::NotFound)?;
        if let Some(v) = &patch.email {
            user.identity.email = Some(v.clone());
        }
        if let Some(v) = &patch.display_name {
            user.identity.display_name = Some(v.clone());
        }
        if let Some(v) = patch.sex {
            user.sex = Some(v);
        }
        if let Some(v) = patch.birth_date {
            user.birth_date = Some(v);
        }
        if let Some(v) = patch.height_cm {
            user.height_cm = Some(v);
        }
        if let Some(v) = patch.activity_level {
            user.activity_level = Some(v);
        }
        if let Some(v) = patch.weight_unit {
            user.weight_unit = v;
        }
        if let Some(v) = patch.height_unit {
            user.height_unit = v;
        }
        user.updated_at = Utc::now();
        Ok(user.clone())
    }

    /// Remove the user row from the in-memory store.
    ///
    /// **Limitation**: this fake does not have access to the other in-memory
    /// repositories (weights, goals, foods, log entries), so it cannot
    /// cascade-delete the user's data. HTTP-level tests that call
    /// `DELETE /me` and then query `/weights` etc. will still see the old
    /// data in memory. Test the cross-table cascade at the Postgres layer;
    /// use these in-memory tests only to verify the 204 response and
    /// authentication behaviour.
    ///
    /// Returns `Ok(())` whether or not the user existed (idempotent).
    async fn delete_user(&self, user_id: Uuid) -> CoreResult<()> {
        self.by_id.lock().unwrap().remove(&user_id);
        Ok(())
    }
}
