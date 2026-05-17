//! HTTP integration tests for the `/foods/*` endpoints (T12 rewrite).
//!
//! Mirrors `tests/http.rs` — same `FakeAuthenticator` + in-memory ports —
//! but exposes a `build_test_app_with` seeder so each test can preload
//! foods + servings into the in-memory repos before the router is built.
//!
//! Per-serving wire shape (T09 / T11): `POST /foods` body carries a
//! `servings` array (≥1) instead of a `nutrition` object. Every response
//! serving carries `{amount, unit, kcal, …}`.
//!
//! NOTE: `InMemoryFoodRepository::search` is a substring matcher; the
//! production CTE-then-rank SQL in `PgFoodRepository::search` is NOT
//! exercised here. These tests verify handler/service behaviour — query
//! validation, pagination, visibility — not Postgres ranking quality.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::domain::{FoodDraft, UserIdentity};
use loseit_core::domain::unit::Unit;
use loseit_core::domain::{ServingDraft, ServingSource};
use loseit_core::repo::{
    FoodDraftWithServings, FoodRepository, GoalRepository, LogRepository, ServingRepository,
    UserRepository, WeightRepository,
};
use loseit_testing::{
    FakeAuthenticator, InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLogRepository,
    InMemoryServingRepository, InMemoryUserRepository, InMemoryWeightRepository,
};
use rust_decimal::Decimal;
use serde_json::Value;
use tower::ServiceExt;
use uuid::Uuid;

/// Local stand-in for `futures::future::BoxFuture` so this test file
/// doesn't need a new dependency.
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

/// Build the test app, running `setup` to seed repos before wiring the router.
/// Returns both the router and alice's user id.
async fn build_test_app_with<F>(setup: F) -> (axum::Router, Uuid)
where
    F: FnOnce(
        &Arc<InMemoryFoodRepository>,
        &Arc<InMemoryServingRepository>,
        &Arc<InMemoryLogRepository>,
        Uuid,
    ) -> SeedFuture,
{
    let users_concrete = Arc::new(InMemoryUserRepository::new());
    let foods_concrete = Arc::new(InMemoryFoodRepository::new());
    let servings_concrete = Arc::new(InMemoryServingRepository::new());
    let logs_concrete = Arc::new(InMemoryLogRepository::new());

    // Pair the food repo with the serving repo so `upsert_external_food_batch`
    // also materializes servings — the production wiring does the same.
    foods_concrete.set_serving_repo(servings_concrete.clone());

    // Provision the alice user up front so seeding closures can reference
    // her uuid.
    let alice = users_concrete.create(&test_identity()).await.unwrap();

    setup(
        &foods_concrete,
        &servings_concrete,
        &logs_concrete,
        alice.id,
    )
    .await;

    let users: Arc<dyn UserRepository> = users_concrete;
    let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
    let goals: Arc<dyn GoalRepository> = Arc::new(InMemoryGoalRepository::new());
    let foods: Arc<dyn FoodRepository> = foods_concrete;
    let servings: Arc<dyn ServingRepository> = servings_concrete;
    let logs: Arc<dyn LogRepository> = logs_concrete;
    let authn: Arc<dyn Authenticator> =
        Arc::new(FakeAuthenticator::new(TEST_TOKEN, test_identity()));
    let state = AppState::from_ports(users, weights, goals, foods, servings, logs, authn, None, None, false, false);
    (router(state), alice.id)
}

