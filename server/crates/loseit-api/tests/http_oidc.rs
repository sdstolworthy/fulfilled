//! HTTP-level tests for the OIDC flow:
//! `/auth/providers`, `/auth/oidc/{id}/start`, `/auth/oidc/{id}/callback`,
//! `/auth/oidc/exchange`.
//!
//! A `wiremock::MockServer` stands in for Authentik, serving:
//!   - `GET /application/o/test/jwks/`  — our RSA test key as a JWKS doc
//!   - `POST /application/o/test/token/` — returns a signed ID token
//!
//! 19 cases covering the happy path, state-cookie tampering, state
//! mismatch, expired state, IdP failures, ID-token sig + nonce rejection,
//! handoff replay + expiry, and a full E2E callback→exchange→/me.
//!
//! Per `server/specs/be_oidc_integration_design.md` §11.4.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use chrono::Utc;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use loseit_api::auth::jwks::JwksVerifier;
use loseit_api::auth::local::LocalAuthenticator;
use loseit_api::auth::oidc::state::{state_payload_with_exp, StateSigner, STATE_COOKIE_NAME};
use loseit_api::config::{OidcProviderConfig, SecretBytes};
use loseit_api::server::{OidcProvider, OidcRegistry};
use loseit_api::{router, AppState};
use loseit_core::auth::Authenticator;
use loseit_core::repo::{
    FoodRepository, GoalRepository, LogRepository, OidcHandoffRepository, ServingRepository,
    UserRepository, WeightRepository,
};
use loseit_core::service::AuthService;
use loseit_testing::{
    InMemoryFoodRepository, InMemoryGoalRepository, InMemoryLocalAuthRepository,
    InMemoryLogRepository, InMemoryOidcHandoffRepository, InMemoryServingRepository,
    InMemoryUserRepository, InMemoryWeightRepository,
};
use rsa::pkcs1::EncodeRsaPrivateKey;
use rsa::pkcs8::LineEnding;
use rsa::traits::PublicKeyParts;
use rsa::RsaPrivateKey;
use serde::Serialize;
use serde_json::{json, Value};
use tower::ServiceExt;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

// ── Helpers ──────────────────────────────────────────────────────────────────

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

/// A test RSA key with its matching JWK representation.
struct TestKey {
    kid: String,
    encoding: EncodingKey,
    jwk: Value,
}

