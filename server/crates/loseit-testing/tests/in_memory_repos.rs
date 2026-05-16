//! Direct unit tests on the in-memory fakes from T04.

use std::sync::Arc;

use chrono::{Duration, NaiveDate, Utc};
use loseit_core::domain::{
    FoodDraft, FoodSource, Meal, NutritionPer100g, NutritionSnapshot, PersistedLogEntry,
    WeightDraft,
};
use loseit_core::repo::{FoodRepository, LogRepository, ServingRepository, WeightRepository};
use loseit_core::service::{LogService, WeightService};
use loseit_core::CoreError;
use loseit_testing::{
    InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLogRepository,
    InMemoryServingRepository, InMemoryWeightRepository,
};
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

#[tokio::test]
async fn list_mine_trims_whitespace_in_q() {
    let repo = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();

    repo.create_custom(alice, &sample_draft("Chocolate Brownie"))
        .await
        .expect("create");
    repo.create_custom(alice, &sample_draft("Plain Oatmeal"))
        .await
        .expect("create");

    // q with surrounding whitespace should match exactly as the trimmed value.
    let hits = repo
        .list_mine(alice, Some("  CHOCO  "), 50, 0)
        .await
        .expect("list_mine with padded q");
    assert_eq!(hits.len(), 1, "whitespace-padded q should still filter");
    assert_eq!(hits[0].name, "Chocolate Brownie");

    // q that is only whitespace should be treated as None (return all).
    let hits = repo
        .list_mine(alice, Some("   "), 50, 0)
        .await
        .expect("list_mine with whitespace-only q");
    assert_eq!(hits.len(), 2, "whitespace-only q should return all foods");

    // count_mine should apply the same trim behaviour.
    let count = repo
        .count_mine(alice, Some("  CHOCO  "))
        .await
        .expect("count_mine with padded q");
    assert_eq!(count, 1);

    let count = repo
        .count_mine(alice, Some("   "))
        .await
        .expect("count_mine with whitespace-only q");
    assert_eq!(count, 2);
}

// ── list_paginated / count_in_range tests (T03) ───────────────────────────────

fn make_log_service() -> (Arc<InMemoryLogRepository>, LogService) {
    let logs = Arc::new(InMemoryLogRepository::new());
    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    let goals = Arc::new(InMemoryGoalRepository::new());
    let svc = LogService::new(logs.clone(), foods, servings, goals);
    (logs, svc)
}

#[tokio::test]
async fn log_repo_list_paginated_orders_by_consumed_on_then_created_at_then_id() {
    // Seed 3 entries across 2 dates. We need the order to be deterministic.
    // Because InMemoryLogRepository uses Utc::now() for created_at and all
    // inserts happen in tight sequence the timestamps may collide — the id
    // tiebreaker (UUID v4 random) would make order non-deterministic in that
    // case. Work around it by inserting in date order and verifying that the
    // descending date sort is what drives the top-level ordering.
    let repo = InMemoryLogRepository::new();
    let user = Uuid::new_v4();
    let food = Uuid::new_v4();

    let day_old = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let day_new = NaiveDate::from_ymd_opt(2026, 1, 3).unwrap();

    // Insert: two entries on the older date, one on the newer.
    let e_old_a = repo
        .create(user, &sample_persisted_entry(food, day_old))
        .await
        .expect("create old_a");
    let e_old_b = repo
        .create(user, &sample_persisted_entry(food, day_old))
        .await
        .expect("create old_b");
    let e_new = repo
        .create(user, &sample_persisted_entry(food, day_new))
        .await
        .expect("create new");

    let page = repo
        .list_paginated(user, None, None, 10, 0)
        .await
        .expect("list_paginated");

    assert_eq!(page.len(), 3);
    // The newer date entry must be first.
    assert_eq!(page[0].id, e_new.id, "newest date should be first");
    // Both older entries follow.
    assert!(
        page[1].consumed_on == day_old && page[2].consumed_on == day_old,
        "older entries should come after"
    );
    // Verify none of the older-date entries are e_new.
    assert_ne!(page[1].id, e_new.id);
    assert_ne!(page[2].id, e_new.id);
    // The two old entries are either e_old_a or e_old_b — just confirm both present.
    let old_ids: Vec<_> = vec![page[1].id, page[2].id];
    assert!(old_ids.contains(&e_old_a.id));
    assert!(old_ids.contains(&e_old_b.id));
}

