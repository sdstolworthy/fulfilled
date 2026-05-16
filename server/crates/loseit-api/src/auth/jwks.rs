//! Provider-agnostic OIDC bearer-token authenticator.
//!
//! Plugs into [`Authenticator`] and validates JWTs against a remote JWKS
//! document. Anything that publishes a JWKS at a stable URL works:
//! Auth0, Cognito, Keycloak, Firebase, a homegrown idP, …
//!
//! Wiring is fully driven by `(issuer, audience, jwks_url, cache_ttl)` —
//! no provider-specific code lives here.
//!
//! ## Cache & refresh
//!
//! The JWKS document is cached by `kid → DecodingKey`. A refresh fires
//! when (a) the cache TTL has elapsed *or* (b) a token presents a `kid`
//! we don't yet know about. Concurrent first-uses are deduped through
//! `refresh_lock` — only one upstream `GET /jwks` is in flight at any
//! moment, and peers re-check the cache once they acquire the lock so
//! they don't pile up extra fetches.
//!
//! A failed JWKS fetch does **not** poison the cache. The existing keys
//! stay put so previously-valid tokens still validate until their `exp`
//! claim catches up.
//!
//! ## Algorithm whitelist
//!
//! We explicitly accept `RS256, RS384, RS512, ES256, ES384`. Symmetric
//! algorithms (`HS*`) and `none` are rejected outright — never trust an
//! `alg` claim a peer can choose against keys we publish.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use jsonwebtoken::jwk::{Jwk, JwkSet};
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use loseit_core::auth::{AuthError, Authenticator};
use loseit_core::domain::UserIdentity;
use serde::Deserialize;
use tokio::sync::{Mutex, RwLock};

/// Algorithms we'll actually verify. Anything outside this set is a 401.
const ALLOWED_ALGS: &[Algorithm] = &[
    Algorithm::RS256,
    Algorithm::RS384,
    Algorithm::RS512,
    Algorithm::ES256,
    Algorithm::ES384,
];

/// Leeway in seconds applied to `exp` and `nbf` checks. Mirrors what
/// most providers default to and matches Auth0 / Cognito's own clients.
const LEEWAY_SECS: u64 = 60;

/// Subset of standard OIDC claims we actually surface. `email` / `name`
/// are optional — Cognito and Firebase may emit them, Auth0 sometimes
/// won't unless scopes were requested. Anything missing is fine; the
/// user will end up with `None` for that field.
#[derive(Debug, Deserialize)]
struct Claims {
    iss: String,
    sub: String,
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    name: Option<String>,
}

#[derive(Default)]
struct JwksCacheState {
    keys: HashMap<String, DecodingKey>,
    fetched_at: Option<Instant>,
}

pub struct JwksAuthenticator {
    issuer: String,
    audience: String,
    jwks_url: String,
    cache_ttl: Duration,
    cache: Arc<RwLock<JwksCacheState>>,
    refresh_lock: Arc<Mutex<()>>,
    http: reqwest::Client,
}