async fn read_json(body: Body) -> Value {
    let bytes = to_bytes(body, 64 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

// -- Seed helpers ------------------------------------------------------------

/// Seed an OFF food + a default cup serving + a 100g serving via
/// `upsert_external_food_batch`. Returns the food id (looked up via
/// `find_by_barcode` because the batch call only returns counts).
async fn seed_off_food(
    foods: &Arc<InMemoryFoodRepository>,
    barcode: &str,
    name: &str,
    brands: Option<&str>,
) -> Uuid {
    seed_off_food_with_kcal(foods, barcode, name, brands, Decimal::new(120, 0)).await
}

/// Like `seed_off_food` but lets the caller pin the default serving's
/// `kcal`. Used by F1 regression coverage so the test can assert on a
/// known top-level `calories_per_serving` value.
async fn seed_off_food_with_kcal(
    foods: &Arc<InMemoryFoodRepository>,
    barcode: &str,
    name: &str,
    brands: Option<&str>,
    kcal: Decimal,
) -> Uuid {
    let batch_id = Uuid::new_v4();
    let rec = FoodDraftWithServings {
        draft: FoodDraft {
            name: name.into(),
            brands: brands.map(|s| s.into()),
            barcode: Some(barcode.into()),
            fdc_id: None,
            data_type: None,
            categories_tags: vec![],
            nutriscore_grade: None,
            servings: vec![],
        },
        quality_score: 50,
        servings: vec![
            ServingDraft {
                label: Some("1 cup".into()),
                amount: Decimal::new(1, 0),
                unit: Unit::Cup,
                kcal,
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                sugar_g: None,
                sodium_mg: None,
                saturated_fat_g: None,
                is_default: true,
                source: ServingSource::Off,
                sort_order: 0,
            },
            ServingDraft {
                label: Some("100 g".into()),
                amount: Decimal::new(100, 0),
                unit: Unit::Gram,
                kcal,
                protein_g: None,
                carbs_g: None,
                fat_g: None,
                fiber_g: None,
                sugar_g: None,
                sodium_mg: None,
                saturated_fat_g: None,
                is_default: false,
                source: ServingSource::System,
                sort_order: 1,
            },
        ],
    };
    foods
        .upsert_external_food_batch(batch_id, vec![rec])
        .await
        .unwrap();

    // Visibility is global for OFF foods so any viewer id will resolve it.
    let any_viewer = Uuid::nil();
    foods
        .find_by_barcode(any_viewer, barcode)
        .await
        .unwrap()
        .expect("just inserted")
        .id
}

/// Create a user-custom food with a single default serving.
async fn seed_custom_food(foods: &Arc<InMemoryFoodRepository>, owner: Uuid, name: &str) -> Uuid {
    let draft = FoodDraft {
        name: name.into(),
        brands: None,
        barcode: None,
        fdc_id: None,
        data_type: None,
        categories_tags: vec![],
        nutriscore_grade: None,
        servings: vec![ServingDraft {
            label: Some("1 serving".into()),
            amount: Decimal::new(1, 0),
            unit: Unit::Serving,
            kcal: Decimal::new(100, 0),
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
        }],
    };
    foods
        .create_custom_with_servings(owner, &draft, draft.servings.clone())
        .await
        .unwrap()
        .id
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

// -- Tests: GET /foods/:id ---------------------------------------------------

#[tokio::test]
async fn test_get_food_by_id_returns_detail_with_servings() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "1111", "Greek Yogurt", Some("Fage")).await;
        })
    })
    .await;

    // Discover the food id via barcode.
    let resp = app
        .clone()
        .oneshot(authed_request("GET", "/api/v1/foods/barcode/1111"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let id = body["id"].as_str().unwrap().to_string();

    let resp = app
        .oneshot(authed_request("GET", &format!("/api/v1/foods/{id}")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["name"], "Greek Yogurt");
    assert_eq!(body["source"], "off");
    let servings = body["servings"].as_array().expect("servings array");
    // OFF seed materializes both the "1 cup" OFF serving and the 100g system
    // serving — total 2.
    assert_eq!(servings.len(), 2, "expected 2 servings from OFF seed");
    // Each serving carries the per-serving wire fields.
    for s in servings {
        assert!(s.get("amount").is_some());
        assert!(s.get("unit").is_some());
        assert!(s.get("kcal").is_some());
    }
}

#[tokio::test]
async fn test_get_food_by_id_404_for_unknown() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let missing = Uuid::new_v4();
    let resp = app
        .oneshot(authed_request("GET", &format!("/api/v1/foods/{missing}")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_get_food_by_id_400_for_non_uuid() {
    // F2-T2: lock-in for axum's `Path<Uuid>` rejection behaviour. A
    // non-UUID path segment (e.g. `"new"`) is rejected with 400 *before*
    // `get_by_id` ever runs — the `PathRejection` short-circuits with
    // axum's default plaintext body. The FE relies on this distinction
    // post-F2-T1 (its FriendlyError mapper treats 400 and 404 the same
    // way for this route, but the BE contract must stay 400 so a future
    // "helpful" refactor that switches to 404 doesn't silently flip the
    // shape the FE depends on).
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/new"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_get_food_by_id_404_when_custom_owned_by_other_user() {
    use std::sync::OnceLock;
    let other_user = Uuid::new_v4();
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, _s, _l, _u| {
        let foods = foods.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let id = seed_custom_food(&foods, other_user, "Bob's Smoothie").await;
            captured.set(id).unwrap();
        })
    })
    .await;
    let bobs_food_id = *captured.get().unwrap();

    let resp = app
        .oneshot(authed_request(
            "GET",
            &format!("/api/v1/foods/{bobs_food_id}"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// -- Tests: GET /foods/barcode/:barcode --------------------------------------

#[tokio::test]
async fn test_get_food_by_barcode_returns_off_food() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "5901234123457", "Mozzarella", Some("Galbani")).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/barcode/5901234123457"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["name"], "Mozzarella");
    assert_eq!(body["barcode"], "5901234123457");
    assert_eq!(body["source"], "off");
}

#[tokio::test]
async fn test_get_food_by_barcode_404_for_missing() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/barcode/000000"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// -- Tests: GET /foods/search -----------------------------------------------

#[tokio::test]
async fn test_search_returns_lean_hits() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "10001", "Greek Yogurt", Some("Fage")).await;
            seed_off_food(&foods, "10002", "Vanilla Yogurt", Some("Chobani")).await;
            seed_off_food(&foods, "10003", "Yogurt Drink", Some("Activia")).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/search?q=yogurt"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().expect("results array");
    assert!(!results.is_empty(), "expected at least one hit");
    // Each hit must carry the lean fields, including the default serving.
    for hit in results {
        assert!(hit.get("id").is_some());
        assert!(hit.get("name").is_some());
        assert!(hit.get("source").is_some());
        assert!(hit.get("default_serving").is_some());
        // F1 (audit §2.1): `calories_per_serving` is a TOP-LEVEL field on
        // every hit, always present in the JSON (null when no default
        // serving). Use `as_object().contains_key` to assert
        // presence-as-null rather than absence.
        assert!(
            hit.as_object()
                .expect("hit is a JSON object")
                .contains_key("calories_per_serving"),
            "hit missing top-level calories_per_serving key: {hit}",
        );
        // When the food has a default serving, the top-level kcal must
        // also be non-null (both come from the same Option<ServingPreview>).
        if hit
            .get("default_serving")
            .map(|v| !v.is_null())
            .unwrap_or(false)
        {
            assert!(
                !hit["calories_per_serving"].is_null(),
                "hit has default_serving but top-level calories_per_serving is null: {hit}",
            );
        }
    }
    assert_eq!(body["limit"], 100);
    assert_eq!(body["offset"], 0);
}

#[tokio::test]
async fn test_search_emits_calories_per_serving_at_top_level() {
    // Regression: F1 / audit §2.1. The Flutter client reads
    // `calories_per_serving` at the row level, NOT `default_serving.kcal`.
    // Seed a food with a known per-serving kcal and confirm the wire
    // shape carries the value at both the top level (contract) and the
    // nested back-compat location.
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food_with_kcal(
                &foods,
                "F1-001",
                "Test Food",
                Some("Brand"),
                Decimal::new(123, 0),
            )
            .await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/search?q=Test"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let hit = &body["results"][0];

    // The top-level field is the contract.
    assert!(
        hit.as_object()
            .expect("hit is a JSON object")
            .contains_key("calories_per_serving"),
        "hit missing calories_per_serving key: {hit}",
    );
    assert_eq!(
        hit["calories_per_serving"].as_str().unwrap_or(""),
        "123",
        "top-level calories_per_serving must equal the default serving's kcal",
    );
    // Nested field retained for back-compat (FE may still read either).
    assert_eq!(
        hit["default_serving"]["kcal"].as_str().unwrap_or(""),
        "123",
        "default_serving.kcal must still mirror the top-level field",
    );
}

#[tokio::test]
async fn test_search_emits_calories_per_serving_as_null_when_no_default_serving() {
    // Null-case companion to F1-T1: a food with no servings must emit
    // BOTH `default_serving == null` AND `calories_per_serving == null`,
    // with both keys present in the JSON (presence-as-null, not absence).
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            let batch_id = Uuid::new_v4();
            let rec = FoodDraftWithServings {
                draft: FoodDraft {
                    name: "Servingless Mystery".into(),
                    brands: None,
                    barcode: Some("F1-002".into()),
                    fdc_id: None,
                    data_type: None,
                    categories_tags: vec![],
                    nutriscore_grade: None,
                    servings: vec![],
                },
                quality_score: 50,
                servings: vec![],
            };
            foods
                .upsert_external_food_batch(batch_id, vec![rec])
                .await
                .unwrap();
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/foods/search?q=Servingless",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let hit = &body["results"][0];
    let obj = hit.as_object().expect("hit is a JSON object");
    assert!(
        obj.contains_key("default_serving"),
        "default_serving key must be present: {hit}",
    );
    assert!(
        obj.contains_key("calories_per_serving"),
        "calories_per_serving key must be present: {hit}",
    );
    assert!(
        hit["default_serving"].is_null(),
        "default_serving must be JSON null: {hit}",
    );
    assert!(
        hit["calories_per_serving"].is_null(),
        "calories_per_serving must be JSON null: {hit}",
    );
}

#[tokio::test]
async fn test_recent_foods_includes_calories_per_serving_at_top_level() {
    // F1-T1 coverage for /foods/recent — the home-screen path. The
    // route reuses `FoodSearchHitResponse` via the same `From` impl, so
    // a single presence-of-key assertion is enough to lock in the
    // contract for this handler.
    use chrono::NaiveDate;
    use loseit_core::domain::unit::Unit as DomainUnit;
    use loseit_core::domain::{Meal, NutritionSnapshot, PersistedLogEntry};
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();

    let (app, _alice) = build_test_app_with(move |foods, _s, logs, alice| {
        let foods = foods.clone();
        let logs = logs.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let id = seed_off_food_with_kcal(
                &foods,
                "F1-003",
                "Recent Yogurt",
                Some("Brand"),
                Decimal::new(140, 0),
            )
            .await;
            captured.set(id).unwrap();

            // recent_foods sorts by the most recent log entry's
            // consumed_on; one entry is enough to surface the food.
            let entry = PersistedLogEntry {
                food_id: id,
                serving_id: None,
                consumed_on: NaiveDate::from_ymd_opt(2026, 5, 10).unwrap(),
                meal: Meal::Breakfast,
                quantity: Decimal::from(1),
                entered_amount: Decimal::from(1),
                entered_unit: DomainUnit::Serving,
                snapshot: NutritionSnapshot {
                    calories_kcal: Decimal::from(140),
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
    let results = body.as_array().expect("recent returns a JSON array");
    assert!(!results.is_empty(), "expected at least one recent hit");
    let hit = &results[0];
    assert!(
        hit.as_object()
            .expect("hit is a JSON object")
            .contains_key("calories_per_serving"),
        "recent hit missing top-level calories_per_serving key: {hit}",
    );
    assert_eq!(
        hit["calories_per_serving"].as_str().unwrap_or(""),
        "140",
        "recent hit top-level kcal must equal the default serving's kcal",
    );
}

#[tokio::test]
async fn test_foods_search_default_limit_is_now_100() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "20001", "Apple", Some("Brand")).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/search?q=Apple"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["limit"], 100);
}

#[tokio::test]
async fn test_foods_search_clamps_limit_at_500() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "30001", "Banana", Some("Brand")).await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/foods/search?q=Banana&limit=10000",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["limit"], 500);
}

#[tokio::test]
async fn test_search_respects_limit_and_offset() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            for i in 0..5 {
                seed_off_food(
                    &foods,
                    &format!("apple-{i}"),
                    &format!("Apple {i}"),
                    Some("Brand"),
                )
                .await;
            }
        })
    })
    .await;

    let resp = app
        .clone()
        .oneshot(authed_request(
            "GET",
            "/api/v1/foods/search?q=Apple&limit=2&offset=0",
        ))
        .await
        .unwrap();
    let page1 = read_json(resp.into_body()).await;
    assert_eq!(page1["limit"], 2);
    assert_eq!(page1["offset"], 0);
    assert_eq!(page1["results"].as_array().unwrap().len(), 2);

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/foods/search?q=Apple&limit=2&offset=2",
        ))
        .await
        .unwrap();
    let page2 = read_json(resp.into_body()).await;
    assert_eq!(page2["offset"], 2);
    let p1_ids: Vec<&str> = page1["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap())
        .collect();
    let p2_ids: Vec<&str> = page2["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_str().unwrap())
        .collect();
    for id in &p2_ids {
        assert!(!p1_ids.contains(id), "pagination must not overlap");
    }
}

#[tokio::test]
async fn test_search_total_count_is_independent_of_pagination() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            for i in 0..5 {
                seed_off_food(
                    &foods,
                    &format!("milk-{i}"),
                    &format!("Milk {i}"),
                    Some("Brand"),
                )
                .await;
            }
        })
    })
    .await;

    let r1 = app
        .clone()
        .oneshot(authed_request(
            "GET",
            "/api/v1/foods/search?q=Milk&limit=2&offset=0",
        ))
        .await
        .unwrap();
    let r2 = app
        .clone()
        .oneshot(authed_request(
            "GET",
            "/api/v1/foods/search?q=Milk&limit=2&offset=2",
        ))
        .await
        .unwrap();
    let r3 = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/foods/search?q=Milk&limit=50&offset=0",
        ))
        .await
        .unwrap();
    let b1 = read_json(r1.into_body()).await;
    let b2 = read_json(r2.into_body()).await;
    let b3 = read_json(r3.into_body()).await;
    assert_eq!(b1["total"], 5);
    assert_eq!(b2["total"], 5);
    assert_eq!(b3["total"], 5);
}

