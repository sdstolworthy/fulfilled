//! End-to-end HTTP tests for the transport layer.
//!
//! These exercise the real axum router with in-memory ports plugged into
//! [`AppState`]. The router is the same one `loseit-api`'s binary serves
//! in production — only the adapter implementations are swapped.

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt as _;
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::domain::UserIdentity;
use loseit_core::repo::{
    FoodRepository, GoalRepository, LogRepository, ServingRepository, UserRepository,
    WeightRepository,
};
use loseit_testing::{
    FakeAuthenticator, InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLogRepository,
    InMemoryServingRepository, InMemoryUserRepository, InMemoryWeightRepository,
};
use serde_json::{json, Value};
use tower::ServiceExt;

const TEST_TOKEN: &str = "test-token";

fn test_identity() -> UserIdentity {
    UserIdentity {
        issuer: "test".into(),
        external_id: "alice".into(),
        email: Some("alice@example.com".into()),
        display_name: Some("Alice".into()),
    }
}

fn build_test_app() -> axum::Router {
    let users: Arc<dyn UserRepository> = Arc::new(InMemoryUserRepository::new());
    let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
    let goals: Arc<dyn GoalRepository> = Arc::new(InMemoryGoalRepository::new());
    let foods: Arc<dyn FoodRepository> = Arc::new(InMemoryFoodRepository::new());
    let servings: Arc<dyn ServingRepository> = Arc::new(InMemoryServingRepository::new());
    let logs: Arc<dyn LogRepository> = Arc::new(InMemoryLogRepository::new());
    let authn: Arc<dyn Authenticator> =
        Arc::new(FakeAuthenticator::new(TEST_TOKEN, test_identity()));
    let state = AppState::from_ports(users, weights, goals, foods, servings, logs, authn, None, None, false, false);
    router(state)
}

async fn read_json(body: Body) -> Value {
    let bytes = to_bytes(body, 64 * 1024).await.unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn read_text(body: Body) -> String {
    let bytes = body.collect().await.unwrap().to_bytes();
    String::from_utf8(bytes.to_vec()).unwrap()
}

#[tokio::test]
async fn health_is_public_and_returns_ok() {
    let app = build_test_app();
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body, json!({ "status": "ok" }));
}

#[tokio::test]
async fn protected_endpoint_rejects_unauthenticated_request() {
    let app = build_test_app();
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn get_me_provisions_user_on_first_call() {
    let app = build_test_app();
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {TEST_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["issuer"], "test");
    assert_eq!(body["external_id"], "alice");
    assert_eq!(body["email"], "alice@example.com");
}

#[tokio::test]
async fn weight_post_then_list_round_trip() {
    let app = build_test_app();

    let post = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/weights")
                .header("Authorization", format!("Bearer {TEST_TOKEN}"))
                .header("Content-Type", "application/json")
                .body(Body::from(
                    json!({
                        "recorded_on": "2026-05-15",
                        "weight_kg": "82.4"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        post.status(),
        StatusCode::CREATED,
        "{}",
        read_text(post.into_body()).await
    );

    let list = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/weights")
                .header("Authorization", format!("Bearer {TEST_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(list.status(), StatusCode::OK);
    let body = read_json(list.into_body()).await;
    let arr = body["results"].as_array().expect("results array");
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["recorded_on"], "2026-05-15");
}