impl JwksAuthenticator {
    /// Build the authenticator and warm the JWKS cache via an initial
    /// fetch. Failing here means we couldn't reach the idP at startup;
    /// surfacing that as `anyhow::Error` lets the composition root bail
    /// loudly instead of silently 503-ing every request.
    pub async fn new(
        issuer: String,
        audience: String,
        jwks_url: String,
        cache_ttl: Duration,
    ) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()?;
        let auth = Self {
            issuer,
            audience,
            jwks_url,
            cache_ttl,
            cache: Arc::new(RwLock::new(JwksCacheState::default())),
            refresh_lock: Arc::new(Mutex::new(())),
            http,
        };
        auth.refresh_now().await.map_err(|e| {
            anyhow::anyhow!("initial JWKS fetch from {} failed: {}", auth.jwks_url, e)
        })?;
        Ok(auth)
    }

    /// Look up `kid` in the cache, refreshing if needed. Returns `Ok(None)`
    /// when the key is unknown even after a refresh — caller turns that
    /// into a 401.
    async fn key_for(&self, kid: &str) -> Result<Option<DecodingKey>, AuthError> {
        // Fast path: cache hit and not stale.
        {
            let guard = self.cache.read().await;
            if let Some(key) = guard.keys.get(kid) {
                if !self.is_stale(guard.fetched_at) {
                    return Ok(Some(key.clone()));
                }
            }
        }

        // Refresh under the single-flight lock so concurrent callers
        // don't pile up upstream fetches.
        let _guard = self.refresh_lock.lock().await;

        // Re-check now that we hold the lock. A peer may have refreshed
        // while we waited.
        {
            let guard = self.cache.read().await;
            if let Some(key) = guard.keys.get(kid) {
                if !self.is_stale(guard.fetched_at) {
                    return Ok(Some(key.clone()));
                }
            }
        }

        self.refresh_now().await?;

        let guard = self.cache.read().await;
        Ok(guard.keys.get(kid).cloned())
    }

    fn is_stale(&self, fetched_at: Option<Instant>) -> bool {
        match fetched_at {
            None => true,
            Some(t) => t.elapsed() > self.cache_ttl,
        }
    }

    /// Fetch the JWKS document and replace the cache atomically. Errors
    /// here are surfaced to the caller (→ 503); the existing cache is
    /// left intact so previously-valid tokens keep validating.
    async fn refresh_now(&self) -> Result<(), AuthError> {
        let resp = self
            .http
            .get(&self.jwks_url)
            .send()
            .await
            .map_err(|e| AuthError::Upstream(format!("jwks fetch: {e}")))?;

        if !resp.status().is_success() {
            return Err(AuthError::Upstream(format!(
                "jwks fetch: HTTP {}",
                resp.status()
            )));
        }

        let doc: JwkSet = resp
            .json()
            .await
            .map_err(|e| AuthError::Upstream(format!("jwks parse: {e}")))?;

        let mut new_keys: HashMap<String, DecodingKey> = HashMap::new();
        for jwk in doc.keys.iter() {
            if !is_usable(jwk) {
                tracing::debug!(kid = ?jwk.common.key_id, "skipping unusable JWK");
                continue;
            }
            let Some(kid) = jwk.common.key_id.clone() else {
                tracing::debug!("skipping JWK without `kid`");
                continue;
            };
            let key = match DecodingKey::from_jwk(jwk) {
                Ok(k) => k,
                Err(e) => {
                    tracing::warn!(error = %e, %kid, "failed to materialise DecodingKey from JWK");
                    continue;
                }
            };
            new_keys.insert(kid, key);
        }

        let mut guard = self.cache.write().await;
        *guard = JwksCacheState {
            keys: new_keys,
            fetched_at: Some(Instant::now()),
        };
        Ok(())
    }
}

/// Accept only signing keys with an `alg` we'd actually verify. Keys
/// without an `alg` field are also fine — `DecodingKey::from_jwk`
/// infers from `kty`, and the per-request `Validation` whitelist will
/// still gate which `alg` claim the *token* may use.
fn is_usable(jwk: &Jwk) -> bool {
    use jsonwebtoken::jwk::PublicKeyUse;

    if let Some(use_) = &jwk.common.public_key_use {
        if !matches!(use_, PublicKeyUse::Signature) {
            return false;
        }
    }
    if let Some(alg) = jwk.common.key_algorithm {
        let alg_str = format!("{alg:?}");
        let allowed = ALLOWED_ALGS.iter().any(|a| format!("{a:?}") == alg_str);
        if !allowed {
            return false;
        }
    }
    true
}

