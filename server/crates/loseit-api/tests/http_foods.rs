//! HTTP integration tests for the `/foods/*` read endpoints (T10 + T11).
//!
//! Mirrors `tests/http.rs` — same `FakeAuthenticator` + in-memory ports —
//! but exposes a `build_test_app_with` seeder so each test can preload
//! foods + servings into the in-memory repos before the router is built.
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
use loseit_core::domain::{FoodDraft, NutritionPer100g, UserIdentity};
use loseit_core::repo::{
    FoodRepository, GoalRepository, LogRepository, OffFoodUpsert, OffServing, ServingRepository,
    SystemServing, UserRepository, WeightRepository,
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
/// doesn't need a new dependency. The closure passed to
/// `build_test_app_with` returns `Pin<Box<dyn Future<…>>>`.
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

/// Sibling of the (private) `build_test_app` in `tests/http.rs`. The
/// signature hands the concrete fake repositories to a `setup` closure so
/// the test can seed them before the router is wired. Returns both the
/// router and the alice user's id (provisioned during setup) so handlers
/// can be hit and assertions can refer to "this user".
///
/// Why a closure rather than returning the `Arc`s and letting the test
/// seed afterwards? Because seeding has to happen *before* the request
/// reaches the router, and `AppState::from_ports` consumes the trait
/// objects. The closure pattern keeps the wiring in one place.
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

    // Pair the food repo with the serving repo so `upsert_off_batch` also
    // materializes servings — the production wiring does the same.
    foods_concrete.set_serving_repo(servings_concrete.clone());

    // Provision the alice user up front so seeding closures can reference
    // her uuid (e.g. for owner-only customs).
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
    let state = AppState::from_ports(users, weights, goals, foods, servings, logs, authn);
    (router(state), alice.id)
}

