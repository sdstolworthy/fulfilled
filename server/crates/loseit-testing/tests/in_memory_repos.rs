//! Direct unit tests on the in-memory fakes from T04.

use std::sync::Arc;

use chrono::{Duration, NaiveDate, Utc};
use loseit_core::domain::{
    FoodDraft, FoodSource, Meal, NutritionPer100g, NutritionSnapshot, PersistedLogEntry,
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

// ── list_mine / count_mine tests ──────────────────────────────────────────────

fn draft_with_brands(name: &str, brands: &str) -> FoodDraft {
    FoodDraft {
        name: name.to_string(),
        brands: Some(brands.to_string()),
        barcode: None,
        categories_tags: Vec::new(),
        nutrition: NutritionPer100g::default(),
        nutriscore_grade: None,
    }
}

#[tokio::test]
async fn list_mine_returns_only_user_owned_foods() {
    use loseit_core::repo::{OffFoodUpsert, SystemServing};

    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();
    let bob = Uuid::new_v4();

    // Alice's custom food.
    repo.create_custom(alice, &sample_draft("Alice's bar"))
        .await
        .expect("create");

    // An OFF food (visible to everyone but must NOT appear in list_mine).
    let batch = Uuid::new_v4();
    repo.upsert_off_batch(
        batch,
        &[OffFoodUpsert {
            draft: FoodDraft {
                name: "Banana".to_string(),
                brands: None,
                barcode: Some("0000000000001".to_string()),
                categories_tags: Vec::new(),
                nutrition: NutritionPer100g::default(),
                nutriscore_grade: None,
            },
            quality_score: 50,
            off_serving: None,
            system_100g_serving: SystemServing {
                label: "100g".to_string(),
                grams: Decimal::from(100),
            },
        }],
    )
    .await
    .expect("upsert_off_batch");

    // Bob's custom food.
    repo.create_custom(bob, &sample_draft("Bob's shake"))
        .await
        .expect("create");

    let hits = repo.list_mine(alice, None, 50, 0).await.expect("list_mine");
    assert_eq!(hits.len(), 1, "Alice should see only her one custom food");
    assert_eq!(hits[0].name, "Alice's bar");
    assert_eq!(hits[0].source, FoodSource::User);
}

#[tokio::test]
async fn list_mine_filters_by_q_case_insensitive() {
    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();

    // Name match.
    repo.create_custom(alice, &sample_draft("Chocolate Brownie"))
        .await
        .expect("create");
    // Brand match only.
    repo.create_custom(alice, &draft_with_brands("Protein Cookie", "MuscleCraft"))
        .await
        .expect("create");
    // No match.
    repo.create_custom(alice, &sample_draft("Plain Oatmeal"))
        .await
        .expect("create");

    // Case-insensitive name match.
    let hits = repo
        .list_mine(alice, Some("CHOCO"), 50, 0)
        .await
        .expect("list_mine");
    assert_eq!(hits.len(), 1, "should match 'Chocolate Brownie' by name");
    assert_eq!(hits[0].name, "Chocolate Brownie");

    // Case-insensitive brand match.
    let hits = repo
        .list_mine(alice, Some("musclecraft"), 50, 0)
        .await
        .expect("list_mine by brand");
    assert_eq!(hits.len(), 1, "should match by brand");
    assert_eq!(hits[0].name, "Protein Cookie");

    // No q → all three returned.
    let hits = repo.list_mine(alice, None, 50, 0).await.expect("all");
    assert_eq!(hits.len(), 3);
}

#[tokio::test]
async fn list_mine_paginates() {
    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();

    // Insert 5 foods with deliberate delays to ensure distinct created_at.
    // Since the in-memory repo uses Utc::now() at creation time and these
    // are synchronous inserts in a tight loop, UUIDs may be created in the
    // same instant. We rely on the secondary sort key (id DESC) for
    // stability — both sorts are deterministic.
    let mut names = Vec::new();
    for i in 0..5i32 {
        let name = format!("food_{i:02}");
        repo.create_custom(alice, &sample_draft(&name))
            .await
            .expect("create");
        names.push(name);
    }

    // Ask for all 5 to determine the stable order.
    let all = repo.list_mine(alice, None, 50, 0).await.expect("all");
    assert_eq!(all.len(), 5);

    // Page 2 (0-indexed): limit=2, offset=2 → items at position 2 and 3.
    let page = repo.list_mine(alice, None, 2, 2).await.expect("page");
    assert_eq!(page.len(), 2);
    assert_eq!(page[0].name, all[2].name);
    assert_eq!(page[1].name, all[3].name);
}

#[tokio::test]
async fn list_mine_excludes_quick_add_sentinel() {
    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();

    // Insert a sentinel directly via create_custom (name matches the filter).
    repo.create_custom(
        alice,
        &FoodDraft {
            name: "__quick_add__".to_string(),
            brands: None,
            barcode: None,
            categories_tags: Vec::new(),
            nutrition: NutritionPer100g::default(),
            nutriscore_grade: None,
        },
    )
    .await
    .expect("create sentinel");

    // Insert a normal food.
    repo.create_custom(alice, &sample_draft("Real Food"))
        .await
        .expect("create");

    let hits = repo.list_mine(alice, None, 50, 0).await.expect("list_mine");
    assert_eq!(hits.len(), 1, "sentinel must be excluded");
    assert_eq!(hits[0].name, "Real Food");

    let count = repo.count_mine(alice, None).await.expect("count");
    assert_eq!(count, 1, "count_mine must also exclude sentinel");
}

#[tokio::test]
async fn count_mine_matches_list_mine_total_independent_of_pagination() {
    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();

    for i in 0..5i32 {
        repo.create_custom(alice, &sample_draft(&format!("food_{i}")))
            .await
            .expect("create");
    }

    // list_mine with limit=2 returns 2 rows...
    let page = repo.list_mine(alice, None, 2, 0).await.expect("page");
    assert_eq!(page.len(), 2);

    // ...but count_mine returns the full 5.
    let total = repo.count_mine(alice, None).await.expect("count");
    assert_eq!(total, 5, "count_mine must be independent of pagination");
}