fn generate_rsa_key(kid: &str) -> TestKey {
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

/// Claims for a test ID token.
#[derive(Serialize)]
struct IdTokenClaims {
    iss: String,
    sub: String,
    aud: String,
    exp: i64,
    iat: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    nonce: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

fn sign_id_token(key: &TestKey, claims: &IdTokenClaims) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some(key.kid.clone());
    encode(&header, claims, &key.encoding).expect("sign id_token")
}

fn sha256_hex(input: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(input.as_bytes())
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

// ── Harness ──────────────────────────────────────────────────────────────────

/// Shared harness state returned by `build_harness`.
struct Harness {
    app: axum::Router,
    /// The test RSA key used to sign mock ID tokens.
    test_key: Arc<TestKey>,
    /// State signer – used in tests to forge valid / expired / tampered cookies.
    state_signer: Arc<StateSigner>,
    /// The issuer URL (trailing-slash form, matches Authentik).
    issuer: String,
    /// URL path for the mock /token endpoint (e.g. `/application/o/test/token/`).
    token_path: String,
    /// The in-memory handoff repo – inspectable from tests.
    handoffs: Arc<InMemoryOidcHandoffRepository>,
    /// wiremock server handle (kept alive for the duration of the test).
    _mock_server: MockServer,
}

/// Build the test harness.
///
/// `with_oidc`: when `true`, an `OidcRegistry` for provider `"authentik"` is
/// wired up and the `GET /application/o/test/jwks/` mock is mounted. When
/// `false`, no OIDC registry is present (used for the local-only test).
async fn build_harness(with_oidc: bool) -> Harness {
    // 1. RSA test key + wiremock server
    let test_key = Arc::new(generate_rsa_key("test-k1"));
    let mock_server = MockServer::start().await;

    let issuer = format!("{}/application/o/test/", mock_server.uri());
    let jwks_url = format!("{}/jwks/", issuer.trim_end_matches('/'));
    let token_url = format!("{}/token/", issuer.trim_end_matches('/'));

    // 2. In-memory repos
    let users_concrete = Arc::new(InMemoryUserRepository::new());
    let local_concrete = Arc::new(InMemoryLocalAuthRepository::new());
    let handoffs = Arc::new(InMemoryOidcHandoffRepository::new());

    let weights: Arc<dyn WeightRepository> = Arc::new(InMemoryWeightRepository::new());
    let goals: Arc<dyn GoalRepository> = Arc::new(InMemoryGoalRepository::new());
    let foods_concrete = Arc::new(InMemoryFoodRepository::new());
    let servings_concrete = Arc::new(InMemoryServingRepository::new());
    foods_concrete.set_serving_repo(servings_concrete.clone());
    let foods: Arc<dyn FoodRepository> = foods_concrete;
    let servings: Arc<dyn ServingRepository> = servings_concrete;
    let logs: Arc<dyn LogRepository> = Arc::new(InMemoryLogRepository::new());
    let users_dyn: Arc<dyn UserRepository> = users_concrete.clone();

    // 3. AuthService + LocalAuthenticator
    let auth_service = Arc::new(AuthService::new(users_concrete.clone(), local_concrete.clone()));
    let authn: Arc<dyn Authenticator> = Arc::new(LocalAuthenticator::new(auth_service.clone()));

    // 4. Optionally wire OIDC registry
    let state_signer = Arc::new(StateSigner::new(SecretBytes(vec![7u8; 32])));

    let oidc_registry: Option<Arc<OidcRegistry>> = if with_oidc {
        // Mount the JWKS mock — path must match the jwks_url's path component
        let jwks_doc = json!({ "keys": [test_key.jwk.clone()] });
        let jwks_path = url::Url::parse(&jwks_url).unwrap().path().to_string();
        Mock::given(method("GET"))
            .and(path(jwks_path.clone()))
            .respond_with(ResponseTemplate::new(200).set_body_json(jwks_doc))
            .mount(&mock_server)
            .await;

        let jwks_verifier = Arc::new(
            JwksVerifier::new(jwks_url.clone(), Duration::from_secs(600))
                .await
                .expect("warm jwks cache"),
        );
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .unwrap();

        let provider_config = OidcProviderConfig {
            id: "authentik".into(),
            display_name: "Authentik".into(),
            issuer: issuer.clone(),
            client_id: "test-client".into(),
            client_secret: "test-secret".into(),
            jwks_url: jwks_url.clone(),
            redirect_uri: "https://fe.example/api/v1/auth/oidc/authentik/callback".into(),
            icon_url: None,
            scopes: vec!["openid".into(), "profile".into(), "email".into()],
        };
        let provider = Arc::new(OidcProvider {
            config: provider_config,
            jwks: jwks_verifier,
            http,
        });

        let mut providers: HashMap<String, Arc<OidcProvider>> = HashMap::new();
        providers.insert("authentik".into(), provider);

        let handoffs_dyn: Arc<dyn OidcHandoffRepository> = handoffs.clone();
        Some(Arc::new(OidcRegistry {
            providers,
            state_signer: state_signer.clone(),
            fe_origin: "https://fe.example".into(),
            handoffs: handoffs_dyn,
            auth: auth_service.clone(),
        }))
    } else {
        None
    };

    let state = AppState::from_ports(
        users_dyn,
        weights,
        goals,
        foods,
        servings,
        logs,
        authn,
        Some(auth_service.clone()),
        oidc_registry,
        true,
        false, // not production → no Secure flag on cookies
    );

    // Compute the URL-path of the token endpoint for per-test wiremock setup
    let computed_token_path = url::Url::parse(&token_url).unwrap().path().to_string();

    Harness {
        app: router(state),
        test_key,
        state_signer,
        issuer,
        token_path: computed_token_path,
        handoffs,
        _mock_server: mock_server,
    }
}

/// Mount a `POST /token/` mock on the harness's mock server that returns a
/// valid signed ID token.
async fn mount_token_mock(
    mock_server: &MockServer,
    issuer: &str,
    key: &TestKey,
    nonce: &str,
    sub: &str,
) {
    // Build the token path from the issuer URL
    let token_url = format!("{}/token/", issuer.trim_end_matches('/'));
    let token_path = url::Url::parse(&token_url)
        .unwrap()
        .path()
        .to_string();
    let n = now_secs();
    let claims = IdTokenClaims {
        iss: issuer.to_string(),
        sub: sub.to_string(),
        aud: "test-client".to_string(),
        exp: n + 3600,
        iat: n,
        nonce: Some(nonce.to_string()),
        email: Some("alice@example.com".to_string()),
        name: Some("Alice".to_string()),
    };
    let id_token = sign_id_token(key, &claims);
    let body = json!({
        "id_token": id_token,
        "access_token": "test-access-token",
        "token_type": "bearer",
    });
    Mock::given(method("POST"))
        .and(path(token_path))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(mock_server)
        .await;
}

/// Build a valid signed state cookie value for provider `authentik`.
fn make_state_cookie(signer: &StateSigner, state_csrf: &str, nonce: &str, next: &str) -> String {
    let payload = state_payload_with_exp(
        "authentik",
        state_csrf,
        "test-pkce-verifier",
        nonce,
        next,
        Utc::now(),
    );
    signer.sign(&payload)
}

async fn body_bytes(resp: axum::http::Response<Body>) -> Vec<u8> {
    to_bytes(resp.into_body(), 64 * 1024).await.unwrap().to_vec()
}

async fn body_json(resp: axum::http::Response<Body>) -> Value {
    let bytes = body_bytes(resp).await;
    serde_json::from_slice(&bytes).expect("response body is JSON")
}

// ── Test cases ────────────────────────────────────────────────────────────────

// 1.
#[tokio::test]
async fn providers_lists_local_when_local_only() {
    // Build harness WITHOUT oidc configured; local login is on.
    let harness = build_harness(false).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/providers")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["local"]["enabled"], true);
    assert_eq!(
        body["oidc"].as_array().map(|a| a.len()).unwrap_or(99),
        0,
        "oidc list must be empty"
    );
}

// 2.
#[tokio::test]
async fn providers_lists_oidc_when_configured() {
    let harness = build_harness(true).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/providers")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["local"]["enabled"], true);
    let oidc = body["oidc"].as_array().expect("oidc must be an array");
    assert_eq!(oidc.len(), 1, "one OIDC provider expected");
    let provider = &oidc[0];
    assert_eq!(provider["id"], "authentik");
    assert_eq!(provider["display_name"], "Authentik");
    assert!(
        provider["start_url"]
            .as_str()
            .unwrap_or("")
            .contains("authentik"),
        "start_url must include provider id"
    );
}

// 3.
#[tokio::test]
async fn start_returns_302_to_authorize_with_pkce() {
    let harness = build_harness(true).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/authentik/start")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SEE_OTHER);
    let location = resp
        .headers()
        .get("location")
        .expect("Location header")
        .to_str()
        .unwrap();

    assert!(
        location.contains("code_challenge="),
        "redirect must contain code_challenge"
    );
    assert!(
        location.contains("code_challenge_method=S256"),
        "redirect must contain code_challenge_method=S256"
    );
    assert!(location.contains("state="), "redirect must contain state");
    assert!(location.contains("nonce="), "redirect must contain nonce");
    assert!(
        location.contains("client_id=test-client"),
        "redirect must contain client_id"
    );
    assert!(
        location.contains("redirect_uri="),
        "redirect must contain redirect_uri"
    );
}

// 4.
#[tokio::test]
async fn start_sets_state_cookie() {
    let harness = build_harness(true).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/authentik/start")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SEE_OTHER);

    let cookies: Vec<&str> = resp
        .headers()
        .get_all("set-cookie")
        .iter()
        .map(|v| v.to_str().unwrap())
        .collect();

    let state_cookie = cookies
        .iter()
        .find(|c| c.contains(STATE_COOKIE_NAME))
        .expect("loseit_oidc_state cookie must be set");

    assert!(
        state_cookie.contains("HttpOnly"),
        "cookie must be HttpOnly"
    );
    assert!(
        state_cookie.to_ascii_lowercase().contains("samesite=lax"),
        "cookie must have SameSite=Lax"
    );
    assert!(
        state_cookie.contains("Max-Age=600"),
        "cookie must have Max-Age=600"
    );
    assert!(
        state_cookie.contains("Path=/api/v1/auth/oidc"),
        "cookie must have Path=/api/v1/auth/oidc"
    );
}

// 5.
#[tokio::test]
async fn start_rejects_bad_next() {
    let harness = build_harness(true).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/authentik/start?next=https://evil.example/")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// 6.
#[tokio::test]
async fn start_accepts_path_next() {
    let harness = build_harness(true).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/authentik/start?next=%2Ffoods")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Should redirect, not 400
    assert_eq!(resp.status(), StatusCode::SEE_OTHER);

    // The state cookie payload should contain the full FE url
    let cookies: Vec<&str> = resp
        .headers()
        .get_all("set-cookie")
        .iter()
        .map(|v| v.to_str().unwrap())
        .collect();
    let state_cookie_header = cookies
        .iter()
        .find(|c| c.contains(STATE_COOKIE_NAME))
        .expect("state cookie must be set");

    // Extract the cookie value (first attribute before ';')
    let cookie_value = state_cookie_header
        .split(';')
        .next()
        .unwrap()
        .trim()
        .strip_prefix(&format!("{}=", STATE_COOKIE_NAME))
        .expect("cookie value");

    // Verify the signed state by decoding it
    let payload = harness
        .state_signer
        .verify(cookie_value)
        .expect("cookie must be valid signed state");
    assert!(
        payload.next.contains("fe.example") && payload.next.contains("/foods"),
        "next must be https://fe.example/foods, got: {}",
        payload.next
    );
}

// 7.
#[tokio::test]
async fn start_404_for_unknown_provider() {
    let harness = build_harness(true).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/does-not-exist/start")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// 8.
#[tokio::test]
async fn callback_happy_path() {
    let harness = build_harness(true).await;

    let state_csrf = "test-state-csrf-value";
    let nonce = "test-nonce-value";
    let cookie_val = make_state_cookie(
        &harness.state_signer,
        state_csrf,
        nonce,
        "https://fe.example/dashboard",
    );

    // Mount the /token mock
    mount_token_mock(
        &harness._mock_server,
        &harness.issuer,
        &harness.test_key,
        nonce,
        "user-sub-001",
    )
    .await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/v1/auth/oidc/authentik/callback?code=authz-code&state={}",
                    state_csrf
                ))
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, cookie_val))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::SEE_OTHER);
    let location = resp
        .headers()
        .get("location")
        .expect("Location header")
        .to_str()
        .unwrap();
    assert!(
        location.contains("oidc_code="),
        "redirect must carry oidc_code, got: {location}"
    );
    assert!(
        location.contains("fe.example"),
        "redirect must go back to fe origin"
    );

    // State cookie must be cleared
    let set_cookies: Vec<&str> = resp
        .headers()
        .get_all("set-cookie")
        .iter()
        .map(|v| v.to_str().unwrap())
        .collect();
    let cleared = set_cookies
        .iter()
        .find(|c| c.contains(STATE_COOKIE_NAME))
        .expect("state cookie must be cleared");
    assert!(
        cleared.contains("Max-Age=0") || cleared.contains("max-age=0"),
        "state cookie Max-Age must be 0 on clear"
    );

    // Handoff row must exist — extract oidc_code from Location
    let url = url::Url::parse(location).unwrap();
    let raw_code = url
        .query_pairs()
        .find(|(k, _)| k == "oidc_code")
        .map(|(_, v)| v.to_string())
        .expect("oidc_code must be in redirect URL");
    let code_hash = sha256_hex(&raw_code);
    let claim = harness
        .handoffs
        .claim(&code_hash)
        .await
        .unwrap()
        .expect("handoff row must exist");
    assert!(!claim.raw_token.is_empty(), "handoff must carry a token");
}