async fn read_json(body: Body) -> Value {
    let bytes = to_bytes(body, 64 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

// -- Seed helpers ------------------------------------------------------------

/// Seed an OFF food + a default serving + a 100g system serving. Returns the
/// food id (looked up via `find_by_barcode` because `upsert_off_batch` only
/// returns counts).
async fn seed_off_food(
    foods: &Arc<InMemoryFoodRepository>,
    barcode: &str,
    name: &str,
    brands: Option<&str>,
) -> Uuid {
    let batch_id = Uuid::new_v4();
    let rec = OffFoodUpsert {
        draft: FoodDraft {
            name: name.into(),
            brands: brands.map(|s| s.into()),
            barcode: Some(barcode.into()),
            categories_tags: vec![],
            nutrition: NutritionPer100g {
                energy_kcal: Some(Decimal::new(120, 0)),
                ..Default::default()
            },
            nutriscore_grade: None,
        },
        quality_score: 50,
        off_serving: Some(OffServing {
            label: "1 cup".into(),
            grams: Decimal::new(245, 0),
        }),
        system_100g_serving: SystemServing {
            label: "100 g".into(),
            grams: Decimal::new(100, 0),
        },
    };
    foods.upsert_off_batch(batch_id, &[rec]).await.unwrap();

    // Visibility is global for OFF foods so any viewer id will resolve it.
    let any_viewer = Uuid::nil();
    foods
        .find_by_barcode(any_viewer, barcode)
        .await
        .unwrap()
        .expect("just inserted")
        .id
}

/// Create a user-custom food (no servings — tests that need them can ignore
/// because the detail handler just returns whatever `list_for_food`
/// produces).
async fn seed_custom_food(foods: &Arc<InMemoryFoodRepository>, owner: Uuid, name: &str) -> Uuid {
    let draft = FoodDraft {
        name: name.into(),
        brands: None,
        barcode: None,
        categories_tags: vec![],
        nutrition: NutritionPer100g {
            energy_kcal: Some(Decimal::new(100, 0)),
            ..Default::default()
        },
        nutriscore_grade: None,
    };
    foods.create_custom(owner, &draft).await.unwrap().id
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

    // Discover the food id via barcode (so the test doesn't have to know it
    // ahead of time).
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
    // OFF seed materializes both the 100 g system serving and the OFF
    // "1 cup" serving — total 2.
    assert_eq!(servings.len(), 2, "expected 100g + OFF serving");
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
async fn test_get_food_by_id_404_when_custom_owned_by_other_user() {
    // Seed a custom food owned by SOMEONE ELSE and capture its id via a
    // `OnceLock` so the test (running outside the seeder closure) knows
    // which uuid to request. We can't reach into the in-memory repo with a
    // different viewer from the HTTP layer, so the id has to be smuggled
    // out of the seeder.
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
    // Each hit must carry the lean fields, including the default serving
    // when one exists.
    for hit in results {
        assert!(hit.get("id").is_some());
        assert!(hit.get("name").is_some());
        assert!(hit.get("source").is_some());
        assert!(hit.get("default_serving").is_some());
    }
    assert_eq!(body["limit"], 100);
    assert_eq!(body["offset"], 0);
}

#[tokio::test]
async fn test_foods_search_default_limit_is_now_100() {
    // Guards the contract bump from `SEARCH_DEFAULT_LIMIT=20` to the unified
    // `DEFAULT_PAGE_LIMIT=100` across all paged endpoints.
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
    // Guards the `MAX_PAGE_LIMIT=500` silent clamp on `/foods/search`.
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

    // Blank `q` — service-level validation surfaces as 400.
    let resp = app
        .clone()
        .oneshot(authed_request("GET", "/api/v1/foods/search?q="))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Whitespace-only `q` is also blank after trim.
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/foods/search?q=%20%20"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// -- Tests: POST /foods (T12) ------------------------------------------------

#[tokio::test]
async fn test_post_food_returns_201_with_id_and_default_serving() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "Homemade Smoothie",
        "brands": "Alice",
        "barcode": null,
        "categories_tags": ["smoothie", "drink"],
        "nutrition": {
            "energy_kcal": 120,
            "protein_g": 5,
            "carbs_g": 20,
            "fat_g": 2,
        },
        "nutriscore_grade": "b",
    });

    let resp = app
        .oneshot(authed_json_request("POST", "/api/v1/foods", body))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert!(body["id"].as_str().is_some(), "must return an id");
    assert_eq!(body["name"], "Homemade Smoothie");
    assert_eq!(body["source"], "user");
    assert_eq!(body["nutriscore"], "b");
    let servings = body["servings"].as_array().expect("servings array");
    // The service synthesizes exactly one default 100 g serving.
    assert_eq!(servings.len(), 1);
    assert_eq!(servings[0]["label"], "100 g");
    assert_eq!(servings[0]["is_default"], true);
    assert_eq!(servings[0]["source"], "system");
}

#[tokio::test]
async fn test_post_food_rejects_blank_name() {
    let (app, _alice) = build_test_app_with(|_f, _s, _l, _u| Box::pin(async move {})).await;

    let body = serde_json::json!({
        "name": "   ",
        "nutrition": {},
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
    // Decision: the in-memory `find_by_id` returns `None` for customs the
    // viewer can't see (visibility rule established in T04 — see
    // `is_visible` in `loseit-testing/src/foods.rs`). The service therefore
    // maps cross-tenant custom-food patches to 404, not 403. This is the
    // documented behaviour from `architect's plan / T10`'s
    // `test_get_food_by_id_404_when_custom_owned_by_other_user`: the
    // existence of someone else's private food is not disclosed.
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
    // 404, not 403 — the food is invisible, so we don't acknowledge it.
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_patch_food_403_on_off_food() {
    // OFF foods are visible to everyone but writable by no one. The service
    // distinguishes this from the cross-tenant case above and returns 403.
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "5555", "OffFood", Some("OffBrand")).await;
        })
    })
    .await;

    let off_id = {
        // Reach in via barcode to discover the id.
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

#[tokio::test]
async fn test_delete_food_409_when_logs_reference_it() {
    use chrono::NaiveDate;
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
                grams_total: Decimal::from(150),
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