#[async_trait]
impl Authenticator for JwksAuthenticator {
    async fn authenticate(&self, token: &str) -> Result<UserIdentity, AuthError> {
        let header = decode_header(token).map_err(|_| AuthError::Invalid)?;
        let Some(kid) = header.kid else {
            return Err(AuthError::Invalid);
        };
        if !ALLOWED_ALGS.contains(&header.alg) {
            return Err(AuthError::Invalid);
        }

        let key = match self.key_for(&kid).await? {
            Some(k) => k,
            None => return Err(AuthError::Invalid),
        };

        // Validation::algorithms must all match the key's family (RSA vs
        // EC), so we narrow to the header's `alg` here. The whitelist
        // gate above already ensured `header.alg` is one we accept.
        let mut validation = Validation::new(header.alg);
        validation.algorithms = vec![header.alg];
        validation.set_issuer(&[&self.issuer]);
        validation.set_audience(&[&self.audience]);
        validation.validate_exp = true;
        validation.validate_nbf = true;
        validation.leeway = LEEWAY_SECS;
        validation.required_spec_claims =
            HashSet::from(["exp".to_string(), "iss".to_string(), "aud".to_string()]);

        let data = decode::<Claims>(token, &key, &validation).map_err(|e| {
            tracing::debug!(error = %e, "jwt decode failed");
            AuthError::Invalid
        })?;

        Ok(UserIdentity {
            issuer: data.claims.iss,
            external_id: data.claims.sub,
            email: data.claims.email,
            display_name: data.claims.name,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use jsonwebtoken::{encode, EncodingKey, Header};
    use rsa::pkcs1::{EncodeRsaPrivateKey, EncodeRsaPublicKey};
    use rsa::pkcs8::LineEnding;
    use rsa::traits::PublicKeyParts;
    use rsa::RsaPrivateKey;
    use serde::Serialize;
    use serde_json::{json, Value};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};
    use wiremock::matchers::method;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    /// Test-only claims helper — mirrors a typical OIDC ID token payload.
    /// We use `Value`s for `aud` to exercise both the string and array
    /// flavour the providers emit.
    #[derive(Serialize)]
    struct TestClaims {
        iss: String,
        sub: String,
        aud: Value,
        exp: i64,
        iat: i64,
        nbf: i64,
        #[serde(skip_serializing_if = "Option::is_none")]
        email: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        name: Option<String>,
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

    fn b64url(bytes: &[u8]) -> String {
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        use base64::Engine as _;
        URL_SAFE_NO_PAD.encode(bytes)
    }

    fn generate_rsa_key(kid: &str) -> TestKey {
        let mut rng = rand::thread_rng();
        let private = RsaPrivateKey::new(&mut rng, 2048).expect("key gen");
        let public = private.to_public_key();

        let pem = private
            .to_pkcs1_pem(LineEnding::LF)
            .expect("private pem")
            .to_string();
        let encoding = EncodingKey::from_rsa_pem(pem.as_bytes()).expect("encoding key");

        // Sanity check: round-trip the public key as PEM too in case anyone
        // ever wants to plug it into a different test path. Not strictly
        // needed for the JWKS document — we build that from n/e directly.
        let _public_pem = public.to_pkcs1_pem(LineEnding::LF).expect("public pem");

        let n = b64url(&public.n().to_bytes_be());
        let e = b64url(&public.e().to_bytes_be());

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

    fn make_claims(iss: &str, aud: Value, sub: &str) -> TestClaims {
        let n = now();
        TestClaims {
            iss: iss.to_string(),
            sub: sub.to_string(),
            aud,
            exp: n + 3600,
            iat: n,
            nbf: n - 5,
            email: Some("alice@example.com".to_string()),
            name: Some("Alice".to_string()),
        }
    }

    fn jwks_doc(keys: &[&TestKey]) -> Value {
        let arr: Vec<Value> = keys.iter().map(|k| k.jwk.clone()).collect();
        json!({ "keys": arr })
    }

    async fn mock_jwks(server: &MockServer, body: Value) {
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(200).set_body_json(body))
            .mount(server)
            .await;
    }

    #[tokio::test]
    async fn accepts_token_signed_by_known_kid() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        let token = sign(
            &key,
            &make_claims("https://issuer.example", json!("loseit-api"), "user-123"),
        );
        let identity = auth.authenticate(&token).await.expect("valid token");
        assert_eq!(identity.issuer, "https://issuer.example");
        assert_eq!(identity.external_id, "user-123");
        assert_eq!(identity.email.as_deref(), Some("alice@example.com"));
        assert_eq!(identity.display_name.as_deref(), Some("Alice"));
    }

    #[tokio::test]
    async fn rejects_token_with_hs256() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        // Hand-build an HS256 token signed with a shared secret. The
        // attacker's gambit is that a naive verifier might trust the
        // `alg` header and verify against the JWKS RSA public key as
        // HMAC. We must refuse before we even look at the key.
        let secret = b"super-secret";
        let mut header = Header::new(Algorithm::HS256);
        header.kid = Some("k1".to_string());
        let claims = make_claims("https://issuer.example", json!("loseit-api"), "user-123");
        let token =
            encode(&header, &claims, &EncodingKey::from_secret(secret)).expect("hs256 encode");

        let err = auth
            .authenticate(&token)
            .await
            .expect_err("hs256 must be rejected");
        assert!(matches!(err, AuthError::Invalid));
    }

    #[tokio::test]
    async fn rejects_token_with_missing_kid() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;
        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        let header = Header::new(Algorithm::RS256); // no kid
        let claims = make_claims("https://issuer.example", json!("loseit-api"), "user-123");
        let token = encode(&header, &claims, &key.encoding).expect("encode");

        let err = auth.authenticate(&token).await.expect_err("no kid → 401");
        assert!(matches!(err, AuthError::Invalid));
    }