// 9.
#[tokio::test]
async fn callback_state_cookie_tampered_rejected_400() {
    let harness = build_harness(true).await;

    let cookie_val = make_state_cookie(
        &harness.state_signer,
        "csrf-val",
        "nonce-val",
        "https://fe.example/",
    );

    // Flip the last byte of the HMAC tag (after the last '.')
    let dot = cookie_val.rfind('.').unwrap();
    let prefix = &cookie_val[..dot + 1];
    let mut tag_bytes = URL_SAFE_NO_PAD.decode(&cookie_val[dot + 1..]).unwrap();
    let last = tag_bytes.len() - 1;
    tag_bytes[last] ^= 0xFF;
    let tampered = format!("{}{}", prefix, URL_SAFE_NO_PAD.encode(tag_bytes));

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/authentik/callback?code=C&state=csrf-val")
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, tampered))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// 10.
#[tokio::test]
async fn callback_state_query_mismatch_rejected_400() {
    let harness = build_harness(true).await;

    // Cookie has state="correct-csrf" but query has state="wrong-csrf"
    let cookie_val = make_state_cookie(
        &harness.state_signer,
        "correct-csrf",
        "nonce-val",
        "https://fe.example/",
    );

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/authentik/callback?code=C&state=wrong-csrf")
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, cookie_val))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// 11.
#[tokio::test]
async fn callback_expired_state_rejected_400() {
    let harness = build_harness(true).await;

    // Manually build an expired payload (exp = past)
    use loseit_api::auth::oidc::state::StatePayload;
    let payload = StatePayload {
        provider_id: "authentik".into(),
        state: "csrf-val".into(),
        pkce_verifier: "verifier".into(),
        nonce: "nonce-val".into(),
        next: "https://fe.example/".into(),
        exp: Utc::now().timestamp() - 10, // already expired
    };
    let signed = harness.state_signer.sign(&payload);

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri("/api/v1/auth/oidc/authentik/callback?code=C&state=csrf-val")
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, signed))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// 12.
#[tokio::test]
async fn callback_idp_token_failure_returns_502() {
    let harness = build_harness(true).await;

    // Mount a failing /token endpoint
    Mock::given(method("POST"))
        .and(path(harness.token_path.clone()))
        .respond_with(ResponseTemplate::new(500))
        .mount(&harness._mock_server)
        .await;

    let state_csrf = "csrf-for-502";
    let cookie_val = make_state_cookie(
        &harness.state_signer,
        state_csrf,
        "nonce-502",
        "https://fe.example/",
    );

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/v1/auth/oidc/authentik/callback?code=authz-code&state={}",
                    state_csrf
                ))
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, cookie_val))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
}

