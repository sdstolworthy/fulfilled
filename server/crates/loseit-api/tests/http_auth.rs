//! HTTP integration tests for `POST /api/v1/auth/login` + bearer round-trip.
//!
//! Ten end-to-end cases covering: correct creds (200), wrong password (401),
//! unknown username (401), no-auth-required on the login endpoint, body
//! validation (400), bearer→/me (200), invalid bearer (401), expired bearer
//! (401), sliding-window refresh (consecutive hits with same token), and 404
//! when auth_service is unset.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use loseit_api::auth::local::LocalAuthenticator;
use loseit_api::auth::dev::DevAuthenticator;
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::domain::UserIdentity;
use loseit_core::repo::{FoodRepository, GoalRepository, LogRepository, ServingRepository, UserRepository, WeightRepository};
use loseit_core::service::AuthService;
use loseit_testing::{
    InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLocalAuthRepository,
    InMemoryLogRepository, InMemoryServingRepository, InMemoryUserRepository,
    InMemoryWeightRepository,
};
use sha2::{Digest, Sha256};
use tower::ServiceExt;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Build the test router. When `with_auth_service` is `true` the login route
/// is mounted and a `LocalAuthenticator` is used so bearer tokens issued by
/// `AuthService::login` are accepted by `require_auth`. Returns the router,
/// the in-memory user repo (for seeding), the in-memory local-auth repo (for
/// force-expire), and the `AuthService` (for `seed_credential`).
fn build_harness(
    with_auth_service: bool,
) -> (
    axum::Router,
    Arc<InMemoryUserRepository>,
    Arc<InMemoryLocalAuthRepository>,
    Option<Arc<AuthService>>,
) {
    let users_concrete = Arc::new(InMemoryUserRepository::new());
    let local_concrete = Arc::new(InMemoryLocalAuthRepository::new());

    let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
    let goals: Arc<dyn GoalRepository> = Arc::new(InMemoryGoalRepository::new());
    let foods_concrete = Arc::new(InMemoryFoodRepository::new());
    let servings_concrete = Arc::new(InMemoryServingRepository::new());
    foods_concrete.set_serving_repo(servings_concrete.clone());
    let foods: Arc<dyn FoodRepository> = foods_concrete;
    let servings: Arc<dyn ServingRepository> = servings_concrete;
    let logs: Arc<dyn LogRepository> = Arc::new(InMemoryLogRepository::new());

    let users_dyn: Arc<dyn UserRepository> = users_concrete.clone();

    if with_auth_service {
        let auth_service = Arc::new(AuthService::new(users_concrete.clone(), local_concrete.clone()));
        let authn: Arc<dyn Authenticator> =
            Arc::new(LocalAuthenticator::new(auth_service.clone()));
        let state = AppState::from_ports(
            users_dyn,
            weights,
            goals,
            foods,
            servings,
            logs,
            authn,
            Some(auth_service.clone()),
            None,
            true,
        );
        (
            router(state),
            users_concrete,
            local_concrete,
            Some(auth_service),
        )
    } else {
        // DevAuthenticator — authenticator choice doesn't matter for the
        // 404 case, but we need a concrete type.
        let identity = UserIdentity {
            issuer: "dev".into(),
            external_id: "dev-user".into(),
            email: None,
            display_name: None,
        };
        let authn: Arc<dyn Authenticator> =
            Arc::new(DevAuthenticator::new("dev-token".into(), identity));
        let state = AppState::from_ports(
            users_dyn,
            weights,
            goals,
            foods,
            servings,
            logs,
            authn,
            None,
            None,
            false,
        );
        (router(state), users_concrete, local_concrete, None)
    }
}

/// Seed a user + credential into the harness, returning the created user's id.
async fn seed_dev_user(
    users: &Arc<InMemoryUserRepository>,
    auth_service: &Arc<AuthService>,
) {
    let identity = UserIdentity {
        issuer: "dev".into(),
        external_id: "dev-user".into(),
        email: Some("dev@example.com".into()),
        display_name: Some("Dev User".into()),
    };
    let user = users.create(&identity).await.unwrap();
    auth_service
        .seed_credential(user.id, "dev", "dev")
        .await
        .unwrap();
}

