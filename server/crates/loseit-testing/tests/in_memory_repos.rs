//! Direct unit tests on the in-memory fakes from T04.

use std::sync::Arc;

use chrono::{Duration, NaiveDate, Utc};
use loseit_core::domain::{
    FoodDraft, Meal, NutritionPer100g, NutritionSnapshot, PersistedLogEntry,
};
use loseit_core::repo::{FoodRepository, LogRepository, ServingRepository};
use loseit_core::CoreError;
use loseit_testing::{InMemoryFoodRepository, InMemoryLogRepository, InMemoryServingRepository};
use rust_decimal::Decimal;
use uuid::Uuid;

fn sample_draft(name: &str) -> FoodDraft {
    FoodDraft {
        name: name.to_string(),
        brands: None,
        barcode: None,
        categories_tags: Vec::new(),
        nutrition: NutritionPer100g::default(),
        nutriscore_grade: None,
    }
}

fn sample_persisted_entry(food_id: Uuid, consumed_on: NaiveDate) -> PersistedLogEntry {
    PersistedLogEntry {
        food_id,
        serving_id: None,
        consumed_on,
        meal: Meal::Breakfast,
        quantity: Decimal::from(1),
        grams_total: Decimal::from(100),
        snapshot: NutritionSnapshot {
            calories_kcal: Decimal::from(100),
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sugar_g: None,
            sodium_mg: None,
            saturated_fat_g: None,
        },
        note: None,
    }
}

#[tokio::test]
async fn test_in_memory_food_repo_hides_other_users_customs() {
    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();
    let food = repo
        .create_custom(alice, &sample_draft("Alice's smoothie"))
        .await
        .expect("create");

    // Alice sees it.
    let seen = repo.find_by_id(alice, food.id).await.expect("find");
    assert!(seen.is_some(), "owner should see their own custom food");

    // Bob does not.
    let unseen = repo.find_by_id(bob, food.id).await.expect("find");
    assert!(unseen.is_none(), "other user must not see private custom");
}

#[tokio::test]
async fn test_in_memory_food_repo_search_respects_visibility() {
    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();
    repo.create_custom(alice, &sample_draft("Secret kale shake"))
        .await
        .expect("create");

    let alice_hits = repo.search(alice, "kale", 50, 0).await.expect("search");
    assert_eq!(alice_hits.len(), 1, "owner sees their custom in search");

    let bob_hits = repo.search(bob, "kale", 50, 0).await.expect("search");
    assert!(bob_hits.is_empty(), "non-owner must not see private custom");

    let bob_count = repo.search_count(bob, "kale").await.expect("count");
    assert_eq!(bob_count, 0);
}

#[tokio::test]
async fn test_in_memory_serving_repo_set_default_is_atomic() {
    use loseit_core::domain::{ServingDraft, ServingSource};

    let repo = Arc::new(InMemoryServingRepository::new());
    let food_id = Uuid::new_v4();

    // Three servings; first one starts as default.
    let mut serving_ids = Vec::new();
    for i in 0i32..3 {
        let s = repo
            .create(
                food_id,
                &ServingDraft {
                    label: format!("serving {i}"),
                    grams: Decimal::from(10 * (i + 1)),
                    is_default: i == 0,
                    source: ServingSource::User,
                    sort_order: i,
                },
            )
            .await
            .expect("create");
        serving_ids.push(s.id);
    }

    // Spawn 8 concurrent set_default calls, cycling through the three IDs.
    let mut join_set = tokio::task::JoinSet::new();
    for i in 0..8u32 {
        let repo = repo.clone();
        let target = serving_ids[(i as usize) % serving_ids.len()];
        join_set.spawn(async move {
            repo.set_default(food_id, target)
                .await
                .expect("set_default");
        });
    }
    while let Some(res) = join_set.join_next().await {
        res.expect("join");
    }

    let servings = repo.list_for_food(food_id).await.expect("list");
    let defaults: Vec<_> = servings.iter().filter(|s| s.is_default).collect();
    assert_eq!(
        defaults.len(),
        1,
        "exactly one serving must remain flagged default after concurrent flips"
    );
}

#[tokio::test]
async fn test_in_memory_log_repo_frequent_counts_recent_window() {
    let repo = InMemoryLogRepository::new();
    let user = Uuid::new_v4();
    let recent_food = Uuid::new_v4();
    let old_food = Uuid::new_v4();

    // Anchor "today" by inserting a recent entry — frequent uses the max
    // consumed_on in the store. Pick a fixed date so the test is stable.
    let today = NaiveDate::from_ymd_opt(2026, 5, 15).unwrap();
    let inside_window = today - Duration::days(10);
    let outside_window = today - Duration::days(60);

    // Two entries for the recent food inside the window, plus the anchor.
    repo.create(user, &sample_persisted_entry(recent_food, today))
        .await
        .expect("create");
    repo.create(user, &sample_persisted_entry(recent_food, inside_window))
        .await
        .expect("create");
    // One entry for an old food well outside the 30-day window.
    repo.create(user, &sample_persisted_entry(old_food, outside_window))
        .await
        .expect("create");

    let pairs = repo
        .frequent_food_ids(user, 30, 10)
        .await
        .expect("frequent");
    assert_eq!(pairs.len(), 1, "only the recent food should appear");
    assert_eq!(pairs[0].0, recent_food);
    assert_eq!(pairs[0].1, 2);
}

#[tokio::test]
async fn test_in_memory_food_repo_delete_conflict_when_log_repo_has_entries() {
    let foods = InMemoryFoodRepository::new();
    let logs = Arc::new(InMemoryLogRepository::new());
    foods.set_log_repo_for_delete_check(logs.clone());

    let owner = Uuid::new_v4();
    let food = foods
        .create_custom(owner, &sample_draft("Custom protein bar"))
        .await
        .expect("create");

    // Insert a log entry referencing the food.
    let today = Utc::now().date_naive();
    logs.create(owner, &sample_persisted_entry(food.id, today))
        .await
        .expect("log create");

    let err = foods
        .delete_custom(owner, food.id)
        .await
        .expect_err("delete should fail");
    match err {
        CoreError::Conflict(msg) => {
            assert!(msg.contains("referenced"), "got: {msg}");
        }
        other => panic!("expected Conflict, got {other:?}"),
    }
}