// 13.
#[tokio::test]
async fn callback_id_token_invalid_sig_rejected_400() {
    let harness = build_harness(true).await;

    // Generate a DIFFERENT key (not in the JWKS mock) to sign the token
    let rogue_key = generate_rsa_key("rogue-k");
    let n = now_secs();
    let claims = IdTokenClaims {
        iss: harness.issuer.clone(),
        sub: "user-rogue".into(),
        aud: "test-client".into(),
        exp: n + 3600,
        iat: n,
        nonce: Some("nonce-sig".into()),
        email: None,
        name: None,
    };
    let bad_token = sign_id_token(&rogue_key, &claims);

    Mock::given(method("POST"))
        .and(path(harness.token_path.clone()))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({
                "id_token": bad_token,
                "access_token": "at",
            })),
        )
        .mount(&harness._mock_server)
        .await;

    let state_csrf = "csrf-bad-sig";
    let cookie_val = make_state_cookie(
        &harness.state_signer,
        state_csrf,
        "nonce-sig",
        "https://fe.example/",
    );

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/v1/auth/oidc/authentik/callback?code=C&state={}",
                    state_csrf
                ))
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, cookie_val))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// 14.
#[tokio::test]
async fn callback_nonce_mismatch_rejected_400() {
    let harness = build_harness(true).await;

    let n = now_secs();
    // Token has nonce "token-nonce" but cookie has "cookie-nonce"
    let claims = IdTokenClaims {
        iss: harness.issuer.clone(),
        sub: "user-nonce".into(),
        aud: "test-client".into(),
        exp: n + 3600,
        iat: n,
        nonce: Some("token-nonce".into()),
        email: None,
        name: None,
    };
    let id_token = sign_id_token(&harness.test_key, &claims);

    Mock::given(method("POST"))
        .and(path(harness.token_path.clone()))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({
                "id_token": id_token,
                "access_token": "at",
            })),
        )
        .mount(&harness._mock_server)
        .await;

    let state_csrf = "csrf-nonce-mm";
    // Cookie nonce is intentionally different from the token nonce
    let cookie_val = make_state_cookie(
        &harness.state_signer,
        state_csrf,
        "cookie-nonce", // <-- mismatch
        "https://fe.example/",
    );

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/v1/auth/oidc/authentik/callback?code=C&state={}",
                    state_csrf
                ))
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, cookie_val))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// 15.
#[tokio::test]
async fn callback_propagates_idp_error_query() {
    let harness = build_harness(true).await;

    let state_csrf = "csrf-error-prop";
    let cookie_val = make_state_cookie(
        &harness.state_signer,
        state_csrf,
        "n",
        "https://fe.example/login",
    );

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/v1/auth/oidc/authentik/callback?error=access_denied&state={}",
                    state_csrf
                ))
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, cookie_val))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    // Must redirect (not 4xx)
    assert_eq!(resp.status(), StatusCode::SEE_OTHER);
    let location = resp
        .headers()
        .get("location")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(
        location.contains("oidc_error=access_denied"),
        "redirect must carry oidc_error, got: {location}"
    );
    // Handoff must NOT be created (no oidc_code in redirect)
    assert!(
        !location.contains("oidc_code="),
        "error redirect must not carry oidc_code"
    );
}