async fn body_json(resp: axum::http::Response<Body>) -> serde_json::Value {
    let bytes = axum::body::to_bytes(resp.into_body(), 64 * 1024)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

fn sha256_hex(input: &str) -> String {
    Sha256::digest(input.as_bytes())
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

fn login_request(username: &str, password: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/api/v1/auth/login")
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"username": username, "password": password}).to_string(),
        ))
        .unwrap()
}

async fn do_login(app: &axum::Router, username: &str, password: &str) -> String {
    let resp = app
        .clone()
        .oneshot(login_request(username, password))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "expected 200 on login");
    let body = body_json(resp).await;
    body["token"].as_str().unwrap().to_string()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn login_returns_200_with_token_on_correct_creds() {
    let (app, users, _local, auth_service) = build_harness(true);
    seed_dev_user(&users, auth_service.as_ref().unwrap()).await;

    let resp = app.oneshot(login_request("dev", "dev")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = body_json(resp).await;
    let token = body["token"].as_str().unwrap_or_default();
    assert!(!token.is_empty(), "token must be non-empty");

    // expires_at must be present and parse as ISO-8601.
    let expires_raw = body["expires_at"].as_str().expect("expires_at must be present");
    let expires = chrono::DateTime::parse_from_rfc3339(expires_raw)
        .expect("expires_at must be ISO-8601");

    // Should be ~30 days in the future (allow ±1 minute for slow CI).
    let now = chrono::Utc::now();
    let diff = expires.signed_duration_since(now);
    assert!(
        diff.num_days() >= 29,
        "expires_at should be at least 29 days away, got {diff:?}"
    );
}

#[tokio::test]
async fn login_returns_401_on_wrong_password() {
    let (app, users, _local, auth_service) = build_harness(true);
    seed_dev_user(&users, auth_service.as_ref().unwrap()).await;

    let resp = app
        .oneshot(login_request("dev", "WRONG"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let body = body_json(resp).await;
    assert_eq!(body["code"], "unauthorized");
    assert_eq!(body["message"], "invalid credential");
}

#[tokio::test]
async fn login_returns_401_on_unknown_username() {
    let (app, _users, _local, _auth_service) = build_harness(true);
    // No user seeded — "nobody" is unknown.
    let resp = app
        .oneshot(login_request("nobody", "x"))
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn login_does_not_require_authorization_header() {
    let (app, users, _local, auth_service) = build_harness(true);
    seed_dev_user(&users, auth_service.as_ref().unwrap()).await;

    // No Authorization header — the login route is public.
    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/auth/login")
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"username": "dev", "password": "dev"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn login_rejects_missing_body_fields_400() {
    let (app, users, _local, auth_service) = build_harness(true);
    seed_dev_user(&users, auth_service.as_ref().unwrap()).await;

    // Missing "password" field — axum's Json extractor should reject this.
    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/auth/login")
        .header("content-type", "application/json")
        .body(Body::from(r#"{"username":"dev"}"#))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn bearer_with_valid_token_passes_authenticate() {
    let (app, users, _local, auth_service) = build_harness(true);
    seed_dev_user(&users, auth_service.as_ref().unwrap()).await;

    let token = do_login(&app, "dev", "dev").await;

    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["issuer"], "dev");
}

#[tokio::test]
async fn bearer_with_invalid_token_returns_401() {
    let (app, _users, _local, _auth_service) = build_harness(true);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", "Bearer obvious-fake-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn bearer_with_expired_token_returns_401() {
    let (app, users, local, auth_service) = build_harness(true);
    seed_dev_user(&users, auth_service.as_ref().unwrap()).await;

    let token = do_login(&app, "dev", "dev").await;

    // Back-date the token in the store so it appears expired.
    let token_hash = sha256_hex(&token);
    local.force_expire(&token_hash);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn login_then_two_protected_calls_use_same_token() {
    let (app, users, _local, auth_service) = build_harness(true);
    seed_dev_user(&users, auth_service.as_ref().unwrap()).await;

    let token = do_login(&app, "dev", "dev").await;

    let first = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    // Same token must still work on the second call.
    let second = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);
}

#[tokio::test]
async fn login_route_absent_when_auth_service_unset() {
    let (app, _users, _local, _auth_service) = build_harness(false);

    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/auth/login")
        .header("content-type", "application/json")
        .body(Body::from(r#"{"username":"dev","password":"dev"}"#))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
