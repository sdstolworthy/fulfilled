//! HTTP integration tests for the serving CRUD endpoints (T13).
//!
//! Mirrors `tests/http_foods.rs` — same `FakeAuthenticator` + in-memory
//! ports, plus a `build_test_app_with` seeder so each test can preload
//! foods and servings before the router is built.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::domain::{FoodDraft, ServingDraft, ServingSource, Unit, UserIdentity};
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

    foods_concrete.set_serving_repo(servings_concrete.clone());

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

async fn seed_off_food(foods: &Arc<InMemoryFoodRepository>, barcode: &str, name: &str) -> Uuid {
    let batch_id = Uuid::new_v4();
    let rec = FoodDraftWithServings {
        draft: FoodDraft {
            name: name.into(),
            brands: None,
            barcode: Some(barcode.into()),
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
                kcal: Decimal::new(293, 0), // 120 kcal/100g * 245g / 100
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
                kcal: Decimal::new(120, 0),
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
    foods.upsert_external_food_batch(batch_id, vec![rec]).await.unwrap();
    foods
        .find_by_barcode(Uuid::nil(), barcode)
        .await
        .unwrap()
        .expect("just inserted")
        .id
}

async fn seed_custom_food_with_default_serving(
    foods: &Arc<InMemoryFoodRepository>,
    _servings: &Arc<InMemoryServingRepository>,
    owner: Uuid,
    name: &str,
) -> (Uuid, Uuid) {
    let draft = FoodDraft {
        name: name.into(),
        brands: None,
        barcode: None,
        categories_tags: vec![],
        nutriscore_grade: None,
        servings: vec![],
    };
    // Use create_custom_with_servings — includes the default 100 g serving.
    let default_serving_draft = ServingDraft {
        label: Some("100 g".into()),
        amount: Decimal::from(100),
        unit: Unit::Gram,
        kcal: Decimal::from(100),
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
        .create_custom_with_servings(owner, &draft, vec![default_serving_draft])
        .await
        .unwrap();
    // Retrieve the serving that was inserted for this food.
    // The food repo wires through to the serving repo, so list_for_food works.
    // We need the serving id: find it via the serving repo that foods has wired in.
    // Since the test app seeds through `foods_concrete`, we reach the serving repo
    // by looking it up via the `_servings` parameter (which is wired to foods).
    let serving_list = _servings.list_for_food(food.id).await.unwrap();
    let default_serving = serving_list
        .into_iter()
        .find(|s| s.is_default)
        .expect("must have default serving after create_custom_with_servings");
    (food.id, default_serving.id)
}

// -- Tests -------------------------------------------------------------------

#[tokio::test]
async fn test_post_serving_409_for_off_food() {
    let (app, _alice) = build_test_app_with(|foods, _s, _l, _u| {
        let foods = foods.clone();
        Box::pin(async move {
            seed_off_food(&foods, "111", "Banana").await;
        })
    })
    .await;

    let food_id = {
        let resp = app
            .clone()
            .oneshot(authed_request("GET", "/api/v1/foods/barcode/111"))
            .await
            .unwrap();
        let body = read_json(resp.into_body()).await;
        body["id"].as_str().unwrap().to_string()
    };

    let body = serde_json::json!({
        "label": "1 banana",
        "amount": 118,
        "unit": "g",
        "kcal": 60,
        "is_default": false,
    });
    let resp = app
        .oneshot(authed_json_request(
            "POST",
            &format!("/api/v1/foods/{food_id}/servings"),
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
    let body = read_json(resp.into_body()).await;
    let msg = body["message"].as_str().unwrap();
    assert!(
        msg.contains("OFF foods are read-only")
            && msg.contains("clone as a custom food to add servings"),
        "expected clone-hint message, got: {msg}"
    );
}

#[tokio::test]
async fn test_post_serving_forbidden_on_other_users_custom() {
    // Visibility rule: another user's custom is invisible → 404 (consistent
    // with the analogous food-patch test in `http_foods.rs`).
    use std::sync::OnceLock;
    let other_user = Uuid::new_v4();
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _l, _u| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, _) =
                seed_custom_food_with_default_serving(&foods, &servings, other_user, "Bob's Cake")
                    .await;
            captured.set(food_id).unwrap();
        })
    })
    .await;
    let bobs_food = *captured.get().unwrap();

    let body = serde_json::json!({
        "label": "1 slice",
        "amount": 90,
        "unit": "g",
        "kcal": 50,
    });
    let resp = app
        .oneshot(authed_json_request(
            "POST",
            &format!("/api/v1/foods/{bobs_food}/servings"),
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_patch_serving_403_for_other_users_custom() {
    // Same 404-not-403 reasoning. Test name keeps the spec's wording.
    use std::sync::OnceLock;
    let other_user = Uuid::new_v4();
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _l, _u| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (_, serving_id) =
                seed_custom_food_with_default_serving(&foods, &servings, other_user, "Bob's Soup")
                    .await;
            // Add a non-default serving we can attempt to patch.
            let extra = servings
                .create(
                    // unrelated food id only matters if we tried to PATCH the
                    // *default* — we want to PATCH a non-default that still
                    // belongs to bob's food, so look up bob's food id from
                    // the first serving.
                    {
                        let s = servings.find_by_id(serving_id).await.unwrap().unwrap();
                        s.food_id
                    },
                    &ServingDraft {
                        label: Some("1 small bowl".into()),
                        amount: Decimal::from(200),
                        unit: Unit::Gram,
                        kcal: Decimal::from(0),
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
            captured.set(extra.id).unwrap();
        })
    })
    .await;
    let bobs_serving = *captured.get().unwrap();

    let body = serde_json::json!({ "label": "Hijacked" });
    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/servings/{bobs_serving}"),
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn test_delete_default_serving_409() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _l, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (_, serving_id) =
                seed_custom_food_with_default_serving(&foods, &servings, alice, "My Food").await;
            captured.set(serving_id).unwrap();
        })
    })
    .await;
    let default_serving = *captured.get().unwrap();

    let resp = app
        .oneshot(authed_request(
            "DELETE",
            &format!("/api/v1/servings/{default_serving}"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn test_set_default_serving_flips_atomically() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<(Uuid, Uuid, Uuid)>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _l, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, default_serving) =
                seed_custom_food_with_default_serving(&foods, &servings, alice, "Toast").await;
            let extra_a = servings
                .create(
                    food_id,
                    &ServingDraft {
                        label: Some("1 slice".into()),
                        amount: Decimal::from(30),
                        unit: Unit::Gram,
                        kcal: Decimal::from(0),
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
            let extra_b = servings
                .create(
                    food_id,
                    &ServingDraft {
                        label: Some("2 slices".into()),
                        amount: Decimal::from(60),
                        unit: Unit::Gram,
                        kcal: Decimal::from(0),
                        protein_g: None,
                        carbs_g: None,
                        fat_g: None,
                        fiber_g: None,
                        sugar_g: None,
                        sodium_mg: None,
                        saturated_fat_g: None,
                        is_default: false,
                        source: ServingSource::User,
                        sort_order: 2,
                    },
                )
                .await
                .unwrap();
            captured
                .set((default_serving, extra_a.id, extra_b.id))
                .unwrap();
        })
    })
    .await;
    let (orig_default, a, b) = *captured.get().unwrap();

    // Flip to A.
    let resp = app
        .clone()
        .oneshot(authed_request(
            "POST",
            &format!("/api/v1/servings/{a}/default"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["is_default"], true);

    // Flip to B.
    let resp = app
        .clone()
        .oneshot(authed_request(
            "POST",
            &format!("/api/v1/servings/{b}/default"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // Inspect all servings via the food detail endpoint: exactly one default
    // should remain.
    // We need to know the food id; reach it through any of the servings.
    // The detail endpoint requires the food id; since seed knows the food id
    // already, we go through `food` from serving A's body which embeds it
    // indirectly — for simplicity, hit the food via the orig_default's
    // detail. Instead, fetch the food list_for_food by re-using the detail
    // for the food id.
    //
    // Simpler approach: re-fetch each serving via PATCH no-op? They have no
    // GET-by-id endpoint. We instead hit the food detail. Look up the food
    // id from the orig_default serving via `find_by_id` in another request
    // is not exposed either. So we record everything we need from `body`
    // above: each serving's id, plus `is_default`. To verify the OTHER two
    // are now `false`, hit `POST /servings/<orig>/default` then `<b>/default`
    // back-to-back, then look at all three returned bodies.
    //
    // Cleanest: hit `/api/v1/foods/:id` if we know the food. Re-fetch the
    // food id off serving b's body — but ServingResponse doesn't expose
    // food_id. Skip the round-trip and just verify via re-flipping: after
    // flipping back to orig_default, the previous default (b) must report
    // `is_default = false`. We do that with a PATCH no-op.

    // Re-flip to orig_default.
    let resp = app
        .clone()
        .oneshot(authed_request(
            "POST",
            &format!("/api/v1/servings/{orig_default}/default"),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["is_default"], true);

    // Now patch a (no-op) and b (no-op) to read their `is_default` state.
    let resp = app
        .clone()
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/servings/{a}"),
            serde_json::json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["is_default"], false, "a must no longer be default");

    let resp = app
        .oneshot(authed_json_request(
            "PATCH",
            &format!("/api/v1/servings/{b}"),
            serde_json::json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["is_default"], false, "b must no longer be default");
}

#[tokio::test]
async fn test_post_serving_creates_with_correct_fields() {
    use std::sync::OnceLock;
    let captured: Arc<OnceLock<Uuid>> = Arc::new(OnceLock::new());
    let captured_for_seed = captured.clone();
    let (app, _alice) = build_test_app_with(move |foods, servings, _l, alice| {
        let foods = foods.clone();
        let servings = servings.clone();
        let captured = captured_for_seed.clone();
        Box::pin(async move {
            let (food_id, _) =
                seed_custom_food_with_default_serving(&foods, &servings, alice, "Oats").await;
            captured.set(food_id).unwrap();
        })
    })
    .await;
    let food_id = *captured.get().unwrap();

    let body = serde_json::json!({
        "label": "1 cup dry",
        "amount": "40.5",
        "unit": "g",
        "kcal": "155",
        "is_default": false,
        "sort_order": 1,
    });
    let resp = app
        .oneshot(authed_json_request(
            "POST",
            &format!("/api/v1/foods/{food_id}/servings"),
            body,
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["label"], "1 cup dry");
    // rust_decimal serializes as a string by default.
    assert_eq!(body["amount"], "40.5");
    assert_eq!(body["unit"], "g");
    assert_eq!(body["kcal"], "155");
    assert_eq!(body["is_default"], false);
    assert_eq!(body["sort_order"], 1);
    // No explicit source → handler defaults to "user".
    assert_eq!(body["source"], "user");
}
