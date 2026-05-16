//! HTTP integration tests for log + day-summary + recent/frequent endpoints
//! (T14, T15, T16, T17).
//!
//! Mirrors `tests/http_foods.rs` — same `FakeAuthenticator` + in-memory
//! ports, plus a `build_test_app_with` seeder so each test can preload
//! foods, servings, and log entries. The seeder hands the test the
//! `InMemoryGoalRepository` too (T16 needs it to attach an active goal to
//! the day-summary response).

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use chrono::{NaiveDate, Utc};
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::domain::{
    FoodDraft, GoalDraft, Meal, NutritionPer100g, NutritionSnapshot, PersistedLogEntry,
    ServingDraft, ServingSource, UserIdentity,
};
use loseit_core::repo::{
    FoodRepository, GoalRepository, LogRepository, ServingRepository, UserRepository,
    WeightRepository,
};
use loseit_testing::{
    FakeAuthenticator, InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLogRepository,
    InMemoryServingRepository, InMemoryUserRepository, InMemoryWeightRepository,
};
use rust_decimal::Decimal;
use serde_json::Value;
use tower::ServiceExt;
use uuid::Uuid;

type SeedFuture = Pin<Box<dyn Future<Output = ()> + Send>>;

const TEST_TOKEN: &str = "test-token";

fn test_identity() -> UserIdentity {
    UserIdentity {
        issuer: "test".into(),
        external_id: "alice".into(),
        email: Some("alice@example.com".into()),
        display_name: Some("Alice".into()),
    }
}

/// Per-test app builder. The seed closure receives the concrete in-memory
/// repos plus the provisioned alice uuid. The goal repo is included so T16
/// tests can pre-seed an active goal.
async fn build_test_app_with<F>(setup: F) -> (axum::Router, Uuid)
where
    F: FnOnce(
        &Arc<InMemoryFoodRepository>,
        &Arc<InMemoryServingRepository>,
        &Arc<InMemoryLogRepository>,
        &Arc<InMemoryGoalRepository>,
        Uuid,
    ) -> SeedFuture,
{
    let users_concrete = Arc::new(InMemoryUserRepository::new());
    let foods_concrete = Arc::new(InMemoryFoodRepository::new());
    let servings_concrete = Arc::new(InMemoryServingRepository::new());
    let logs_concrete = Arc::new(InMemoryLogRepository::new());
    let goals_concrete = Arc::new(InMemoryGoalRepository::new());

    foods_concrete.set_serving_repo(servings_concrete.clone());
    // Wire sentinel filter unconditionally so recent/frequent always exclude
    // the quick-add sentinel when it exists. The wiring is harmless for tests
    // that never call quick_add (no sentinel rows → nothing to filter).
    logs_concrete.set_food_repo_for_sentinel_filter(foods_concrete.clone());

    let alice = users_concrete.create(&test_identity()).await.unwrap();

    setup(
        &foods_concrete,
        &servings_concrete,
        &logs_concrete,
        &goals_concrete,
        alice.id,
    )
    .await;

    let users: Arc<dyn UserRepository> = users_concrete;
    let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
    let goals: Arc<dyn GoalRepository> = goals_concrete;
    let foods: Arc<dyn FoodRepository> = foods_concrete;
    let servings: Arc<dyn ServingRepository> = servings_concrete;
    let logs: Arc<dyn LogRepository> = logs_concrete;
    let authn: Arc<dyn Authenticator> =
        Arc::new(FakeAuthenticator::new(TEST_TOKEN, test_identity()));
    let state = AppState::from_ports(users, weights, goals, foods, servings, logs, authn);
    (router(state), alice.id)
}

