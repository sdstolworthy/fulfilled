//! HTTP integration tests for log + day-summary + recent/frequent endpoints
//! (T13 rewrite — per-serving wire shape).
//!
//! All `grams_total` assertions have been removed (D6). Every log-create /
//! log-patch body now uses `entered_amount` + `entered_unit` instead of
//! `quantity`. New tests cover round-trips, cross-family 400s, within-family
//! volume conversion, Count cross-unit 400, quick_add entered_unit, and the
//! R3 PATCH-serving-id regression.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use chrono::{NaiveDate, Utc};
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::domain::{
    FoodDraft, GoalDraft, Meal, NutritionSnapshot, PersistedLogEntry,
    ServingDraft, ServingSource, UserIdentity,
};
use loseit_core::domain::unit::Unit;
use loseit_core::repo::{
    FoodRepository, GoalRepository, LogRepository, ServingRepository, UserRepository,
    WeightRepository,
};
use loseit_testing::{
    FakeAuthenticator, InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLogRepository,
    InMemoryServingRepository, InMemoryUserFoodSummaryReader, InMemoryUserRepository,
    InMemoryWeightRepository,
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
/// tests can pre-seed an active goal to the day-summary response.
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
    // the quick-add sentinel when it exists.
    logs_concrete.set_food_repo_for_sentinel_filter(foods_concrete.clone());
    // Wire serving repo so every list/create path populates serving_name.
    logs_concrete.set_serving_repo(servings_concrete.clone());

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
    let summary_reader: Arc<dyn loseit_core::service::UserFoodSummaryReader> =
        Arc::new(InMemoryUserFoodSummaryReader::new(logs_concrete.clone()));
    let logs: Arc<dyn LogRepository> = logs_concrete;
    let authn: Arc<dyn Authenticator> =
        Arc::new(FakeAuthenticator::new(TEST_TOKEN, test_identity()));
    let state = AppState::from_ports(
        users,
        weights,
        goals,
        foods,
        servings,
        logs,
        summary_reader,
        authn,
        None,
        None,
        false,
        false,
    );
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

/// Seed a custom food owned by `owner` with a single default serving at
/// `{amount, unit, kcal_per_serving}`. Returns `(food_id, serving_id)`.
async fn seed_food_with_serving(
    foods: &Arc<InMemoryFoodRepository>,
    servings: &Arc<InMemoryServingRepository>,
    owner: Uuid,
    name: &str,
    kcal_per_serving: Decimal,
    serving_unit: Unit,
    serving_amount: Decimal,
) -> (Uuid, Uuid) {
    let draft = FoodDraft {
        name: name.into(),
        brands: None,
        barcode: None,
        fdc_id: None,
        data_type: None,
        categories_tags: vec![],
        nutriscore_grade: None,
        servings: vec![],
    };
    let serving_draft = ServingDraft {
        label: Some("1 portion".into()),
        amount: serving_amount,
        unit: serving_unit,
        kcal: kcal_per_serving,
        protein_g: None,
        carbs_g: None,
        fat_g: None,
        fiber_g: None,
        sugar_g: None,
        sodium_mg: None,
        saturated_fat_g: None,
        is_default: true,
        source: ServingSource::System,
        sort_order: 0,
    };
    let food = foods
        .create_custom_with_servings(owner, &draft, vec![serving_draft])
        .await
        .unwrap();
    // Fetch the serving id from the serving repo.
    let all_servings = servings.list_for_food(food.id).await.unwrap();
    let serving = all_servings
        .into_iter()
        .find(|s| s.is_default)
        .expect("default serving must exist after seeding");
    (food.id, serving.id)
}

// =============================================================================
// T14 — Service-level behaviour exercised via HTTP.
// =============================================================================

#[tokio::test]
async fn test_log_create_uses_serving_kcal_times_quantity() {
    // 1 serving of a 300-kcal serving → 300 kcal.
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
                Decimal::from(300),
                Unit::Gram,
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
        "entered_amount": "100",
        "entered_unit": "g",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["calories_kcal"], "300.00");
    assert_eq!(body["meal"], "breakfast");
    assert_eq!(body["food_id"], food_id.to_string());
    assert_eq!(body["serving_id"], serving_id.to_string());
    // No grams_total on the wire (D6).
    assert!(body.get("grams_total").is_none());
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
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let (_food_b, serving_b) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Banana",
                Decimal::from(90),
                Unit::Gram,
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
        "entered_amount": "1",
        "entered_unit": "g",
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
        "entered_amount": "1",
        "entered_unit": "g",
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
                Unit::Gram,
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
        "entered_amount": "1",
        "entered_unit": "g",
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
                Unit::Gram,
                Decimal::from(30),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // entered_amount of 0 drives quantity to 0, which the service rejects.
    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "breakfast",
        "entered_amount": "0",
        "entered_unit": "g",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_log_update_recomputes_snapshot_when_entered_amount_changes() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            // 350 kcal per 100 g serving.
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Pasta",
                Decimal::from(350),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // Create entry: 100 g → quantity=1 → 350 kcal.
    let post = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "lunch",
        "entered_amount": "100",
        "entered_unit": "g",
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

    // PATCH: change to 200 g → quantity=2 → 700 kcal.
    let patch = serde_json::json!({
        "entered_amount": "200",
        "entered_unit": "g",
    });
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
    assert_eq!(body["calories_kcal"], "700.00");
    // No grams_total field.
    assert!(body.get("grams_total").is_none());
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
            // 195 kcal per 1 serving (serving unit = gram, amount = 150g, kcal = 195).
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Rice",
                Decimal::from(195),
                Unit::Gram,
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
        "entered_amount": "150",
        "entered_unit": "g",
        "note": "leftovers",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    // 150 g / 150 g serving = quantity 1.0; 1.0 × 195 kcal = 195 kcal.
    assert_eq!(body["calories_kcal"], "195.00");
    assert_eq!(body["note"], "leftovers");
    assert_eq!(body["consumed_on"], "2026-05-10");
    // No grams_total field (D6).
    assert!(body.get("grams_total").is_none());
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
                Decimal::from(120),
                Unit::Gram,
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
            "entered_amount": "150",
            "entered_unit": "g",
        });
        let resp = app
            .clone()
            .oneshot(authed_json_request("POST", "/api/v1/log", body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    // Query a sub-window — expect 2 entries (12th + 15th, newest-first).
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
                Unit::Gram,
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
        "entered_amount": "100",
        "entered_unit": "g",
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
    // food_id is immutable; sending it on PATCH surfaces a 400.
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
                Unit::Gram,
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
        "entered_amount": "30",
        "entered_unit": "g",
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
            // 250 kcal per 1 serving (serving unit gram, 100g amount).
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Plain Toast",
                Decimal::from(250),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // One entry each for breakfast / lunch / dinner.
    for meal in &["breakfast", "lunch", "dinner"] {
        let body = serde_json::json!({
            "food_id": food_id,
            "serving_id": serving_id,
            "consumed_on": "2026-05-15",
            "meal": meal,
            "entered_amount": "100",
            "entered_unit": "g",
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
    assert!(body["total"]["protein_g"].is_null());
    assert_eq!(body["by_meal"].as_array().unwrap().len(), 4);
    assert!(body["active_goal"].is_null());
}

#[tokio::test]
async fn test_get_day_summary_attaches_active_goal_or_none_when_no_goal() {
    use std::sync::OnceLock;
    // First: no goal → active_goal is null.
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/days/2026-05-15/summary"))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    assert!(body["active_goal"].is_null());

    // Second: with an active goal seeded.
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
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_a, serving_a) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food A",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let (food_b, serving_b) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food B",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let (food_c, serving_c) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food C",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((food_a, food_b, food_c)).unwrap();

            // Log entries in order A, B, C.
            for (fid, sid) in [(food_a, serving_a), (food_b, serving_b), (food_c, serving_c)] {
                let entry = PersistedLogEntry {
                    food_id: fid,
                    serving_id: Some(sid),
                    consumed_on: NaiveDate::from_ymd_opt(2026, 5, 15).unwrap(),
                    meal: Meal::Lunch,
                    quantity: Decimal::from(1),
                    entered_amount: Decimal::from(100),
                    entered_unit: Unit::Gram,
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
    for hit in arr {
        assert!(hit.get("name").is_some());
        assert!(hit.get("source").is_some());
        assert!(hit.get("default_serving").is_some());
    }
}

#[tokio::test]
async fn test_recent_foods_kcal_is_per_serving() {
    // A 200-kcal/1-cup serving → the hit's default_serving.kcal must be 200.
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            let (fid, sid) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Dense Food",
                Decimal::from(200),
                Unit::Cup,
                Decimal::from(1),
            )
            .await;
            let entry = PersistedLogEntry {
                food_id: fid,
                serving_id: Some(sid),
                consumed_on: NaiveDate::from_ymd_opt(2026, 5, 15).unwrap(),
                meal: Meal::Dinner,
                quantity: Decimal::from(1),
                entered_amount: Decimal::from(1),
                entered_unit: Unit::Cup,
                snapshot: NutritionSnapshot {
                    calories_kcal: Decimal::from(200),
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
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/recent"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let arr = body.as_array().expect("array");
    assert_eq!(arr.len(), 1);
    let hit = &arr[0];
    // The serving preview carries kcal directly — no per-100g math.
    let kcal_str = hit["default_serving"]["kcal"]
        .as_str()
        .expect("default_serving.kcal is a string");
    let kcal_val: rust_decimal::Decimal = kcal_str
        .parse()
        .expect("kcal parses as Decimal");
    assert_eq!(kcal_val, Decimal::from(200), "kcal must equal the serving's 200");
}

#[tokio::test]
async fn test_get_frequent_foods_orders_by_count_descending() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_a, serving_a) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food A",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let (food_b, serving_b) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food B",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let (food_c, serving_c) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food C",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((food_a, food_b, food_c)).unwrap();

            let today = Utc::now().date_naive();
            let log_n = |fid: Uuid, sid: Uuid, times: usize| {
                let logs = logs.clone();
                async move {
                    for _ in 0..times {
                        let entry = PersistedLogEntry {
                            food_id: fid,
                            serving_id: Some(sid),
                            consumed_on: today,
                            meal: Meal::Snack,
                            quantity: Decimal::from(1),
                            entered_amount: Decimal::from(100),
                            entered_unit: Unit::Gram,
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
            log_n(food_a, serving_a, 3).await;
            log_n(food_b, serving_b, 2).await;
            log_n(food_c, serving_c, 1).await;
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
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        Box::pin(async move {
            for i in 0..5 {
                let (fid, sid) = seed_food_with_serving(
                    &foods,
                    &servings,
                    alice,
                    &format!("Food {i}"),
                    Decimal::from(100),
                    Unit::Gram,
                    Decimal::from(100),
                )
                .await;
                let entry = PersistedLogEntry {
                    food_id: fid,
                    serving_id: Some(sid),
                    consumed_on: NaiveDate::from_ymd_opt(2026, 5, 15).unwrap(),
                    meal: Meal::Snack,
                    quantity: Decimal::from(1),
                    entered_amount: Decimal::from(100),
                    entered_unit: Unit::Gram,
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
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

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
    assert_eq!(body["calories_kcal"], "250.00");
    assert_eq!(body["meal"], "snack");
    assert_eq!(body["consumed_on"], "2024-01-15");
    // No grams_total (D6).
    assert!(body.get("grams_total").is_none());
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
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "100",
        "meal": "breakfast",
        "consumed_on": "2024-01-15",
    });
    let resp1 = app
        .clone()
        .oneshot(authed_json_request(
            "POST",
            "/api/v1/log/quick_add",
            body.clone(),
        ))
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

    assert_ne!(body1["id"], body2["id"]);
    assert_eq!(body1["food_id"], body2["food_id"]);
}

#[tokio::test]
async fn quick_add_400_on_zero_calories() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

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
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

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
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

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
        body["message"]
            .as_str()
            .unwrap_or("")
            .contains("calories_kcal must be less than 9999"),
        "expected calories-specific error, got: {body}"
    );
}

#[tokio::test]
async fn quick_add_400_on_invalid_meal() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

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
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

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
        Unit::Gram,
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
            entered_amount: Decimal::from(100),
            entered_unit: Unit::Gram,
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
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

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
                Unit::Gram,
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
                    entered_amount: Decimal::from(100),
                    entered_unit: Unit::Gram,
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

// =============================================================================
// T10 — POST /log/copy.
// =============================================================================

#[tokio::test]
async fn copy_day_recomputes_snapshot_from_current_serving_not_source_snapshot() {
    // Seed alice's custom food + serving at 50 kcal/serving. Log on day 1
    // (snapshot frozen at 50). Swap serving list to 100 kcal/serving. Copy
    // day 1 → day 2 and assert day 2's snapshot uses the *current* serving.
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Arc<InMemoryServingRepository>)>> =
        Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Mystery Stew",
                Decimal::from(50),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured
                .set((food_id, serving_id, servings.clone()))
                .ok()
                .expect("OnceLock not set yet");
        })
    })
    .await;
    let (food_id, serving_id, servings_repo) = captured.get().unwrap().clone();

    // Create the day-1 entry while the food is still at 50 kcal.
    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "breakfast",
        "entered_amount": "100",
        "entered_unit": "g",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["calories_kcal"], "50.00");

    // Update just the kcal on the *existing* serving (preserves serving_id so
    // the log entry's FK is not NULLed). The day-1 frozen snapshot stays at 50,
    // but copy_day re-snapshots from the *current* serving.
    use loseit_core::domain::ServingPatch;
    servings_repo
        .update(
            serving_id,
            &ServingPatch {
                kcal: Some(Decimal::from(100)),
                ..ServingPatch::default()
            },
        )
        .await
        .unwrap();

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let copied = body["copied"].as_array().expect("copied array");
    assert_eq!(copied.len(), 1);
    // 100 kcal/100g × 100g → 100 kcal (the *new* value, not the frozen 50).
    assert_eq!(copied[0]["calories_kcal"], "100.00");
    assert_eq!(copied[0]["consumed_on"], "2026-05-16");
}

#[tokio::test]
async fn copy_day_filters_by_meal() {
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
                "Cereal",
                Decimal::from(60),
                Unit::Gram,
                Decimal::from(50),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    for meal in &["breakfast", "lunch"] {
        let body = serde_json::json!({
            "food_id": food_id,
            "serving_id": serving_id,
            "consumed_on": "2026-05-15",
            "meal": meal,
            "entered_amount": "50",
            "entered_unit": "g",
        });
        let resp = app
            .clone()
            .oneshot(authed_json_request("POST", "/api/v1/log", body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
        "meal": "breakfast",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let copied = body["copied"].as_array().expect("copied array");
    assert_eq!(copied.len(), 1);
    assert_eq!(copied[0]["meal"], "breakfast");
    assert_eq!(copied[0]["consumed_on"], "2026-05-16");

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/log?from=2026-05-16&to=2026-05-16",
        ))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().expect("results");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["meal"], "breakfast");
}

#[tokio::test]
async fn copy_day_allows_same_day_copy_duplicating_entries() {
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
                "Sandwich",
                Decimal::from(250),
                Unit::Gram,
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
        "meal": "lunch",
        "entered_amount": "100",
        "entered_unit": "g",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-15",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["copied"].as_array().unwrap().len(), 1);

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/log?from=2026-05-15&to=2026-05-15",
        ))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 2);
}