// 16.
#[tokio::test]
async fn exchange_returns_token_then_404_on_replay() {
    let harness = build_harness(true).await;

    // Seed a handoff row manually
    let raw_code = "raw-handoff-code-replay";
    let code_hash = sha256_hex(raw_code);
    harness
        .handoffs
        .insert(
            &code_hash,
            uuid::Uuid::new_v4(),
            "session-token-replay",
            Utc::now() + chrono::Duration::days(30),
            Utc::now() + chrono::Duration::seconds(60),
        )
        .await
        .unwrap();

    // First exchange — must succeed
    let first_resp = harness
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/oidc/exchange")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "code": raw_code }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(first_resp.status(), StatusCode::OK);
    let first_body = body_json(first_resp).await;
    assert_eq!(first_body["token"], "session-token-replay");

    // Second exchange (replay) — must be 401 (or 404)
    let second_resp = harness
        .app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/oidc/exchange")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "code": raw_code }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert!(
        second_resp.status() == StatusCode::UNAUTHORIZED
            || second_resp.status() == StatusCode::NOT_FOUND,
        "replay must be rejected, got {}",
        second_resp.status()
    );
}

// 17.
#[tokio::test]
async fn exchange_404_on_unknown_code() {
    let harness = build_harness(true).await;

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/oidc/exchange")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "code": "totally-unknown-code" }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert!(
        resp.status() == StatusCode::UNAUTHORIZED || resp.status() == StatusCode::NOT_FOUND,
        "unknown code must be rejected, got {}",
        resp.status()
    );
}

