//! End-to-end HTTP tests for the JWKS authenticator branch.
//!
//! Spins up a `wiremock` server serving a JWKS document, wires a real
//! [`JwksAuthenticator`] into [`AppState`], and pokes the axum router
//! through the normal middleware stack. The point is to exercise the
//! whole composition — request → middleware → token validation → user
//! provisioning — not to retest the validator's unit-level edges.

use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use loseit_api::auth::jwks::JwksAuthenticator;
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::repo::{
    FoodRepository, GoalRepository, LogRepository, ServingRepository, UserRepository,
    WeightRepository,
};
use loseit_testing::{
    InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLogRepository,
    InMemoryServingRepository, InMemoryUserFoodSummaryReader, InMemoryUserRepository,
    InMemoryWeightRepository,
};
use rsa::pkcs1::EncodeRsaPrivateKey;
use rsa::pkcs8::LineEnding;
use rsa::traits::PublicKeyParts;
use rsa::RsaPrivateKey;
use serde::Serialize;
use serde_json::{json, Value};
use tower::ServiceExt;
use wiremock::matchers::method;
use wiremock::{Mock, MockServer, ResponseTemplate};

const ISSUER: &str = "https://issuer.example";
const AUDIENCE: &str = "loseit-api";

#[derive(Serialize)]
struct TestClaims {
    iss: String,
    sub: String,
    aud: String,
    exp: i64,
    iat: i64,
    nbf: i64,
    email: String,
    name: String,
}

struct TestKey {
    kid: String,
    encoding: EncodingKey,
    jwk: Value,
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn generate_key(kid: &str) -> TestKey {
    let mut rng = rand::thread_rng();
    let private = RsaPrivateKey::new(&mut rng, 2048).expect("key gen");
    let pem = private
        .to_pkcs1_pem(LineEnding::LF)
        .expect("private pem")
        .to_string();
    let encoding = EncodingKey::from_rsa_pem(pem.as_bytes()).expect("encoding key");
    let public = private.to_public_key();
    let n = URL_SAFE_NO_PAD.encode(public.n().to_bytes_be());
    let e = URL_SAFE_NO_PAD.encode(public.e().to_bytes_be());
    let jwk = json!({
        "kty": "RSA",
        "alg": "RS256",
        "use": "sig",
        "kid": kid,
        "n": n,
        "e": e,
    });
    TestKey {
        kid: kid.to_string(),
        encoding,
        jwk,
    }
}

fn sign(key: &TestKey, claims: &TestClaims) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some(key.kid.clone());
    encode(&header, claims, &key.encoding).expect("sign")
}

fn fresh_claims(sub: &str) -> TestClaims {
    let n = now();
    TestClaims {
        iss: ISSUER.to_string(),
        sub: sub.to_string(),
        aud: AUDIENCE.to_string(),
        exp: n + 3600,
        iat: n,
        nbf: n - 5,
        email: "alice@example.com".to_string(),
        name: "Alice".to_string(),
    }
}

async fn mount_jwks(server: &MockServer, body: Value) {
    Mock::given(method("GET"))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(server)
        .await;
}

async fn build_app(authn: Arc<dyn Authenticator>) -> axum::Router {
    let users: Arc<dyn UserRepository> = Arc::new(InMemoryUserRepository::new());
    let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
    let goals: Arc<dyn GoalRepository> = Arc::new(InMemoryGoalRepository::new());
    let foods: Arc<dyn FoodRepository> = Arc::new(InMemoryFoodRepository::new());
    let servings: Arc<dyn ServingRepository> = Arc::new(InMemoryServingRepository::new());
    let logs_concrete = Arc::new(InMemoryLogRepository::new());
    let summary_reader: Arc<dyn loseit_core::service::UserFoodSummaryReader> =
        Arc::new(InMemoryUserFoodSummaryReader::new(logs_concrete.clone()));
    let logs: Arc<dyn LogRepository> = logs_concrete;
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
    router(state)
}

#[tokio::test]
async fn valid_token_reaches_me_and_provisions_user() {
    let key = generate_key("k1");
    let server = MockServer::start().await;
    mount_jwks(&server, json!({ "keys": [key.jwk.clone()] })).await;

    let authn: Arc<dyn Authenticator> = Arc::new(
        JwksAuthenticator::new(
            ISSUER.to_string(),
            AUDIENCE.to_string(),
            format!("{}/jwks", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache"),
    );
    let app = build_app(authn).await;

    let token = sign(&key, &fresh_claims("user-xyz"));
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
    assert_eq!(resp.status(), StatusCode::OK);

    let bytes = to_bytes(resp.into_body(), 64 * 1024).await.unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["issuer"], ISSUER);
    assert_eq!(body["external_id"], "user-xyz");
    assert_eq!(body["email"], "alice@example.com");
}

#[tokio::test]
async fn tampered_signature_returns_401() {
    let key = generate_key("k1");
    let server = MockServer::start().await;
    mount_jwks(&server, json!({ "keys": [key.jwk.clone()] })).await;

    let authn: Arc<dyn Authenticator> = Arc::new(
        JwksAuthenticator::new(
            ISSUER.to_string(),
            AUDIENCE.to_string(),
            format!("{}/jwks", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache"),
    );
    let app = build_app(authn).await;

    let token = sign(&key, &fresh_claims("user-xyz"));
    // Flip the last byte of the signature.
    let mut parts: Vec<&str> = token.split('.').collect();
    assert_eq!(parts.len(), 3);
    let sig_bytes = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
    let mut bad = sig_bytes.clone();
    let last = bad.len() - 1;
    bad[last] ^= 0xFF;
    let bad_b64 = URL_SAFE_NO_PAD.encode(bad);
    parts[2] = &bad_b64;
    let bad_token = parts.join(".");

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {bad_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn jwks_endpoint_failure_after_warmup_returns_503() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let key = generate_key("k1");
    let server = MockServer::start().await;
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_clone = hits.clone();
    let doc = json!({ "keys": [key.jwk.clone()] });
    Mock::given(method("GET"))
        .respond_with(move |_req: &wiremock::Request| {
            let n = hits_clone.fetch_add(1, Ordering::SeqCst);
            if n == 0 {
                ResponseTemplate::new(200).set_body_json(doc.clone())
            } else {
                ResponseTemplate::new(500)
            }
        })
        .mount(&server)
        .await;

    let authn: Arc<dyn Authenticator> = Arc::new(
        JwksAuthenticator::new(
            ISSUER.to_string(),
            AUDIENCE.to_string(),
            format!("{}/jwks", server.uri()),
            Duration::from_secs(3600),
        )
        .await
        .expect("warm cache"),
    );
    let app = build_app(authn).await;

    // Token signed by an unknown kid forces a refresh, which will fail.
    let other = generate_key("k-rotated");
    let token = sign(&other, &fresh_claims("user-xyz"));
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
    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
}