async fn read_json(body: Body) -> Value {
    let bytes = to_bytes(body, 64 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

fn authed_request(method: &str, uri: &str) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("Authorization", format!("Bearer {TEST_TOKEN}"))
        .body(Body::empty())
        .unwrap()
}

fn authed_json_request(method: &str, uri: &str, body: serde_json::Value) -> Request<Body> {
    let s = serde_json::to_vec(&body).unwrap();
    Request::builder()
        .method(method)
        .uri(uri)
        .header("Authorization", format!("Bearer {TEST_TOKEN}"))
        .header("content-type", "application/json")
        .body(Body::from(s))
        .unwrap()
}

// -- Seed helpers ------------------------------------------------------------

/// Seed a custom food owned by `owner` with the given per-100g calories and
/// a single default serving. Returns `(food_id, serving_id)`.
async fn seed_food_with_serving(
    foods: &Arc<InMemoryFoodRepository>,
    servings: &Arc<InMemoryServingRepository>,
    owner: Uuid,
    name: &str,
    energy_kcal_per_100g: Decimal,
    serving_grams: Decimal,
) -> (Uuid, Uuid) {
    let draft = FoodDraft {
        name: name.into(),
        brands: None,
        barcode: None,
        categories_tags: vec![],
        nutrition: NutritionPer100g {
            energy_kcal: Some(energy_kcal_per_100g),
            ..Default::default()
        },
        nutriscore_grade: None,
    };
    let food = foods.create_custom(owner, &draft).await.unwrap();
    let serving = servings
        .create(
            food.id,
            &ServingDraft {
                label: "1 portion".into(),
                grams: serving_grams,
                is_default: true,
                source: ServingSource::System,
                sort_order: 0,
            },
        )
        .await
        .unwrap();
    (food.id, serving.id)
}

// =============================================================================
// T14 — Service-level behaviour exercised via HTTP. (compute_snapshot unit
// tests live in `crates/loseit-core/src/service/log.rs` because the function
// is `pub(crate)`.)
// =============================================================================

#[tokio::test]
async fn test_log_create_uses_serving_grams_times_quantity() {
    // 1.5 portions of a 100 g serving (200 kcal/100 g) → 150 g, 300 kcal.
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Oats",
                Decimal::from(200),
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "breakfast",
        "quantity": "1.5",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["grams_total"], "150.00");
    assert_eq!(body["calories_kcal"], "300.00");
    assert_eq!(body["meal"], "breakfast");
    assert_eq!(body["food_id"], food_id.to_string());
    assert_eq!(body["serving_id"], serving_id.to_string());
}

#[tokio::test]
async fn test_log_create_rejects_serving_belonging_to_different_food() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_a, _serving_a) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Apple",
                Decimal::from(50),
                Decimal::from(100),
            )
            .await;
            let (_food_b, serving_b) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Banana",
                Decimal::from(90),
                Decimal::from(100),
            )
            .await;
            captured.set((food_a, serving_b)).unwrap();
        })
    })
    .await;
    let (food_a, serving_b) = *captured.get().unwrap();

    let body = serde_json::json!({
        "food_id": food_a,
        "serving_id": serving_b,
        "consumed_on": "2026-05-15",
        "meal": "lunch",
        "quantity": "1",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_log_create_404_for_unknown_food() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "food_id": Uuid::new_v4(),
        "serving_id": Uuid::new_v4(),
        "consumed_on": "2026-05-15",
        "meal": "lunch",
        "quantity": "1",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_log_create_404_for_other_users_custom_food() {
    // Custom food owned by Bob → invisible to Alice → 404.
    use std::sync::OnceLock;
    let bob = Uuid::new_v4();
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, _alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                bob,
                "Bob's Soup",
                Decimal::from(40),
                Decimal::from(250),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "dinner",
        "quantity": "1",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_log_create_400_for_quantity_zero() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Toast",
                Decimal::from(250),
                Decimal::from(30),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "breakfast",
        "quantity": "0",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_log_update_recomputes_snapshot_when_quantity_changes() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Pasta",
                Decimal::from(350),
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // Create entry with quantity=1 → 100 g, 350 kcal.
    let post = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "lunch",
        "quantity": "1",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", post))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let entry_id = body["id"].as_str().unwrap().to_string();
    assert_eq!(body["calories_kcal"], "350.00");

    // PATCH to quantity=2 → expect 200 g, 700 kcal.
    let patch = serde_json::json!({ "quantity": "2" });
    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/log/{entry_id}"),
            patch,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["grams_total"], "200.00");
    assert_eq!(body["calories_kcal"], "700.00");
}

// =============================================================================
// T15 — HTTP shape for /log endpoints.
// =============================================================================

#[tokio::test]
async fn test_post_log_persists_snapshot() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Rice",
                Decimal::from(130),
                Decimal::from(150),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-10",
        "meal": "dinner",
        "quantity": "1",
        "note": "leftovers",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    // 130 kcal/100g * 150g = 195 kcal.
    assert_eq!(body["calories_kcal"], "195.00");
    assert_eq!(body["grams_total"], "150.00");
    assert_eq!(body["note"], "leftovers");
    assert_eq!(body["consumed_on"], "2026-05-10");
    // Snapshot fields are flattened at the top level.
    assert!(body.get("snapshot").is_none());
}