// 18.
#[tokio::test]
async fn exchange_404_on_expired_handoff() {
    let harness = build_harness(true).await;

    let raw_code = "expired-handoff-code";
    let code_hash = sha256_hex(raw_code);
    // Insert with an already-expired expires_at
    harness
        .handoffs
        .insert(
            &code_hash,
            uuid::Uuid::new_v4(),
            "some-token",
            Utc::now() + chrono::Duration::days(30),
            Utc::now() - chrono::Duration::seconds(1), // EXPIRED
        )
        .await
        .unwrap();

    let resp = harness
        .app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/oidc/exchange")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "code": raw_code }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert!(
        resp.status() == StatusCode::UNAUTHORIZED || resp.status() == StatusCode::NOT_FOUND,
        "expired handoff must be rejected, got {}",
        resp.status()
    );
}

// 19.
#[tokio::test]
async fn callback_then_exchange_then_get_me() {
    let harness = build_harness(true).await;

    let state_csrf = "e2e-state-csrf";
    let nonce = "e2e-nonce";
    let sub = "e2e-user-sub";

    let cookie_val = make_state_cookie(
        &harness.state_signer,
        state_csrf,
        nonce,
        "https://fe.example/home",
    );

    mount_token_mock(
        &harness._mock_server,
        &harness.issuer,
        &harness.test_key,
        nonce,
        sub,
    )
    .await;

    // Step 1: callback → get oidc_code
    let callback_resp = harness
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/v1/auth/oidc/authentik/callback?code=e2e-code&state={}",
                    state_csrf
                ))
                .header("cookie", format!("{}={}", STATE_COOKIE_NAME, cookie_val))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(callback_resp.status(), StatusCode::SEE_OTHER);
    let location = callback_resp
        .headers()
        .get("location")
        .unwrap()
        .to_str()
        .unwrap();
    let redirect_url = url::Url::parse(location).unwrap();
    let oidc_code = redirect_url
        .query_pairs()
        .find(|(k, _)| k == "oidc_code")
        .map(|(_, v)| v.to_string())
        .expect("oidc_code in callback redirect");

    // Step 2: exchange → get bearer token
    let exchange_resp = harness
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/oidc/exchange")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "code": oidc_code }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(exchange_resp.status(), StatusCode::OK);
    let exchange_body = body_json(exchange_resp).await;
    let bearer = exchange_body["token"]
        .as_str()
        .expect("token must be a string")
        .to_string();
    assert!(!bearer.is_empty(), "bearer token must be non-empty");

    // Step 3: GET /me with the bearer token
    let me_resp = harness
        .app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/me")
                .header("Authorization", format!("Bearer {bearer}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(me_resp.status(), StatusCode::OK);
    let me_body = body_json(me_resp).await;

    // issuer must be the provider id ("authentik"), not the raw issuer URL
    assert_eq!(
        me_body["issuer"], "authentik",
        "issuer must be the provider id"
    );
    assert_eq!(me_body["external_id"], sub, "external_id must match sub");
}