#[tokio::test]
async fn copy_day_allows_backward_copy() {
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
                "Salad",
                Decimal::from(80),
                Unit::Gram,
                Decimal::from(200),
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
        "consumed_on": "2026-05-20",
        "meal": "dinner",
        "entered_amount": "200",
        "entered_unit": "g",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let copy = serde_json::json!({
        "from_date": "2026-05-20",
        "to_date": "2026-05-10",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let copied = body["copied"].as_array().expect("copied array");
    assert_eq!(copied.len(), 1);
    assert_eq!(copied[0]["consumed_on"], "2026-05-10");
}

#[tokio::test]
async fn copy_day_empty_source_returns_empty_copied_array() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert!(body["copied"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn copy_day_skips_entries_with_deleted_serving() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Arc<InMemoryServingRepository>)>> =
        Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, _default_serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Pancakes",
                Decimal::from(200),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            // Second, non-default serving — deletable.
            let extra = servings
                .create(
                    food_id,
                    &ServingDraft {
                        label: Some("big stack".into()),
                        amount: Decimal::from(250),
                        unit: Unit::Gram,
                        kcal: Decimal::from(500),
                        protein_g: None,
                        carbs_g: None,
                        fat_g: None,
                        fiber_g: None,
                        sugar_g: None,
                        sodium_mg: None,
                        saturated_fat_g: None,
                        is_default: false,
                        source: ServingSource::User,
                        sort_order: 1,
                    },
                )
                .await
                .unwrap();
            captured
                .set((food_id, extra.id, servings.clone()))
                .ok()
                .expect("OnceLock not set yet");
        })
    })
    .await;
    let (food_id, extra_serving_id, servings) = captured.get().unwrap().clone();

    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": extra_serving_id,
        "consumed_on": "2026-05-15",
        "meal": "breakfast",
        "entered_amount": "250",
        "entered_unit": "g",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    servings.delete(extra_serving_id).await.unwrap();

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert!(body["copied"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn copy_day_response_includes_only_inserted_entries() {
    use std::sync::OnceLock;
    let bob = Uuid::new_v4();
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let logs = logs.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (alice_food, alice_serving) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Alice's Food",
                Decimal::from(200),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let (bob_food, bob_serving) = seed_food_with_serving(
                &foods,
                &servings,
                bob,
                "Bob's Food",
                Decimal::from(200),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((alice_food, alice_serving)).unwrap();

            for (food_id, serving_id) in [(alice_food, alice_serving), (bob_food, bob_serving)] {
                let entry = PersistedLogEntry {
                    food_id,
                    serving_id: Some(serving_id),
                    consumed_on: NaiveDate::from_ymd_opt(2026, 5, 15).unwrap(),
                    meal: Meal::Lunch,
                    quantity: Decimal::from(1),
                    entered_amount: Decimal::from(100),
                    entered_unit: Unit::Gram,
                    snapshot: NutritionSnapshot {
                        calories_kcal: Decimal::from(200),
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
    let (alice_food, alice_serving) = *captured.get().unwrap();

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let copied = body["copied"].as_array().expect("copied array");
    assert_eq!(copied.len(), 1);
    assert_eq!(copied[0]["food_id"], alice_food.to_string());
    assert_eq!(copied[0]["serving_id"], alice_serving.to_string());
}

#[tokio::test]
async fn copy_day_coexists_with_existing_destination_entries() {
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
                "Rice Bowl",
                Decimal::from(150),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    for day in &["2026-05-15", "2026-05-16"] {
        let body = serde_json::json!({
            "food_id": food_id,
            "serving_id": serving_id,
            "consumed_on": day,
            "meal": "lunch",
            "entered_amount": "100",
            "entered_unit": "g",
        });
        let resp = app
            .clone()
            .oneshot(authed_json_request("POST", "/api/v1/log", body))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["copied"].as_array().unwrap().len(), 1);

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/log?from=2026-05-16&to=2026-05-16",
        ))
        .await
        .unwrap();
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 2);
}

#[tokio::test]
async fn copy_day_three_entries_preserve_input_order() {
    use std::sync::OnceLock;
    type ThreePairs = ((Uuid, Uuid), (Uuid, Uuid), (Uuid, Uuid));
    let captured: Arc<OnceLock<ThreePairs>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let pair_a = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food A",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let pair_b = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food B",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            let pair_c = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Food C",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((pair_a, pair_b, pair_c)).unwrap();
        })
    })
    .await;
    let ((food_a, serving_a), (food_b, serving_b), (food_c, serving_c)) = *captured.get().unwrap();

    for (fid, sid) in [
        (food_a, serving_a),
        (food_b, serving_b),
        (food_c, serving_c),
    ] {
        let post = serde_json::json!({
            "food_id": fid,
            "serving_id": sid,
            "consumed_on": "2026-05-15",
            "meal": "snack",
            "entered_amount": "100",
            "entered_unit": "g",
        });
        let resp = app
            .clone()
            .oneshot(authed_json_request("POST", "/api/v1/log", post))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let copied = body["copied"].as_array().expect("copied array");
    assert_eq!(copied.len(), 3);
    assert_eq!(copied[0]["food_id"], food_a.to_string());
    assert_eq!(copied[1]["food_id"], food_b.to_string());
    assert_eq!(copied[2]["food_id"], food_c.to_string());
}