#[tokio::test]
async fn test_search_excludes_other_users_customs() {
    let other_user = Uuid::new_v4();
    let (app, _alice) = build_test_app_with(move |foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            // OFF food alice should see.
            seed_off_food(&foods, "barcode-x", "Banana", Some("Dole")).await;
            // Custom food owned by ANOTHER user — alice must not see it.
            seed_custom_food(&foods, other_user, "Banana Bread Loaf").await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/search?q=Banana"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let names: Vec<&str> = body["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["name"].as_str().unwrap())
        .collect();
    assert!(names.iter().any(|n| n.contains("Banana")));
    assert!(
        !names.iter().any(|n| n.contains("Bread")),
        "must not include another user's custom"
    );
    assert_eq!(body["total"], 1);
}

#[tokio::test]
async fn test_search_rejects_blank_query() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let resp = app
        .clone()
        .oneshot(authed_request("GET", "/api/v1/foods/search?q="))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/search?q=%20%20"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// -- Tests: POST /foods (T12 per-serving wire) --------------------------------

#[tokio::test]
async fn food_create_with_volumetric_serving_round_trips() {
    // POST /foods with a volumetric serving → 201; response echoes the
    // serving with the same fields.
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "Test smoothie",
        "servings": [
            {"amount": 1, "unit": "cup", "kcal": 180}
        ]
    });

    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/foods", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert!(body["id"].as_str().is_some(), "must return id");
    assert_eq!(body["name"], "Test smoothie");
    assert_eq!(body["source"], "user");
    let servings = body["servings"].as_array().expect("servings array");
    assert_eq!(servings.len(), 1);
    // Decimal serializes as a JSON string (e.g. "1", "180").
    assert_eq!(servings[0]["amount"].as_str().unwrap_or(""), "1");
    assert_eq!(servings[0]["unit"], "cup");
    assert_eq!(servings[0]["kcal"].as_str().unwrap_or(""), "180");
}