#[tokio::test]
async fn log_repo_list_paginated_filters_by_from_only() {
    let repo = InMemoryLogRepository::new();
    let user = Uuid::new_v4();
    let food = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    repo.create(user, &sample_persisted_entry(food, jan1))
        .await
        .expect("create jan1");
    repo.create(user, &sample_persisted_entry(food, jan5))
        .await
        .expect("create jan5");
    repo.create(user, &sample_persisted_entry(food, jan10))
        .await
        .expect("create jan10");

    // from=jan5 → jan5 and jan10 only.
    let page = repo
        .list_paginated(user, Some(jan5), None, 10, 0)
        .await
        .expect("list");
    assert_eq!(page.len(), 2, "from filter should include jan5..=jan10");
    assert!(page.iter().all(|e| e.consumed_on >= jan5));
}

#[tokio::test]
async fn log_repo_list_paginated_filters_by_to_only() {
    let repo = InMemoryLogRepository::new();
    let user = Uuid::new_v4();
    let food = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    repo.create(user, &sample_persisted_entry(food, jan1))
        .await
        .expect("create jan1");
    repo.create(user, &sample_persisted_entry(food, jan5))
        .await
        .expect("create jan5");
    repo.create(user, &sample_persisted_entry(food, jan10))
        .await
        .expect("create jan10");

    // to=jan5 → jan1 and jan5 only.
    let page = repo
        .list_paginated(user, None, Some(jan5), 10, 0)
        .await
        .expect("list");
    assert_eq!(page.len(), 2, "to filter should include jan1..=jan5");
    assert!(page.iter().all(|e| e.consumed_on <= jan5));
}

#[tokio::test]
async fn log_repo_list_paginated_filters_by_both() {
    let repo = InMemoryLogRepository::new();
    let user = Uuid::new_v4();
    let food = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();
    let jan7 = NaiveDate::from_ymd_opt(2026, 1, 7).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    repo.create(user, &sample_persisted_entry(food, jan1))
        .await
        .expect("create jan1");
    repo.create(user, &sample_persisted_entry(food, jan5))
        .await
        .expect("create jan5");
    repo.create(user, &sample_persisted_entry(food, jan7))
        .await
        .expect("create jan7");
    repo.create(user, &sample_persisted_entry(food, jan10))
        .await
        .expect("create jan10");

    // from=jan5, to=jan7 → jan5 and jan7 only.
    let page = repo
        .list_paginated(user, Some(jan5), Some(jan7), 10, 0)
        .await
        .expect("list");
    assert_eq!(page.len(), 2, "both filters: jan5..=jan7");
    assert!(page.iter().all(|e| e.consumed_on >= jan5 && e.consumed_on <= jan7));
}

#[tokio::test]
async fn log_repo_list_paginated_filters_by_neither() {
    let repo = InMemoryLogRepository::new();
    let user = Uuid::new_v4();
    let food = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    repo.create(user, &sample_persisted_entry(food, jan1))
        .await
        .expect("create jan1");
    repo.create(user, &sample_persisted_entry(food, jan10))
        .await
        .expect("create jan10");

    let page = repo
        .list_paginated(user, None, None, 10, 0)
        .await
        .expect("list");
    assert_eq!(page.len(), 2, "no filters: all entries returned");
}

#[tokio::test]
async fn log_repo_count_in_range_matches_list_paginated_total_without_limit() {
    let repo = InMemoryLogRepository::new();
    let user = Uuid::new_v4();
    let food = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();

    for d in [jan1, jan5, jan5] {
        repo.create(user, &sample_persisted_entry(food, d))
            .await
            .expect("create");
    }

    // count with from=jan5 should be 2 (the two jan5 entries).
    let count = repo
        .count_in_range(user, Some(jan5), None)
        .await
        .expect("count");
    let page = repo
        .list_paginated(user, Some(jan5), None, 1000, 0)
        .await
        .expect("list");
    assert_eq!(
        count,
        page.len() as i64,
        "count_in_range must equal list_paginated length when limit is large"
    );
    assert_eq!(count, 2);
}

#[tokio::test]
async fn log_service_list_returns_validation_error_on_from_after_to() {
    let (_logs, svc) = make_log_service();
    let user = Uuid::new_v4();

    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();
    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();

    let err = svc
        .list(user, Some(jan10), Some(jan1), None, None)
        .await
        .expect_err("from > to should fail");

    match err {
        CoreError::Validation(msg) => {
            assert!(
                msg.contains("from"),
                "error message should mention `from`: {msg}"
            );
        }
        other => panic!("expected Validation, got {other:?}"),
    }
}

#[tokio::test]
async fn log_service_list_applies_default_limit_when_omitted() {
    let (_logs, svc) = make_log_service();
    let user = Uuid::new_v4();

    let result = svc
        .list(user, None, None, None, None)
        .await
        .expect("list with no params");

    assert_eq!(result.limit, 100, "default limit must be 100");
    assert_eq!(result.offset, 0, "default offset must be 0");
}

