//! HTTP integration tests for GET /weights (T06).
//!
//! Uses the same in-memory repo wiring as `tests/http_log.rs`.

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use chrono::NaiveDate;
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::domain::{UserIdentity, WeightDraft};
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

const TEST_TOKEN: &str = "test-token";

fn test_identity() -> UserIdentity {
    UserIdentity {
        issuer: "test".into(),
        external_id: "alice".into(),
        email: Some("alice@example.com".into()),
        display_name: Some("Alice".into()),
    }
}

async fn build_test_app() -> (axum::Router, Uuid, Arc<InMemoryWeightRepository>) {
    let users_concrete = Arc::new(InMemoryUserRepository::new());
    let weights_concrete = Arc::new(InMemoryWeightRepository::new());
    let foods_concrete = Arc::new(InMemoryFoodRepository::new());
    let servings_concrete = Arc::new(InMemoryServingRepository::new());
    let logs_concrete = Arc::new(InMemoryLogRepository::new());
    let goals_concrete = Arc::new(InMemoryGoalRepository::new());

    foods_concrete.set_serving_repo(servings_concrete.clone());

    let alice = users_concrete.create(&test_identity()).await.unwrap();

    let users: Arc<dyn UserRepository> = users_concrete;
    let weights_dyn: Arc<dyn WeightRepository> = weights_concrete.clone();
    let goals: Arc<dyn GoalRepository> = goals_concrete;
    let foods: Arc<dyn FoodRepository> = foods_concrete;
    let servings: Arc<dyn ServingRepository> = servings_concrete;
    let logs: Arc<dyn LogRepository> = logs_concrete;
    let authn: Arc<dyn Authenticator> =
        Arc::new(FakeAuthenticator::new(TEST_TOKEN, test_identity()));
    let state = AppState::from_ports(users, weights_dyn, goals, foods, servings, logs, authn, None, None, false);
    (router(state), alice.id, weights_concrete)
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

/// Seed `count` weight entries for `alice` on consecutive days starting from
/// 2025-01-01, with weight_kg incrementing by 1 each day.
async fn seed_weights(weights: &Arc<InMemoryWeightRepository>, alice: Uuid, count: usize) {
    for i in 0..count {
        let day = NaiveDate::from_ymd_opt(2025, 1, 1 + i as u32).unwrap();
        let draft = WeightDraft {
            recorded_on: day,
            recorded_at_local: None,
            weight_kg: Decimal::from(70 + i as u64),
            note: None,
        };
        weights.create(alice, &draft).await.unwrap();
    }
}

// =============================================================================
// T06 — GET /weights paginated envelope.
// =============================================================================

#[tokio::test]
async fn list_weights_returns_paginated_envelope() {
    let (app, alice, weights) = build_test_app().await;
    seed_weights(&weights, alice, 3).await;

    let resp = app
        .oneshot(authed_request("GET", "/api/v1/weights"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 3);
    assert_eq!(body["limit"], 100);
    assert_eq!(body["offset"], 0);
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 3);
    // Verify response shape has expected fields.
    let first = &results[0];
    assert!(first.get("id").is_some());
    assert!(first.get("recorded_on").is_some());
    assert!(first.get("weight_kg").is_some());
    assert!(first.get("created_at").is_some());
}

#[tokio::test]
async fn list_weights_filters_by_from_and_to_inclusive() {
    let (app, alice, weights) = build_test_app().await;
    // Seed 5 days: Jan 1–5.
    seed_weights(&weights, alice, 5).await;

    // Filter: Jan 2 to Jan 4 — expect 3 results.
    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/weights?from=2025-01-02&to=2025-01-04",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = read_json(resp.into_body()).await;
    assert_eq!(body["total"], 3);
    let results = body["results"].as_array().expect("results array");
    assert_eq!(results.len(), 3);
    // Newest first: Jan 4, Jan 3, Jan 2.
    assert_eq!(results[0]["recorded_on"], "2025-01-04");
    assert_eq!(results[2]["recorded_on"], "2025-01-02");
}

#[tokio::test]
async fn list_weights_400_when_from_after_to() {
    let (app, _alice, _weights) = build_test_app().await;

    let resp = app
        .oneshot(authed_request(
            "GET",
            "/api/v1/weights?from=2025-02-01&to=2025-01-01",
        ))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn list_weights_paginates() {
    let (app, alice, weights) = build_test_app().await;
    seed_weights(&weights, alice, 5).await;

    // Page 2: offset=2, limit=2 → 2 results, total=5.
    let resp = app
        .oneshot(authed_request("GET", "/api/v1/weights?limit=2&offset=2"))
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