#[tokio::test]
async fn test_get_log_filters_by_date_range_and_user() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Yogurt",
                Decimal::from(80),
                Decimal::from(150),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // Three entries on three different days.
    for day in &["2026-05-10", "2026-05-12", "2026-05-15"] {
        let body = serde_json::json!({
            "food_id": food_id,
            "serving_id": serving_id,
            "consumed_on": day,
            "meal": "snack",
            "quantity": "1",
        });
        let resp = app
            .clone()
            .oneshot(authed_json_request("POST", "/api/v1/log", body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    // Query a sub-window — expect 2 entries (12th + 15th, in newest-first
    // order).
    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/log?from=2026-05-12&to=2026-05-15",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let arr = body["results"].as_array().expect("results array");
    assert_eq!(arr.len(), 2);
    assert_eq!(body["total"], 2);
    assert_eq!(arr[0]["consumed_on"], "2026-05-15");
    assert_eq!(arr[1]["consumed_on"], "2026-05-12");
}

#[tokio::test]
async fn test_delete_log_204() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Apple",
                Decimal::from(52),
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "snack",
        "quantity": "1",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    let entry_id = body["id"].as_str().unwrap().to_string();

    let resp = app
        .oneshot(authed_request("DELETE", &format!("/api/v1/log/{entry_id}")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn test_patch_log_400_when_food_id_is_provided() {
    // food_id is immutable; sending it on PATCH is a client bug we surface
    // as 400 rather than silently ignoring.
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Bread",
                Decimal::from(265),
                Decimal::from(30),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    let post = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "breakfast",
        "quantity": "2",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", post))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    let entry_id = body["id"].as_str().unwrap().to_string();

    let patch = serde_json::json!({ "food_id": Uuid::new_v4() });
    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/log/{entry_id}"),
            patch,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// =============================================================================
// T16 — Day summary.
// =============================================================================

#[tokio::test]
async fn test_get_day_summary_aggregates_three_meals() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Plain Toast",
                Decimal::from(250),
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // One entry each for breakfast / lunch / dinner on the same day — snack
    // stays empty.
    for meal in &["breakfast", "lunch", "dinner"] {
        let body = serde_json::json!({
            "food_id": food_id,
            "serving_id": serving_id,
            "consumed_on": "2026-05-15",
            "meal": meal,
            "quantity": "1",
        });
        let resp = app
            .clone()
            .oneshot(authed_json_request("POST", "/api/v1/log", body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/days/2026-05-15/summary"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["date"], "2026-05-15");
    // 3 entries × 250 kcal = 750 kcal.
    assert_eq!(body["total"]["calories_kcal"], "750.00");
    // by_meal must always have 4 entries, snack with zero counts.
    let by_meal = body["by_meal"].as_array().expect("by_meal array");
    assert_eq!(by_meal.len(), 4);
    let snack = by_meal
        .iter()
        .find(|m| m["meal"] == "snack")
        .expect("snack slot present");
    assert_eq!(snack["entry_count"], 0);
    assert_eq!(snack["calories_kcal"], "0");
    for m in &["breakfast", "lunch", "dinner"] {
        let slot = by_meal
            .iter()
            .find(|s| s["meal"] == *m)
            .expect("meal slot present");
        assert_eq!(slot["entry_count"], 1);
        assert_eq!(slot["calories_kcal"], "250.00");
    }
}

#[tokio::test]
async fn test_get_day_summary_with_no_entries_returns_zero_totals() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/days/2026-05-15/summary"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"]["calories_kcal"], "0");
    // Optional macros are absent when no entry carried them.
    assert!(body["total"]["protein_g"].is_null());
    assert_eq!(body["by_meal"].as_array().unwrap().len(), 4);
    assert!(body["active_goal"].is_null());
}

#[tokio::test]
async fn test_get_day_summary_attaches_active_goal_or_none_when_no_goal() {
    use std::sync::OnceLock;
    // First, verify that with no goal seeded, active_goal is null.
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/days/2026-05-15/summary"))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    assert!(body["active_goal"].is_null());

    // Second, with a goal seeded that's active on the queried day, expect
    // the goal id to come through.
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |_foods, _servings, _logs, goals, alice| {
        let goals = goals.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let goal = goals
                .create(
                    alice,
                    &GoalDraft {
                        starts_on: NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
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
            captured.set(goal.id).unwrap();
        })
    })
    .await;
    let goal_id = *captured.get().unwrap();
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/days/2026-05-15/summary"))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["active_goal"]["id"], goal_id.to_string());
    assert_eq!(body["active_goal"]["daily_calorie_target"], 2200);
}

// =============================================================================
// T17 — Recent / frequent.
// =============================================================================

#[tokio::test]
async fn test_get_recent_foods_returns_lean_hits() {
    // Seed three distinct foods + one log entry per food, with controlled
    // created_at timestamps (most recent food is "C"). Then assert the
    // recent endpoint returns them in most-recent-first order.
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_a, _) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food A",
                Decimal::from(100),
                Decimal::from(100),
            )
            .await;
            let (food_b, _) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food B",
                Decimal::from(100),
                Decimal::from(100),
            )
            .await;
            let (food_c, _) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food C",
                Decimal::from(100),
                Decimal::from(100),
            )
            .await;
            captured.set((food_a, food_b, food_c)).unwrap();

            // Log entries in order A, B, C — `created_at = Utc::now()` so C
            // gets the latest timestamp.
            for fid in [food_a, food_b, food_c] {
                let entry = PersistedLogEntry {
                    food_id: fid,
                    serving_id: None,
                    consumed_on: NaiveDate::from_ymd_opt(2026, 5, 15).unwrap(),
                    meal: Meal::Lunch,
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
                };
                logs.create(alice, &entry).await.unwrap();
                // Force a measurable gap so ordering is deterministic.
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
            }
        })
    })
    .await;
    let (a, b, c) = *captured.get().unwrap();

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/recent"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let arr = body.as_array().expect("array");
    let ids: Vec<String> = arr
        .iter()
        .map(|h| h["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids.len(), 3);
    assert_eq!(ids[0], c.to_string(), "most recent food first");
    assert_eq!(ids[1], b.to_string());
    assert_eq!(ids[2], a.to_string());
    // Each hit must carry the lean fields.
    for hit in arr {
        assert!(hit.get("name").is_some());
        assert!(hit.get("source").is_some());
        assert!(hit.get("default_serving").is_some());
    }
}

#[tokio::test]
async fn test_get_frequent_foods_orders_by_count_descending() {
    // Log 3× food A, 2× food B, 1× food C — repo returns them ordered by
    // count desc.
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_a, _) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food A",
                Decimal::from(100),
                Decimal::from(100),
            )
            .await;
            let (food_b, _) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food B",
                Decimal::from(100),
                Decimal::from(100),
            )
            .await;
            let (food_c, _) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food C",
                Decimal::from(100),
                Decimal::from(100),
            )
            .await;
            captured.set((food_a, food_b, food_c)).unwrap();

            let today = Utc::now().date_naive();
            // Use today's date so they fall inside FREQUENT_WINDOW_DAYS=30.
            let log_n = |fid: Uuid, times: usize| {
                let logs = logs.clone();
                async move {
                    for _ in 0..times {
                        let entry = PersistedLogEntry {
                            food_id: fid,
                            serving_id: None,
                            consumed_on: today,
                            meal: Meal::Snack,
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
                        };
                        logs.create(alice, &entry).await.unwrap();
                    }
                }
            };
            log_n(food_a, 3).await;
            log_n(food_b, 2).await;
            log_n(food_c, 1).await;
        })
    })
    .await;
    let (a, b, c) = *captured.get().unwrap();

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/frequent"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let arr = body.as_array().expect("array");
    let ids: Vec<String> = arr
        .iter()
        .map(|h| h["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(ids, vec![a.to_string(), b.to_string(), c.to_string()]);
}

#[tokio::test]
async fn test_recent_foods_respects_limit() {
    // Seed 5 foods, log all of them, request limit=2 → expect 2 results.
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            for i in 0..5 {
                let (fid, _) = seed_food_with_serving(
                    &foods,
                    &servings,
                    alice,
                    &format!("Food {i}"),
                    Decimal::from(100),
                    Decimal::from(100),
                )
                .await;
                let entry = PersistedLogEntry {
                    food_id: fid,
                    serving_id: None,
                    consumed_on: NaiveDate::from_ymd_opt(2026, 5, 15).unwrap(),
                    meal: Meal::Snack,
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
                };
                logs.create(alice, &entry).await.unwrap();
                tokio::time::sleep(std::time::Duration::from_millis(2)).await;
            }
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/recent?limit=2"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let arr = body.as_array().expect("array");
    assert_eq!(arr.len(), 2);
}

// =============================================================================
// T08 — POST /log/quick_add.
// =============================================================================

#[tokio::test]
async fn quick_add_creates_entry_with_only_calories() {
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "250",
        "meal": "snack",
        "consumed_on": "2024-01-15",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    // quantity == calories_kcal. The in-memory store round-trips the Decimal
    // parsed from the wire ("250") without rescaling, so the serialized value
    // preserves the input precision (NUMERIC columns in Postgres would store
    // it with scale=0 as-is for an integer input).
    assert_eq!(body["quantity"], "250");
    assert_eq!(body["calories_kcal"], "250.00");
    assert_eq!(body["grams_total"], "25000.00");
    assert_eq!(body["meal"], "snack");
    assert_eq!(body["consumed_on"], "2024-01-15");
    // All macros must be null.
    assert!(body["protein_g"].is_null());
    assert!(body["carbs_g"].is_null());
    assert!(body["fat_g"].is_null());
    assert!(body["fiber_g"].is_null());
    assert!(body["sugar_g"].is_null());
    assert!(body["sodium_mg"].is_null());
    assert!(body["saturated_fat_g"].is_null());
    // No nested snapshot field.
    assert!(body.get("snapshot").is_none());
}

#[tokio::test]
async fn quick_add_is_repeatable_for_same_user() {
    // Second call returns 201 with a *different* id but the same food_id.
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "100",
        "meal": "breakfast",
        "consumed_on": "2024-01-15",
    });
    let resp1 = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body.clone()))
        .await
        .unwrap();
    assert_eq!(resp1.status(), StatusCode::CREATED);
    let body1 = read_json(resp1.into_body()).await;

    let resp2 = app
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp2.status(), StatusCode::CREATED);
    let body2 = read_json(resp2.into_body()).await;

    // Different entry ids.
    assert_ne!(body1["id"], body2["id"]);
    // Same sentinel food_id (sentinel was reused, not recreated).
    assert_eq!(body1["food_id"], body2["food_id"]);
}