#[tokio::test]
async fn food_create_empty_servings_returns_400() {
    // POST /foods with an empty servings array → 400 (service validation).
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "No Servings Food",
        "servings": []
    });

    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/foods", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn food_create_serving_missing_kcal_returns_400() {
    // Serving body with no `kcal` field → serde/axum extractor rejects it
    // because `kcal: Decimal` is required (non-optional in ServingBody).
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "Missing kcal",
        "servings": [
            {"amount": 1, "unit": "serving"}
        ]
    });

    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/foods", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn food_create_serving_macros_optional() {
    // POST /foods with a serving that only supplies kcal (no macros) → 201;
    // the response's protein_g / carbs_g / fat_g fields are null.
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "Kcal Only Food",
        "servings": [
            {"amount": 100, "unit": "g", "kcal": 250}
        ]
    });

    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/foods", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    let servings = body["servings"].as_array().expect("servings array");
    assert_eq!(servings.len(), 1);
    assert!(servings[0]["protein_g"].is_null(), "protein_g must be null");
    assert!(servings[0]["carbs_g"].is_null(), "carbs_g must be null");
    assert!(servings[0]["fat_g"].is_null(), "fat_g must be null");
}

#[tokio::test]
async fn food_patch_servings_full_list_replace() {
    // PATCH /foods/{id} with a new servings list → 200; old servings gone,
    // new ones present.
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    // Create the food with one serving.
    let create_body = serde_json::json!({
        "name": "Patch Test Food",
        "servings": [
            {"amount": 1, "unit": "serving", "kcal": 100}
        ]
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/foods", create_body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created = read_json(resp.into_body()).await;
    let food_id = created["id"].as_str().unwrap().to_string();
    let old_serving_id = created["servings"][0]["id"].as_str().unwrap().to_string();

    // PATCH with a completely different servings list.
    let patch_body = serde_json::json!({
        "servings": [
            {"amount": 30, "unit": "g", "kcal": 120, "protein_g": 5}
        ]
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/foods/{food_id}"),
            patch_body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let patched = read_json(resp.into_body()).await;
    let new_servings = patched["servings"].as_array().expect("servings array");

    // Old serving is gone; exactly one new serving exists.
    assert_eq!(new_servings.len(), 1);
    assert_ne!(
        new_servings[0]["id"].as_str().unwrap(),
        old_serving_id,
        "old serving id must be replaced"
    );
    assert_eq!(new_servings[0]["unit"], "g");
    // Decimal serializes as a JSON string.
    assert_eq!(new_servings[0]["kcal"].as_str().unwrap_or(""), "120");
    assert_eq!(new_servings[0]["protein_g"].as_str().unwrap_or(""), "5");
}

#[tokio::test]
async fn test_post_food_rejects_blank_name() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "   ",
        "servings": [{"amount": 1, "unit": "serving", "kcal": 100}],
    });

    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/foods", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_patch_food_404_for_unknown() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;
    let missing = Uuid::new_v4();

    let body = serde_json::json!({ "name": "Renamed" });
    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/foods/{missing}"),
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_patch_food_403_when_owned_by_other_user() {
    // The in-memory `find_by_id` returns `None` for customs the viewer can't
    // see (visibility rule). The service maps cross-tenant custom-food
    // patches to 404, not 403 — existence of someone else's private food is
    // not disclosed.
    use std::sync::OnceLock;
    let other_user = Uuid::new_v4();
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, _s, _l, _u| {
        let foods = foods.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let id = seed_custom_food(&foods, other_user, "Bob's Soup").await;
            captured.set(id).unwrap();
        })
    })
    .await;
    let bobs_food_id = *captured.get().unwrap();

    let body = serde_json::json!({ "name": "Hijacked" });
    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/foods/{bobs_food_id}"),
            body,
        ))
        .await
        .unwrap();
    // 404, not 403 — the food is invisible.
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_patch_food_403_on_off_food() {
    // OFF foods are visible to everyone but writable by no one.
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "5555", "OffFood", Some("OffBrand")).await;
        })
    })
    .await;

    let off_id = {
        let resp = app
            .clone()
            .oneshot(authed_request("GET", "/api/v1/foods/barcode/5555"))
            .await
            .unwrap();
        let body = read_json(resp.into_body()).await;
        body["id"].as_str().unwrap().to_string()
    };

    let body = serde_json::json!({ "name": "Hijacked" });
    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/foods/{off_id}"),
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// -- Tests: GET /foods/mine -------------------------------------------------