#[tokio::test]
async fn copy_day_400_on_invalid_meal() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
        "meal": "elevenses",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn copy_day_replicates_quick_add_entries_with_same_calories() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let qa_body = serde_json::json!({
        "calories_kcal": "350",
        "meal": "lunch",
        "consumed_on": "2026-05-15",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request(
            "POST",
            "/api/v1/log/quick_add",
            qa_body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let qa_entry = read_json(resp.into_body()).await;
    let original_calories = qa_entry["calories_kcal"].clone();
    let original_quantity = qa_entry["quantity"].clone();
    assert!(qa_entry["protein_g"].is_null());
    assert!(qa_entry["carbs_g"].is_null());
    assert!(qa_entry["fat_g"].is_null());

    let copy = serde_json::json!({
        "from_date": "2026-05-15",
        "to_date": "2026-05-16",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/copy", copy))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let copied = body["copied"].as_array().expect("copied array");
    assert_eq!(copied.len(), 1, "expected exactly one copied entry");

    assert_eq!(copied[0]["calories_kcal"], original_calories);
    assert_eq!(copied[0]["quantity"], original_quantity);
    assert_eq!(copied[0]["consumed_on"], "2026-05-16");
    assert!(copied[0]["protein_g"].is_null());
    assert!(copied[0]["carbs_g"].is_null());
    assert!(copied[0]["fat_g"].is_null());
}

// =============================================================================
// T04 — food_name + serving_name in GET /log response.
// =============================================================================

#[tokio::test]
async fn list_log_entries_include_food_name_and_serving_name() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let draft = FoodDraft {
                name: "Tomato paste".into(),
                brands: None,
                barcode: None,
                fdc_id: None,
                data_type: None,
                categories_tags: vec![],
                nutriscore_grade: None,
                servings: vec![],
            };
            let serving_draft = ServingDraft {
                label: Some("100 g".into()),
                amount: Decimal::from(100),
                unit: Unit::Gram,
                kcal: Decimal::from(82),
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                sugar_g: None,
                sodium_mg: None,
                saturated_fat_g: None,
                is_default: true,
                source: ServingSource::System,
                sort_order: 0,
            };
            let food = foods
                .create_custom_with_servings(alice, &draft, vec![serving_draft])
                .await
                .unwrap();
            let all_servings = servings.list_for_food(food.id).await.unwrap();
            let serving = all_servings
                .into_iter()
                .find(|s| s.is_default)
                .expect("default serving");
            captured.set((food.id, serving.id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "lunch",
        "entered_amount": "100",
        "entered_unit": "g",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/log?from=2026-05-15&to=2026-05-15",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["food_name"], "Tomato paste");
    assert_eq!(results[0]["serving_name"], "100 g");
}

#[tokio::test]
async fn list_log_entries_quick_add_has_no_serving_name() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "100",
        "meal": "snack",
        "consumed_on": "2026-05-15",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/log?from=2026-05-15&to=2026-05-15",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 1);
    assert!(
        !results[0]["food_name"]
            .as_str()
            .unwrap_or("")
            .is_empty(),
        "food_name must be non-empty for a quick_add entry"
    );
    // The sentinel serving has label = None (nullable per new schema), so
    // serving_name may be null. The important thing is food_name is non-empty.
    // (serving_name null is correct when the serving has no label.)
}

// =============================================================================
// T13 — New per-serving wire-shape tests (§8, §10 R2, R3).
// =============================================================================

/// `entered_amount` + `entered_unit` round-trip through POST /log.
#[tokio::test]
async fn log_create_entered_amount_unit_round_trips() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            // Seed a custom food + volumetric serving: {amount: 1, unit: cup, kcal: 200}.
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Olive Oil",
                Decimal::from(200),
                Unit::Cup,
                Decimal::from(1),
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
        "entered_amount": "1",
        "entered_unit": "cup",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    // entered fields must be echoed verbatim.
    assert_eq!(body["entered_amount"], "1");
    assert_eq!(body["entered_unit"], "cup");
    // quantity = 1 cup / 1 cup = 1.
    assert_eq!(body["quantity"], "1.000");
    // kcal = 1 × 200 = 200.
    assert_eq!(body["calories_kcal"], "200.00");
    // No grams_total.
    assert!(body.get("grams_total").is_none());
}

/// Cross-family POST /log returns 400 with code "unit_family_mismatch".
#[tokio::test]
async fn log_create_cross_family_returns_400_unit_family_mismatch() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            // Volumetric serving.
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Milk",
                Decimal::from(200),
                Unit::Cup,
                Decimal::from(1),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // entered_unit "g" (Mass) against a Cup (Volume) serving → mismatch.
    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "breakfast",
        "entered_amount": "200",
        "entered_unit": "g",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = read_json(resp.into_body()).await;
    assert_eq!(
        body["code"], "unit_family_mismatch",
        "expected unit_family_mismatch code, got: {body}"
    );
}

/// Within-family Volume conversion: 4 fl_oz / 1 cup = 0.5 quantity, 100 kcal.
///
/// Math (§10 R2 + §4.1):
///   entered_canonical = 4 × 29.5735295625 ml = 118.294118250 ml
///   serving_canonical = 1 × 236.5882365   ml = 236.5882365   ml
///   quantity = 118.294118250 / 236.5882365 = 0.5 (exact).
///   calories_kcal = 0.5 × 200 = 100.
#[tokio::test]
async fn log_create_volume_within_family_converts_correctly() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            // Serving: {amount: 1, unit: cup, kcal: 200}.
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Cream",
                Decimal::from(200),
                Unit::Cup,
                Decimal::from(1),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // POST with 4 fl_oz: within Volume family, converts to 0.5 × 1-cup serving.
    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "snack",
        "entered_amount": "4",
        "entered_unit": "fl_oz",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    // quantity = 0.500 (exact Decimal result, rounded to NUMERIC(8,3)).
    assert_eq!(
        body["quantity"], "0.500",
        "4 fl_oz / 1 cup should give quantity=0.500, got: {}",
        body["quantity"]
    );
    // calories_kcal = 0.500 × 200 = 100.00.
    assert_eq!(body["calories_kcal"], "100.00");
    assert_eq!(body["entered_unit"], "fl_oz");
    assert_eq!(body["entered_amount"], "4");
}

/// Count cross-unit: "piece" against a "serving" serving → 400
/// (Count members are siblings, not interconvertible — §5.1 step 4).
#[tokio::test]
async fn log_create_count_cross_unit_returns_400() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            // Count-family serving: {amount: 1, unit: serving, kcal: 50}.
            let (food_id, serving_id) = seed_food_with_serving(
                &foods,
                &servings,
                alice,
                "Cookie",
                Decimal::from(50),
                Unit::Serving,
                Decimal::from(1),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // entered_unit "piece" against a "serving" serving → both Count, but
    // different units → unit_family_mismatch.
    let body = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "snack",
        "entered_amount": "1",
        "entered_unit": "piece",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = read_json(resp.into_body()).await;
    assert_eq!(
        body["code"], "unit_family_mismatch",
        "piece vs serving should give unit_family_mismatch, got: {body}"
    );
}

/// quick_add response must carry entered_amount = calories_kcal,
/// entered_unit = "serving" (D1 mechanic).
#[tokio::test]
async fn log_quick_add_returns_entered_unit_serving() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _g, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "100",
        "meal": "snack",
        "consumed_on": "2026-05-15",
    });
    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    // D1: entered_amount = calories_kcal, entered_unit = "serving".
    assert_eq!(body["entered_unit"], "serving");
    // entered_amount is the numeric value "100" (Decimal serialised without scale).
    let ea: rust_decimal::Decimal = body["entered_amount"]
        .as_str()
        .expect("entered_amount is a string")
        .parse()
        .expect("entered_amount parses as Decimal");
    assert_eq!(ea, rust_decimal::Decimal::from(100));
    assert_eq!(body["calories_kcal"], "100.00");
}