#[tokio::test]
async fn quick_add_400_on_zero_calories() {
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "0",
        "meal": "lunch",
        "consumed_on": "2024-01-15",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn quick_add_400_on_negative_calories() {
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "-50",
        "meal": "dinner",
        "consumed_on": "2024-01-15",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn quick_add_400_on_max_calories_overflow() {
    // 9_999 is the first value that should reject with the calories-specific
    // message. Values < 10_000 that reach the grams_total guard instead would
    // give a generic message; the bound is intentionally set below 10_000 so
    // callers always see the calories error.
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "9999",
        "meal": "snack",
        "consumed_on": "2024-01-15",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = read_json(resp.into_body()).await;
    assert!(
        body["message"].as_str().unwrap_or("").contains("calories_kcal must be less than 9999"),
        "expected calories-specific error, got: {body}"
    );
}

#[tokio::test]
async fn quick_add_400_on_invalid_meal() {
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "300",
        "meal": "elevenses",
        "consumed_on": "2024-01-15",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn quick_add_does_not_appear_in_food_search() {
    // After quick_add, searching for "quick" or the sentinel name should
    // return an empty result.
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    // Trigger quick_add to provision the sentinel food.
    let body = serde_json::json!({
        "calories_kcal": "150",
        "meal": "snack",
        "consumed_on": "2024-01-15",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    // Search for "quick" — should return no results.
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/search?q=quick"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().expect("results array");
    assert!(
        results.is_empty(),
        "sentinel food must not appear in search results"
    );
}

// =============================================================================
// T04 — GET /log paginated envelope.
// =============================================================================

/// Seed `count` log entries for `alice` on consecutive dates starting from
/// `2026-01-01`, returning `(food_id, serving_id)`.
async fn seed_entries_for_list(
    foods: &Arc<InMemoryFoodRepository>,
    servings: &Arc<InMemoryServingRepository>,
    logs: &Arc<InMemoryLogRepository>,
    alice: Uuid,
    count: usize,
) -> (Uuid, Uuid) {
    let (food_id, serving_id) = seed_food_with_serving(
        foods,
        servings,
        alice,
        "ListFood",
        Decimal::from(100),
        Decimal::from(100),
    )
    .await;
    for i in 0..count {
        let day = NaiveDate::from_ymd_opt(2026, 1, 1 + i as u32).unwrap();
        let entry = PersistedLogEntry {
            food_id,
            serving_id: Some(serving_id),
            consumed_on: day,
            meal: Meal::Lunch,
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
        };
        logs.create(alice, &entry).await.unwrap();
    }
    (food_id, serving_id)
}

#[tokio::test]
async fn test_list_returns_paginated_envelope_with_no_params() {
    // Seed 3 entries; GET /log with no params → envelope with total=3,
    // limit=100, offset=0.
    let (app, _alice) = build_test_app_with(|foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            seed_entries_for_list(&foods, &servings, &logs, alice, 3).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/log"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 3);
    assert_eq!(body["limit"], 100);
    assert_eq!(body["offset"], 0);
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 3);
}

#[tokio::test]
async fn test_list_paginates_within_full_total() {
    // Seed 5 entries; ?limit=2&offset=2 returns 2 results, total=5.
    let (app, _alice) = build_test_app_with(|foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            seed_entries_for_list(&foods, &servings, &logs, alice, 5).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/log?limit=2&offset=2"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 5);
    assert_eq!(body["limit"], 2);
    assert_eq!(body["offset"], 2);
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 2);
}

#[tokio::test]
async fn test_list_400_when_from_after_to() {
    let (app, _alice) =
        build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/log?from=2026-02-01&to=2026-01-01",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_list_accepts_from_only() {
    // Seed 2 entries; ?from=2026-01-02 returns only the second one.
    let (app, _alice) = build_test_app_with(|foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            seed_entries_for_list(&foods, &servings, &logs, alice, 2).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/log?from=2026-01-02"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 1);
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["consumed_on"], "2026-01-02");
}

#[tokio::test]
async fn test_list_accepts_to_only() {
    // Seed 2 entries; ?to=2026-01-01 returns only the first one.
    let (app, _alice) = build_test_app_with(|foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            seed_entries_for_list(&foods, &servings, &logs, alice, 2).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/log?to=2026-01-01"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 1);
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["consumed_on"], "2026-01-01");
}

#[tokio::test]
async fn test_list_orders_newest_consumed_first_then_newest_created_at() {
    // Seed 3 entries on 2026-01-03, 2026-01-01, 2026-01-02 (in that
    // creation order). Expect the response in reverse consumed_on order:
    // 2026-01-03, 2026-01-02, 2026-01-01.
    let (app, _alice) = build_test_app_with(|foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "OrderFood",
                Decimal::from(100),
                Decimal::from(100),
            )
            .await;
            for day_num in [3u32, 1, 2] {
                let day = NaiveDate::from_ymd_opt(2026, 1, day_num).unwrap();
                let entry = PersistedLogEntry {
                    food_id,
                    serving_id: Some(serving_id),
                    consumed_on: day,
                    meal: Meal::Lunch,
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
                };
                logs.create(alice, &entry).await.unwrap();
            }
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/log"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 3);
    assert_eq!(results[0]["consumed_on"], "2026-01-03");
    assert_eq!(results[1]["consumed_on"], "2026-01-02");
    assert_eq!(results[2]["consumed_on"], "2026-01-01");
}