#[tokio::test]
async fn list_mine_returns_paginated_envelope() {
    let (app, _alice) = build_test_app_with(move |foods, _s, _l, alice| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_custom_food(&foods, alice, "My Food A").await;
            seed_custom_food(&foods, alice, "My Food B").await;
            seed_custom_food(&foods, alice, "My Food C").await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/mine"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 3);
    assert_eq!(body["limit"], 100);
    assert_eq!(body["offset"], 0);
    assert_eq!(body["results"].as_array().unwrap().len(), 3);
}

#[tokio::test]
async fn list_mine_filters_by_q() {
    let (app, _alice) = build_test_app_with(move |foods, _s, _l, alice| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_custom_food(&foods, alice, "Apple Pie").await;
            seed_custom_food(&foods, alice, "Banana Bread").await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/mine?q=apple"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    let results = body["results"].as_array().unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0]["name"], "Apple Pie");
}

#[tokio::test]
async fn list_mine_rejects_q_over_200_chars() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let long_q = "a".repeat(201);
    let uri = format!("/api/v1/foods/mine?q={long_q}");
    let resp = app.oneshot(authed_request("GET", &uri)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn list_mine_silently_clamps_oversized_limit() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/mine?limit=1000"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["limit"], 500);
}

#[tokio::test]
async fn list_mine_negative_limit_400() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/mine?limit=-1"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn list_mine_excludes_other_users() {
    let bob = Uuid::new_v4();
    let (app, _alice) = build_test_app_with(move |foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_custom_food(&foods, bob, "Bob's Secret Recipe").await;
        })
    })
    .await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/mine"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 0);
    assert_eq!(body["results"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn test_delete_food_409_when_logs_reference_it() {
    use chrono::NaiveDate;
    use loseit_core::domain::unit::Unit as DomainUnit;
    use loseit_core::domain::{Meal, NutritionSnapshot, PersistedLogEntry};
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();

    let (app, _alice) = build_test_app_with(move |foods, _s, logs, alice| {
        let foods = foods.clone();
        let logs = logs.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            // Wire the log repo into the food repo so `delete_custom` will
            // surface the conflict that production gets from FK-restrict.
            foods.set_log_repo_for_delete_check(logs.clone());

            let id = seed_custom_food(&foods, alice, "Custom Pasta").await;
            captured.set(id).unwrap();

            // Manually create a log entry referencing this food.
            let entry = PersistedLogEntry {
                food_id: id,
                serving_id: None,
                consumed_on: NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
                meal: Meal::Lunch,
                quantity: Decimal::from(1),
                entered_amount: Decimal::from(1),
                entered_unit: DomainUnit::Serving,
                snapshot: NutritionSnapshot {
                    calories_kcal: Decimal::from(150),
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

    let food_id = *captured.get().unwrap();
    let resp = app
        .oneshot(authed_request(
            "DELETE",
            &format!("/api/v1/foods/{food_id}"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

// -- Tests: FoodDetailResponse.kind (T06) ------------------------------------

#[tokio::test]
async fn food_detail_kind_normal_for_custom_food() {
    // POST a custom food, then GET /foods/:id and assert kind == "normal".
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "Kind Test Custom Food",
        "servings": [{"amount": 100, "unit": "g", "kcal": 200}],
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/foods", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let created = read_json(resp.into_body()).await;
    let food_id = created["id"].as_str().unwrap().to_string();

    let resp = app
        .oneshot(authed_request("GET", &format!("/api/v1/foods/{food_id}")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["kind"], "normal", "custom food must report kind=normal");
}

#[tokio::test]
async fn food_detail_kind_quick_add_for_sentinel() {
    // POST /log/quick_add triggers find_or_create_quick_add; the returned
    // log entry carries food_id. GET /foods/:food_id and assert kind ==
    // "quick_add".
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "calories_kcal": "300",
        "meal": "lunch",
        "consumed_on": "2024-06-01",
    });
    let resp = app
        .clone()
        .oneshot(authed_json_request("POST", "/api/v1/log/quick_add", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let entry = read_json(resp.into_body()).await;
    let food_id = entry["food_id"].as_str().unwrap().to_string();

    let resp = app
        .oneshot(authed_request("GET", &format!("/api/v1/foods/{food_id}")))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(
        body["kind"], "quick_add",
        "quick_add sentinel must report kind=quick_add"
    );
}