/// R3 regression: PATCH serving_id to a different-family serving without
/// updating entered_unit must return 400 unit_family_mismatch.
#[tokio::test]
async fn log_patch_serving_id_to_cross_family_returns_400() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _logs, _goals, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            // Single food with two servings: one Volume (cup), one Mass (g).
            let draft = FoodDraft {
                name: "Dual Serving Food".into(),
                brands: None,
                barcode: None,
                fdc_id: None,
                data_type: None,
                categories_tags: vec![],
                nutriscore_grade: None,
                servings: vec![],
            };
            let vol_draft = ServingDraft {
                label: Some("1 cup".into()),
                amount: Decimal::from(1),
                unit: Unit::Cup,
                kcal: Decimal::from(200),
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                sugar_g: None,
                sodium_mg: None,
                saturated_fat_g: None,
                is_default: true,
                source: ServingSource::User,
                sort_order: 0,
            };
            let food = foods
                .create_custom_with_servings(alice, &draft, vec![vol_draft])
                .await
                .unwrap();
            // Add the mass serving separately.
            let mass_serving = servings
                .create(
                    food.id,
                    &ServingDraft {
                        label: Some("100 g".into()),
                        amount: Decimal::from(100),
                        unit: Unit::Gram,
                        kcal: Decimal::from(80),
                        protein_g: None,
                        carbs_g: None,
                        fat_g: None,
                        fiber_g: None,
                        sugar_g: None,
                        sodium_mg: None,
                        saturated_fat_g: None,
                        is_default: false,
                        source: ServingSource::User,
                        sort_order: 1,
                    },
                )
                .await
                .unwrap();
            // Fetch the cup serving id.
            let all = servings.list_for_food(food.id).await.unwrap();
            let vol_id = all
                .into_iter()
                .find(|s| s.is_default)
                .expect("default cup serving")
                .id;
            captured.set((food.id, vol_id, mass_serving.id)).unwrap();
        })
    })
    .await;
    let (food_id, vol_serving_id, mass_serving_id) = *captured.get().unwrap();

    // Create entry against the volumetric serving (entered_unit = cup).
    let post = serde_json::json!({
        "food_id": food_id,
        "serving_id": vol_serving_id,
        "consumed_on": "2026-05-15",
        "meal": "lunch",
        "entered_amount": "1",
        "entered_unit": "cup",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", post))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created = read_json(resp.into_body()).await;
    let entry_id = created["id"].as_str().unwrap().to_string();

    // PATCH: swap serving_id to the mass serving WITHOUT changing entered_unit.
    // The existing entered_unit="cup" (Volume) now conflicts with the new
    // serving's unit="g" (Mass) → 400 unit_family_mismatch.
    let patch = serde_json::json!({ "serving_id": mass_serving_id });
    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/log/{entry_id}"),
            patch,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = read_json(resp.into_body()).await;
    assert_eq!(
        body["code"], "unit_family_mismatch",
        "cross-family serving swap should give unit_family_mismatch, got: {body}"
    );
}

/// GET /log response must include entered_amount and entered_unit;
/// must NOT include grams_total (D6).
#[tokio::test]
async fn log_list_response_has_entered_fields_no_grams_total() {
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
                "Test Food",
                Decimal::from(100),
                Unit::Gram,
                Decimal::from(100),
            )
            .await;
            captured.set((food_id, serving_id)).unwrap();
        })
    })
    .await;
    let (food_id, serving_id) = *captured.get().unwrap();

    // Seed one entry via POST.
    let post = serde_json::json!({
        "food_id": food_id,
        "serving_id": serving_id,
        "consumed_on": "2026-05-15",
        "meal": "lunch",
        "entered_amount": "100",
        "entered_unit": "g",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log", post))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    // GET /log and inspect the shape.
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/log?from=2026-05-15&to=2026-05-15"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 1);
    let entry = &results[0];
    // entered_amount and entered_unit must be present.
    assert!(
        entry.get("entered_amount").is_some(),
        "entered_amount must be present in GET /log results"
    );
    assert!(
        entry.get("entered_unit").is_some(),
        "entered_unit must be present in GET /log results"
    );
    assert_eq!(entry["entered_unit"], "g");
    // grams_total must NOT be present (D6).
    assert!(
        entry.get("grams_total").is_none(),
        "grams_total must NOT appear in GET /log results (D6)"
    );
}