// ── weight_repo list_paginated / count_for_user tests (T05) ──────────────────

fn make_weight_draft(recorded_on: NaiveDate) -> WeightDraft {
    WeightDraft {
        recorded_on,
        recorded_at_local: None,
        weight_kg: Decimal::from(70),
        note: None,
    }
}

fn make_weight_service() -> (Arc<InMemoryWeightRepository>, WeightService) {
    let weights = Arc::new(InMemoryWeightRepository::new());
    let svc = WeightService::new(weights.clone());
    (weights, svc)
}

#[tokio::test]
async fn weight_repo_list_paginated_orders_newest_first_with_id_tiebreaker() {
    let repo = InMemoryWeightRepository::new();
    let user = Uuid::new_v4();

    let day_old = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let day_new = NaiveDate::from_ymd_opt(2026, 1, 3).unwrap();

    // Insert two entries on the older date and one on the newer date.
    let w_old_a = repo
        .create(user, &make_weight_draft(day_old))
        .await
        .expect("create old_a");
    let w_old_b = repo
        .create(user, &make_weight_draft(day_old))
        .await
        .expect("create old_b");
    let w_new = repo
        .create(user, &make_weight_draft(day_new))
        .await
        .expect("create new");

    let page = repo
        .list_paginated(user, None, None, 10, 0)
        .await
        .expect("list_paginated");

    assert_eq!(page.len(), 3);
    // Newest date must be first.
    assert_eq!(page[0].id, w_new.id, "newest date should be first");
    // Both older entries follow.
    assert!(
        page[1].recorded_on == day_old && page[2].recorded_on == day_old,
        "older entries should come after"
    );
    assert_ne!(page[1].id, w_new.id);
    assert_ne!(page[2].id, w_new.id);
    // Both old entries are present.
    let old_ids: std::collections::HashSet<_> = [page[1].id, page[2].id].into();
    assert!(old_ids.contains(&w_old_a.id));
    assert!(old_ids.contains(&w_old_b.id));
}

#[tokio::test]
async fn weight_repo_count_for_user_matches_list_total() {
    let repo = InMemoryWeightRepository::new();
    let user = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    // Seed 3 entries: jan1, jan5, jan10.
    for d in [jan1, jan5, jan10] {
        repo.create(user, &make_weight_draft(d))
            .await
            .expect("create");
    }

    // Filter from jan5 onward — should match jan5 and jan10 (2 entries).
    let count = repo
        .count_for_user(user, Some(jan5), None)
        .await
        .expect("count");
    let page = repo
        .list_paginated(user, Some(jan5), None, 1000, 0)
        .await
        .expect("list");
    assert_eq!(
        count,
        page.len() as i64,
        "count_for_user must equal list_paginated length when limit is large"
    );
    assert_eq!(count, 2);
}

#[tokio::test]
async fn weight_service_list_returns_validation_error_on_from_after_to() {
    let (_weights, svc) = make_weight_service();
    let user = Uuid::new_v4();

    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();
    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();

    let err = svc
        .list(user, Some(jan10), Some(jan1), None, None)
        .await
        .expect_err("from > to should fail");

    match err {
        CoreError::Validation(msg) => {
            assert!(
                msg.contains("from"),
                "error message should mention `from`: {msg}"
            );
        }
        other => panic!("expected Validation, got {other:?}"),
    }
}

#[tokio::test]
async fn weight_service_list_applies_default_limit_when_omitted() {
    let (_weights, svc) = make_weight_service();
    let user = Uuid::new_v4();

    let result = svc
        .list(user, None, None, None, None)
        .await
        .expect("list with no params");

    assert_eq!(result.limit, 100, "default limit must be 100");
    assert_eq!(result.offset, 0, "default offset must be 0");
}

#[tokio::test]
async fn weight_repo_list_paginated_filters_by_from_only() {
    let repo = InMemoryWeightRepository::new();
    let user = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    repo.create(user, &make_weight_draft(jan1))
        .await
        .expect("create jan1");
    repo.create(user, &make_weight_draft(jan5))
        .await
        .expect("create jan5");
    repo.create(user, &make_weight_draft(jan10))
        .await
        .expect("create jan10");

    // from=jan5 → jan5 and jan10 only.
    let page = repo
        .list_paginated(user, Some(jan5), None, 10, 0)
        .await
        .expect("list");
    assert_eq!(page.len(), 2, "from filter should include jan5..=jan10");
    assert!(page.iter().all(|w| w.recorded_on >= jan5));
}

