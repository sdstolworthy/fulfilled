//! HTTP integration tests for `DELETE /me` (T12).
//!
//! Uses the same in-memory repo wiring as `tests/http.rs`. Because
//! `InMemoryUserRepository::delete_user` only removes the user row (it has
//! no access to the other repos), we only test HTTP-level concerns here:
//! - `DELETE /me` returns 204.
//! - After deletion, a new request with the same token re-provisions a fresh
//!   user (the token is still JWT-valid; `ensure_user` creates a new row).
//! - Deleting Alice leaves Bob's data untouched.
//! - An unauthenticated `DELETE /me` returns 401.
//!
//! Cross-table cascade correctness is tested at the Postgres layer in
//! `loseit-db` integration tests (require a live DB, run separately).

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
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
use tower::ServiceExt;

const ALICE_TOKEN: &str = "alice-token";
const BOB_TOKEN: &str = "bob-token";

fn alice_identity() -> UserIdentity {
    UserIdentity {
        issuer: "test".into(),
        external_id: "alice".into(),
        email: Some("alice@example.com".into()),
        display_name: Some("Alice".into()),
    }
}

fn bob_identity() -> UserIdentity {
    UserIdentity {
        issuer: "test".into(),
        external_id: "bob".into(),
        email: Some("bob@example.com".into()),
        display_name: Some("Bob".into()),
    }
}

/// Build a test app that accepts only Alice's token.
fn build_test_app_alice() -> (axum::Router, Arc<InMemoryUserRepository>) {
    let users_concrete = Arc::new(InMemoryUserRepository::new());
    let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
    let goals: Arc<dyn GoalRepository> = Arc::new(InMemoryGoalRepository::new());
    let foods_concrete = Arc::new(InMemoryFoodRepository::new());
    let servings_concrete = Arc::new(InMemoryServingRepository::new());
    foods_concrete.set_serving_repo(servings_concrete.clone());
    let foods: Arc<dyn FoodRepository> = foods_concrete;
    let servings: Arc<dyn ServingRepository> = servings_concrete;
    let logs: Arc<dyn LogRepository> = Arc::new(InMemoryLogRepository::new());
    let authn: Arc<dyn Authenticator> =
        Arc::new(FakeAuthenticator::new(ALICE_TOKEN, alice_identity()));
    let users_dyn: Arc<dyn UserRepository> = users_concrete.clone();
    let state = AppState::from_ports(users_dyn, weights, goals, foods, servings, logs, authn);
    (router(state), users_concrete)
}

/// Build a test app that recognises two tokens (Alice and Bob) by using a
/// single-token authenticator for Alice. Bob's requests will fail auth.
/// For the cross-tenant test we build two separate apps sharing the same
/// user repo — this is simpler than a multi-token authenticator.
fn build_test_app_two_users() -> (axum::Router, axum::Router, Arc<InMemoryUserRepository>) {
    let users_concrete = Arc::new(InMemoryUserRepository::new());

    let make_app = |token: &'static str, identity: UserIdentity| {
        let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
        let goals: Arc<dyn GoalRepository> = Arc::new(InMemoryGoalRepository::new());
        let foods_concrete = Arc::new(InMemoryFoodRepository::new());
        let servings_concrete = Arc::new(InMemoryServingRepository::new());
        foods_concrete.set_serving_repo(servings_concrete.clone());
        let foods: Arc<dyn FoodRepository> = foods_concrete;
        let servings: Arc<dyn ServingRepository> = servings_concrete;
        let logs: Arc<dyn LogRepository> = Arc::new(InMemoryLogRepository::new());
        let authn: Arc<dyn Authenticator> = Arc::new(FakeAuthenticator::new(token, identity));
        let users_dyn: Arc<dyn UserRepository> = users_concrete.clone();
        let state = AppState::from_ports(users_dyn, weights, goals, foods, servings, logs, authn);
        router(state)
    };

    let alice_app = make_app(ALICE_TOKEN, alice_identity());
    let bob_app = make_app(BOB_TOKEN, bob_identity());
    (alice_app, bob_app, users_concrete)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn delete_me_returns_204() {
    let (app, _users) = build_test_app_alice();

    // First provision the user via GET /me.
    let _get = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn delete_me_requires_auth() {
    let (app, _users) = build_test_app_alice();

    let resp = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v1/me")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn delete_me_then_get_me_re_provisions_fresh_user() {
    // After deletion the JWT is still valid — the next GET /me call will
    // re-provision a brand-new user row (ensure_user creates it again).
    // This is accepted v1 behaviour.
    let (app, users) = build_test_app_alice();

    // Provision Alice.
    let get1 = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(get1.status(), StatusCode::OK);
    assert_eq!(users.len(), 1);

    // Delete Alice.
    let del = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(del.status(), StatusCode::NO_CONTENT);
    assert_eq!(users.len(), 0, "user row should be gone");

    // GET /me re-provisions.
    let get2 = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(get2.status(), StatusCode::OK);
    assert_eq!(users.len(), 1, "user row should be re-provisioned");
}

#[tokio::test]
async fn delete_me_leaves_other_users_intact() {
    // Alice and Bob share the same in-memory user repo but have separate
    // router instances (each authenticator is single-token). Delete Alice,
    // confirm Bob's row is still present.
    let (alice_app, bob_app, users) = build_test_app_two_users();

    // Provision both users.
    alice_app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    bob_app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {BOB_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(users.len(), 2, "both users provisioned");

    // Delete Alice.
    let del = alice_app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {ALICE_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(del.status(), StatusCode::NO_CONTENT);

    assert_eq!(users.len(), 1, "only Bob should remain");

    // Bob can still GET /me.
    let bob_get = bob_app
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {BOB_TOKEN}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(bob_get.status(), StatusCode::OK);
}
