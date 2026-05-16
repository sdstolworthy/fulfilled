//! Integration tests exercising the service layer against in-memory
//! repository fakes. These tests run in a few milliseconds, require no
//! Postgres, and are the canonical pattern for asserting business
//! behaviour without HTTP or SQL noise.

use std::sync::Arc;

use chrono::NaiveDate;
use loseit_core::domain::{GoalDraft, ProfilePatch, Sex, UserIdentity, WeightDraft};
use loseit_core::service::{GoalService, UserService, WeightService};
use loseit_testing::{InMemoryGoalRepository, InMemoryUserRepository, InMemoryWeightRepository};
use rust_decimal::Decimal;

fn dev_identity() -> UserIdentity {
    UserIdentity {
        issuer: "test".into(),
        external_id: "abc-123".into(),
        email: Some("test@example.com".into()),
        display_name: Some("Test User".into()),
    }
}

#[tokio::test]
async fn ensure_user_is_idempotent() {
    let repo = Arc::new(InMemoryUserRepository::new());
    let users = UserService::new(repo.clone());

    let identity = dev_identity();
    let first = users.ensure_user(&identity).await.unwrap();
    let second = users.ensure_user(&identity).await.unwrap();

    assert_eq!(first.id, second.id, "ensure_user must not duplicate rows");
    assert_eq!(repo.len(), 1);
}

#[tokio::test]
async fn profile_patch_applies_provided_fields_only() {
    let repo = Arc::new(InMemoryUserRepository::new());
    let users = UserService::new(repo);

    let user = users.ensure_user(&dev_identity()).await.unwrap();

    let patch = ProfilePatch {
        sex: Some(Sex::Female),
        height_cm: Some(Decimal::new(17000, 2)), // 170.00
        ..Default::default()
    };
    let updated = users.update_profile(user.id, patch).await.unwrap();

    assert_eq!(updated.sex, Some(Sex::Female));
    assert_eq!(updated.height_cm, Some(Decimal::new(17000, 2)));
    // email/display_name from the original identity were not touched.
    assert_eq!(updated.identity.email.as_deref(), Some("test@example.com"));
}

#[tokio::test]
async fn weights_list_filters_by_date_window() {
    let repo = Arc::new(InMemoryWeightRepository::new());
    let weights = WeightService::new(repo);

    let user_id = uuid::Uuid::new_v4();
    for day in 10..=20 {
        let draft = WeightDraft {
            recorded_on: NaiveDate::from_ymd_opt(2026, 5, day).unwrap(),
            recorded_at_local: None,
            weight_kg: Decimal::new(8000, 2),
            note: None,
        };
        weights.record(user_id, draft).await.unwrap();
    }

    let from = Some(NaiveDate::from_ymd_opt(2026, 5, 13).unwrap());
    let to = Some(NaiveDate::from_ymd_opt(2026, 5, 17).unwrap());
    let in_window = weights.list(user_id, from, to).await.unwrap();
    assert_eq!(in_window.len(), 5);
    // Sorted newest first.
    assert_eq!(in_window[0].recorded_on.day(), 17);
}

#[tokio::test]
async fn creating_a_new_goal_closes_the_previous_open_ended_one() {
    let repo = Arc::new(InMemoryGoalRepository::new());
    let goals = GoalService::new(repo);

    let user_id = uuid::Uuid::new_v4();

    let first = goals
        .create(
            user_id,
            GoalDraft {
                starts_on: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
                ends_on: None,
                start_weight_kg: None,
                target_weight_kg: None,
                weekly_rate_kg: None,
                daily_calorie_target: Some(2200),
                protein_g_target: None,
                carbs_g_target: None,
                fat_g_target: None,
            },
        )
        .await
        .unwrap();
    assert!(first.ends_on.is_none());

    let second_start = NaiveDate::from_ymd_opt(2026, 6, 1).unwrap();
    let second = goals
        .create(
            user_id,
            GoalDraft {
                starts_on: second_start,
                ends_on: None,
                start_weight_kg: None,
                target_weight_kg: None,
                weekly_rate_kg: None,
                daily_calorie_target: Some(1800),
                protein_g_target: None,
                carbs_g_target: None,
                fat_g_target: None,
            },
        )
        .await
        .unwrap();
    assert!(second.ends_on.is_none());

    let listing = goals.list(user_id).await.unwrap();
    let prior = listing
        .iter()
        .find(|g| g.id == first.id)
        .expect("first goal still present");
    assert_eq!(
        prior.ends_on,
        Some(NaiveDate::from_ymd_opt(2026, 5, 31).unwrap()),
        "previous goal should end the day before the new one starts"
    );

    let active_today = goals.active_on(user_id, second_start).await.unwrap();
    assert_eq!(active_today.id, second.id);
}

// Local use of chrono's Datelike for tidier date-component access above.
use chrono::Datelike;