    #[tokio::test]
    async fn refreshes_on_unknown_kid_then_accepts() {
        // First JWKS doc has only k1. Token is signed with k2. The
        // authenticator should refresh, see k2, and accept the token.
        let k1 = generate_rsa_key("k1");
        let k2 = generate_rsa_key("k2");

        let server = MockServer::start().await;
        // Serve only k1 initially.
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = hits.clone();
        let doc_initial = jwks_doc(&[&k1]);
        let doc_after_rotation = jwks_doc(&[&k1, &k2]);

        Mock::given(method("GET"))
            .respond_with(move |_req: &wiremock::Request| {
                let n = hits_clone.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    ResponseTemplate::new(200).set_body_json(doc_initial.clone())
                } else {
                    ResponseTemplate::new(200).set_body_json(doc_after_rotation.clone())
                }
            })
            .mount(&server)
            .await;

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(3600),
        )
        .await
        .expect("warm cache");

        let token = sign(
            &k2,
            &make_claims("https://issuer.example", json!("loseit-api"), "user-123"),
        );
        auth.authenticate(&token).await.expect("refresh + accept");
        assert!(
            hits.load(Ordering::SeqCst) >= 2,
            "should have refreshed at least once after warm-up"
        );
    }

    #[tokio::test]
    async fn rejects_unknown_kid_after_refresh() {
        let known = generate_rsa_key("k1");
        let attacker = generate_rsa_key("attacker");

        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&known])).await;

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(3600),
        )
        .await
        .expect("warm cache");

        let token = sign(
            &attacker,
            &make_claims("https://issuer.example", json!("loseit-api"), "user-123"),
        );
        let err = auth
            .authenticate(&token)
            .await
            .expect_err("unknown kid → 401");
        assert!(matches!(err, AuthError::Invalid));
    }

    #[tokio::test]
    async fn rejects_expired_token() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        // exp 5 minutes ago — well outside the 60s leeway.
        let mut claims = make_claims("https://issuer.example", json!("loseit-api"), "user-123");
        claims.exp = now() - 300;
        claims.iat = now() - 600;
        claims.nbf = now() - 600;
        let token = sign(&key, &claims);

        let err = auth.authenticate(&token).await.expect_err("expired → 401");
        assert!(matches!(err, AuthError::Invalid));
    }

    #[tokio::test]
    async fn accepts_token_within_leeway() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        // exp 30s ago — inside the 60s leeway, should still validate.
        let mut claims = make_claims("https://issuer.example", json!("loseit-api"), "user-123");
        claims.exp = now() - 30;
        let token = sign(&key, &claims);

        auth.authenticate(&token).await.expect("inside leeway");
    }

    #[tokio::test]
    async fn rejects_wrong_issuer() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;
        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        let token = sign(
            &key,
            &make_claims("https://wrong.example", json!("loseit-api"), "user-123"),
        );
        let err = auth
            .authenticate(&token)
            .await
            .expect_err("issuer mismatch → 401");
        assert!(matches!(err, AuthError::Invalid));
    }

    #[tokio::test]
    async fn rejects_wrong_audience() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;
        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        let token = sign(
            &key,
            &make_claims("https://issuer.example", json!("other-api"), "user-123"),
        );
        let err = auth
            .authenticate(&token)
            .await
            .expect_err("audience mismatch → 401");
        assert!(matches!(err, AuthError::Invalid));
    }

    #[tokio::test]
    async fn rejects_nbf_in_future() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;
        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        let mut claims = make_claims("https://issuer.example", json!("loseit-api"), "user-123");
        // nbf 5 minutes in the future, well past the 60s leeway.
        claims.nbf = now() + 300;
        claims.iat = now();
        let token = sign(&key, &claims);

        let err = auth.authenticate(&token).await.expect_err("nbf → 401");
        assert!(matches!(err, AuthError::Invalid));
    }

    #[tokio::test]
    async fn accepts_audience_as_array() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        mock_jwks(&server, jwks_doc(&[&key])).await;
        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        .expect("warm cache");

        let token = sign(
            &key,
            &make_claims(
                "https://issuer.example",
                json!(["other-api", "loseit-api"]),
                "user-123",
            ),
        );
        auth.authenticate(&token).await.expect("array aud accepted");
    }

    #[tokio::test]
    async fn upstream_failure_at_construction_propagates() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;

        let err = match JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(600),
        )
        .await
        {
            Ok(_) => panic!("initial fetch should fail"),
            Err(e) => e,
        };
        let msg = format!("{err:#}");
        assert!(msg.contains("jwks fetch"), "got: {msg}");
    }

    #[tokio::test]
    async fn upstream_failure_after_warmup_returns_upstream_error() {
        // Warm with k1, then make the JWKS endpoint start returning 500.
        // A request with an *unknown* kid forces a refresh, which fails →
        // AuthError::Upstream (maps to 503 at the HTTP layer).
        let k1 = generate_rsa_key("k1");

        let server = MockServer::start().await;
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = hits.clone();
        let doc = jwks_doc(&[&k1]);

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

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(3600),
        )
        .await
        .expect("warm cache");

        // Token signed with an unknown kid forces a refresh.
        let k2 = generate_rsa_key("k2");
        let token = sign(
            &k2,
            &make_claims("https://issuer.example", json!("loseit-api"), "user-123"),
        );
        let err = auth.authenticate(&token).await.expect_err("refresh fails");
        assert!(matches!(err, AuthError::Upstream(_)));
    }

    #[tokio::test]
    async fn cached_within_ttl_does_not_refetch() {
        let key = generate_rsa_key("k1");
        let server = MockServer::start().await;
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = hits.clone();
        let doc = jwks_doc(&[&key]);

        Mock::given(method("GET"))
            .respond_with(move |_req: &wiremock::Request| {
                hits_clone.fetch_add(1, Ordering::SeqCst);
                ResponseTemplate::new(200).set_body_json(doc.clone())
            })
            .mount(&server)
            .await;

        let auth = JwksAuthenticator::new(
            "https://issuer.example".into(),
            "loseit-api".into(),
            format!("{}/", server.uri()),
            Duration::from_secs(3600),
        )
        .await
        .expect("warm cache");

        // After warm-up there should be exactly one fetch.
        assert_eq!(hits.load(Ordering::SeqCst), 1);

        for _ in 0..5 {
            let token = sign(
                &key,
                &make_claims("https://issuer.example", json!("loseit-api"), "user-123"),
            );
            auth.authenticate(&token).await.expect("cached");
        }
        assert_eq!(
            hits.load(Ordering::SeqCst),
            1,
            "no extra fetches within TTL"
        );
    }

    #[tokio::test]
    async fn concurrent_unknown_kid_dedups_refreshes() {
        // Warm-up returns k1. Then 10 parallel requests show up with
        // kid=k2 — the refresh_lock must serialize them so only one
        // upstream refetch happens.
        let k1 = generate_rsa_key("k1");
        let k2 = generate_rsa_key("k2");

        let server = MockServer::start().await;
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = hits.clone();
        let doc_initial = jwks_doc(&[&k1]);
        let doc_after = jwks_doc(&[&k1, &k2]);

        Mock::given(method("GET"))
            .respond_with(move |_req: &wiremock::Request| {
                let n = hits_clone.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    ResponseTemplate::new(200).set_body_json(doc_initial.clone())
                } else {
                    ResponseTemplate::new(200).set_body_json(doc_after.clone())
                }
            })
            .mount(&server)
            .await;

        let auth = Arc::new(
            JwksAuthenticator::new(
                "https://issuer.example".into(),
                "loseit-api".into(),
                format!("{}/", server.uri()),
                Duration::from_secs(3600),
            )
            .await
            .expect("warm cache"),
        );
        assert_eq!(hits.load(Ordering::SeqCst), 1);

        let mut handles = Vec::new();
        for i in 0..10 {
            let auth = auth.clone();
            let token = sign(
                &k2,
                &make_claims(
                    "https://issuer.example",
                    json!("loseit-api"),
                    &format!("user-{i}"),
                ),
            );
            handles.push(tokio::spawn(async move { auth.authenticate(&token).await }));
        }
        for h in handles {
            h.await.unwrap().expect("all accepted");
        }

        // Initial warm-up = 1 fetch, plus exactly one refresh for the
        // burst of unknown kids.
        assert_eq!(
            hits.load(Ordering::SeqCst),
            2,
            "single refresh under refresh_lock"
        );
    }
}