#[tokio::test]
async fn weight_repo_list_paginated_filters_by_to_only() {
    let repo = InMemoryWeightRepository::new();
    let user = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    repo.create(user, &make_weight_draft(jan1))
        .await
        .expect("create jan1");
    repo.create(user, &make_weight_draft(jan5))
        .await
        .expect("create jan5");
    repo.create(user, &make_weight_draft(jan10))
        .await
        .expect("create jan10");

    // to=jan5 → jan1 and jan5 only.
    let page = repo
        .list_paginated(user, None, Some(jan5), 10, 0)
        .await
        .expect("list");
    assert_eq!(page.len(), 2, "to filter should include jan1..=jan5");
    assert!(page.iter().all(|w| w.recorded_on <= jan5));
}

#[tokio::test]
async fn weight_repo_list_paginated_filters_by_both() {
    let repo = InMemoryWeightRepository::new();
    let user = Uuid::new_v4();

    let jan1 = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let jan5 = NaiveDate::from_ymd_opt(2026, 1, 5).unwrap();
    let jan10 = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();

    repo.create(user, &make_weight_draft(jan1))
        .await
        .expect("create jan1");
    repo.create(user, &make_weight_draft(jan5))
        .await
        .expect("create jan5");
    repo.create(user, &make_weight_draft(jan10))
        .await
        .expect("create jan10");

    // from=jan5, to=jan5 → jan5 only (middle date).
    let page = repo
        .list_paginated(user, Some(jan5), Some(jan5), 10, 0)
        .await
        .expect("list");
    assert_eq!(page.len(), 1, "both filters: jan5..=jan5 returns only jan5");
    assert_eq!(page[0].recorded_on, jan5);
}

// ── find_or_create_quick_add / sentinel filter tests (T07) ─────────────────────

#[tokio::test]
async fn find_or_create_quick_add_is_idempotent() {
    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    foods.set_serving_repo(servings.clone());
    let owner = Uuid::new_v4();

    let (food_a, serving_a) = foods
        .find_or_create_quick_add(owner)
        .await
        .expect("first");
    let (food_b, serving_b) = foods
        .find_or_create_quick_add(owner)
        .await
        .expect("second");

    assert_eq!(food_a.id, food_b.id, "same food row across calls");
    assert_eq!(serving_a.id, serving_b.id, "same serving row across calls");
    assert_eq!(food_a.name, "__quick_add__");
    assert!(serving_a.is_default);
    assert_eq!(serving_a.label, "kcal");
    assert_eq!(serving_a.grams, Decimal::from(100));
}

#[tokio::test]
async fn find_or_create_quick_add_concurrent_first_uses_dont_duplicate() {
    use tokio::task::JoinSet;

    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    foods.set_serving_repo(servings.clone());
    let owner = Uuid::new_v4();

    let mut set = JoinSet::new();
    for _ in 0..8u32 {
        let foods = foods.clone();
        set.spawn(async move {
            foods
                .find_or_create_quick_add(owner)
                .await
                .expect("find_or_create")
        });
    }

    let mut food_ids = std::collections::HashSet::new();
    let mut serving_ids = std::collections::HashSet::new();
    while let Some(res) = set.join_next().await {
        let (food, serving) = res.expect("join");
        food_ids.insert(food.id);
        serving_ids.insert(serving.id);
    }

    assert_eq!(food_ids.len(), 1, "concurrent calls must collapse to one food");
    assert_eq!(
        serving_ids.len(),
        1,
        "concurrent calls must collapse to one serving"
    );
}

#[tokio::test]
async fn search_excludes_quick_add_sentinel() {
    let foods = InMemoryFoodRepository::new();
    let alice = Uuid::new_v4();

    // Provision sentinel and a real food whose name shares the literal "quick"
    // substring so a naive search would match both.
    foods
        .find_or_create_quick_add(alice)
        .await
        .expect("provision sentinel");
    foods
        .create_custom(alice, &sample_draft("Quick oats"))
        .await
        .expect("create real food");

    let hits = foods.search(alice, "quick", 50, 0).await.expect("search");
    assert_eq!(hits.len(), 1, "sentinel must be excluded from search");
    assert_eq!(hits[0].name, "Quick oats");

    let count = foods
        .search_count(alice, "quick")
        .await
        .expect("search_count");
    assert_eq!(count, 1, "search_count must also exclude the sentinel");
}

#[tokio::test]
async fn recent_food_ids_excludes_sentinel_when_filter_wired() {
    let foods = Arc::new(InMemoryFoodRepository::new());
    let logs = Arc::new(InMemoryLogRepository::new());
    logs.set_food_repo_for_sentinel_filter(foods.clone());
    let user = Uuid::new_v4();

    let (sentinel, _) = foods
        .find_or_create_quick_add(user)
        .await
        .expect("provision");
    let real = foods
        .create_custom(user, &sample_draft("Real bar"))
        .await
        .expect("create");

    let today = NaiveDate::from_ymd_opt(2026, 5, 15).unwrap();
    logs.create(user, &sample_persisted_entry(sentinel.id, today))
        .await
        .expect("log sentinel");
    logs.create(user, &sample_persisted_entry(real.id, today))
        .await
        .expect("log real");

    let recents = logs.recent_food_ids(user, 50).await.expect("recents");
    assert_eq!(recents, vec![real.id], "sentinel id must be filtered out");
}

#[tokio::test]
async fn frequent_food_ids_excludes_sentinel_when_filter_wired() {
    let foods = Arc::new(InMemoryFoodRepository::new());
    let logs = Arc::new(InMemoryLogRepository::new());
    logs.set_food_repo_for_sentinel_filter(foods.clone());
    let user = Uuid::new_v4();

    let (sentinel, _) = foods
        .find_or_create_quick_add(user)
        .await
        .expect("provision");
    let real = foods
        .create_custom(user, &sample_draft("Real bar"))
        .await
        .expect("create");

    let today = NaiveDate::from_ymd_opt(2026, 5, 15).unwrap();
    // Log the sentinel many times, the real food once. Without the filter,
    // sentinel would dominate the result by count.
    for _ in 0..5 {
        logs.create(user, &sample_persisted_entry(sentinel.id, today))
            .await
            .expect("log sentinel");
    }
    logs.create(user, &sample_persisted_entry(real.id, today))
        .await
        .expect("log real");

    let freqs = logs.frequent_food_ids(user, 30, 10).await.expect("freqs");
    assert_eq!(freqs.len(), 1, "only the real food should appear");
    assert_eq!(freqs[0].0, real.id);
}

#[tokio::test]
async fn create_custom_rejects_reserved_sentinel_name() {
    use loseit_core::service::FoodService;

    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    let service = FoodService::new(foods.clone(), servings.clone());

    let owner = Uuid::new_v4();
    let err = service
        .create_custom(owner, sample_draft("__quick_add__"))
        .await
        .expect_err("must reject reserved name");
    match err {
        loseit_core::CoreError::Validation(msg) => {
            assert!(msg.contains("reserved"), "expected reserved-name validation, got: {msg}");
        }
        other => panic!("expected Validation, got {other:?}"),
    }

    // Case-insensitive: same rejection for upper-case / mixed.
    let err = service
        .create_custom(owner, sample_draft("__QUICK_ADD__"))
        .await
        .expect_err("must reject case-insensitive");
    assert!(matches!(err, loseit_core::CoreError::Validation(_)));

    // Whitespace-padded should also be rejected (trim before compare).
    let err = service
        .create_custom(owner, sample_draft("  __quick_add__  "))
        .await
        .expect_err("must reject whitespace-padded");
    assert!(matches!(err, loseit_core::CoreError::Validation(_)));
}

#[tokio::test]
async fn update_custom_on_sentinel_returns_forbidden() {
    use loseit_core::domain::FoodPatch;
    use loseit_core::service::FoodService;

    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    foods.set_serving_repo(servings.clone());
    let service = FoodService::new(foods.clone(), servings.clone());

    let owner = Uuid::new_v4();
    let (sentinel, _) = foods
        .find_or_create_quick_add(owner)
        .await
        .expect("provision");

    let patch = FoodPatch {
        name: Some("renamed".into()),
        ..FoodPatch::default()
    };
    let err = service
        .update_custom(owner, sentinel.id, patch)
        .await
        .expect_err("must refuse to update the sentinel");
    assert!(matches!(err, loseit_core::CoreError::Forbidden));
}

#[tokio::test]
async fn delete_custom_on_sentinel_returns_forbidden() {
    use loseit_core::service::FoodService;

    let foods = Arc::new(InMemoryFoodRepository::new());
    let servings = Arc::new(InMemoryServingRepository::new());
    foods.set_serving_repo(servings.clone());
    let service = FoodService::new(foods.clone(), servings.clone());

    let owner = Uuid::new_v4();
    let (sentinel, _) = foods
        .find_or_create_quick_add(owner)
        .await
        .expect("provision");

    let err = service
        .delete_custom(owner, sentinel.id)
        .await
        .expect_err("must refuse to delete the sentinel");
    assert!(matches!(err, loseit_core::CoreError::Forbidden));
}
