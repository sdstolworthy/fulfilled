use axum::extract::{Path, Query, State};
use axum::response::Redirect;
use axum::routing::{get, post};
use axum::{Json, Router};
use axum_extra::extract::cookie::{Cookie, SameSite};
use axum_extra::extract::CookieJar;
use chrono::{DateTime, Utc};
use loseit_core::domain::UserIdentity;
use serde::{Deserialize, Serialize};

use crate::auth::oidc::state::{StatePayload, STATE_TTL_SECS};
use crate::error::ApiError;
use crate::server::{AppState, OidcProvider};

#[derive(Deserialize)]
struct LoginBody {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct LoginResponse {
    token: String,
    expires_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct ExchangeBody {
    code: String,
}

#[derive(Serialize)]
struct ExchangeResponse {
    token: String,
    expires_at: DateTime<Utc>,
}

#[derive(Serialize)]
struct ProvidersResponse {
    local: LocalProviderDescriptor,
    oidc: Vec<OidcProviderDescriptor>,
}

#[derive(Serialize)]
struct LocalProviderDescriptor {
    enabled: bool,
}

#[derive(Serialize)]
struct OidcProviderDescriptor {
    id: String,
    display_name: String,
    icon_url: Option<String>,
    start_url: String,
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/auth/providers", get(providers))
        .route("/auth/login", post(login))
        .route("/auth/oidc/:id/start", get(oidc_start))
        .route("/auth/oidc/:id/callback", get(oidc_callback))
        .route("/auth/oidc/exchange", post(oidc_exchange))
}

async fn login(
    State(state): State<AppState>,
    Json(body): Json<LoginBody>,
) -> Result<Json<LoginResponse>, ApiError> {
    let Some(auth) = state.auth.clone() else {
        // Defensive: route is normally not mounted when auth is None,
        // but guard against state-level confusion.
        return Err(ApiError::not_found());
    };
    let token = auth.login(&body.username, &body.password).await?;
    Ok(Json(LoginResponse {
        token: token.raw,
        expires_at: token.expires_at,
    }))
}

// ── OIDC start ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct StartParams {
    next: Option<String>,
}

/// Validate the `next` redirect destination against the configured `fe_origin`.
///
/// Accepts:
/// - Path-only URLs (start with `/`): prepends `fe_origin`.
/// - Absolute URLs whose origin equals `fe_origin`.
///
/// Rejects scheme-relative URLs (`//`), backslash-containing strings, and any
/// absolute URL from a different origin.
pub fn resolve_next(fe_origin: &str, next: Option<&str>) -> Result<String, ApiError> {
    let raw = next.unwrap_or("/");
    if raw.starts_with("//") || raw.contains('\\') {
        return Err(ApiError::bad_request("invalid `next`"));
    }
    if raw.starts_with('/') {
        return Ok(format!("{}{}", fe_origin.trim_end_matches('/'), raw));
    }
    let url = url::Url::parse(raw).map_err(|_| ApiError::bad_request("invalid `next`"))?;
    let origin = format!(
        "{}://{}{}",
        url.scheme(),
        url.host_str().unwrap_or(""),
        url.port().map(|p| format!(":{p}")).unwrap_or_default(),
    );
    if origin == fe_origin.trim_end_matches('/') {
        Ok(raw.to_string())
    } else {
        Err(ApiError::bad_request("`next` origin not allowed"))
    }
}

fn b64url_random(n_bytes: usize) -> String {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    use rand::RngCore;
    let mut bytes = vec![0u8; n_bytes];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn b64url_sha256(input: &str) -> String {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
    use sha2::{Digest, Sha256};
    URL_SAFE_NO_PAD.encode(Sha256::digest(input.as_bytes()))
}

fn build_authorize_url(
    p: &OidcProvider,
    state_csrf: &str,
    code_challenge: &str,
    nonce: &str,
) -> String {
    let mut url = url::Url::parse(&p.config.issuer).expect("issuer URL validated at boot");
    url.path_segments_mut()
        .unwrap()
        .pop_if_empty()
        .push("authorize");
    url.query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", &p.config.client_id)
        .append_pair("redirect_uri", &p.config.redirect_uri)
        .append_pair("scope", &p.config.scopes.join(" "))
        .append_pair("state", state_csrf)
        .append_pair("nonce", nonce)
        .append_pair("code_challenge", code_challenge)
        .append_pair("code_challenge_method", "S256");
    url.to_string()
}

fn build_state_cookie(value: String, secure: bool) -> Cookie<'static> {
    let mut c = Cookie::new("loseit_oidc_state", value);
    c.set_http_only(true);
    c.set_same_site(SameSite::Lax);
    c.set_max_age(time::Duration::seconds(600));
    c.set_path("/api/v1/auth/oidc");
    if secure {
        c.set_secure(true);
    }
    c
}

async fn oidc_start(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Query(params): Query<StartParams>,
    cookies: CookieJar,
) -> Result<(CookieJar, Redirect), ApiError> {
    let registry = state.oidc.as_ref().ok_or_else(|| ApiError::not_found())?;
    let provider = registry
        .providers
        .get(&provider_id)
        .ok_or_else(|| ApiError::not_found())?;

    let next = resolve_next(&registry.fe_origin, params.next.as_deref())?;

    let pkce_verifier = b64url_random(32);
    let code_challenge = b64url_sha256(&pkce_verifier);
    let state_csrf = b64url_random(32);
    let nonce = b64url_random(32);

    let payload = StatePayload {
        provider_id: provider_id.clone(),
        state: state_csrf.clone(),
        pkce_verifier,
        nonce: nonce.clone(),
        next,
        exp: (chrono::Utc::now() + chrono::Duration::seconds(STATE_TTL_SECS)).timestamp(),
    };
    let signed = registry.state_signer.sign(&payload);

    let authorize_url = build_authorize_url(provider, &state_csrf, &code_challenge, &nonce);
    let cookie = build_state_cookie(signed, state.env_is_production);
    Ok((cookies.add(cookie), Redirect::to(&authorize_url)))
}

// ── OIDC callback ─────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct CallbackParams {
    code: Option<String>,
    state: String,
    #[allow(dead_code)]
    error: Option<String>,
    #[allow(dead_code)]
    error_description: Option<String>,
}

#[derive(Deserialize)]
struct TokenResponse {
    id_token: String,
    // We don't keep access_token or refresh_token.
}

async fn oidc_callback(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Query(params): Query<CallbackParams>,
    cookies: CookieJar,
) -> Result<(CookieJar, Redirect), ApiError> {
    let registry = state.oidc.as_ref().ok_or_else(|| ApiError::not_found())?;
    let provider = registry
        .providers
        .get(&provider_id)
        .ok_or_else(|| ApiError::not_found())?;

    // 1. Read + verify state cookie.
    let signed = cookies
        .get("loseit_oidc_state")
        .ok_or_else(|| ApiError::bad_request("missing state cookie"))?;
    let payload = registry
        .state_signer
        .verify(signed.value())
        .map_err(|_| ApiError::bad_request("invalid state cookie"))?;

    // 2. Same-provider + CSRF check.
    if payload.provider_id != provider_id {
        return Err(ApiError::bad_request("provider mismatch"));
    }
    use subtle::ConstantTimeEq;
    if payload
        .state
        .as_bytes()
        .ct_eq(params.state.as_bytes())
        .unwrap_u8()
        == 0
    {
        return Err(ApiError::bad_request("state mismatch"));
    }

    // 3. Either the IdP told us about an error, or we have a code.
    if let Some(err) = params.error.as_deref() {
        let cleared = clear_state_cookie(state.env_is_production);
        let url = next_with_error(&payload.next, err);
        return Ok((cookies.add(cleared), Redirect::to(&url)));
    }
    let code = params
        .code
        .ok_or_else(|| ApiError::bad_request("missing code"))?;

    // 4. Exchange code at the IdP's /token endpoint.
    let token_resp = exchange_code(provider, &code, &payload.pkce_verifier).await?;

    // 5. Verify ID token via JWKS, checking iss + aud + nonce.
    let claims = provider
        .jwks
        .verify(
            &token_resp.id_token,
            &provider.config.issuer,
            &provider.config.client_id,
            Some(&payload.nonce),
        )
        .await
        .map_err(|_| ApiError::bad_request("invalid id_token"))?;

    // 6. Upsert local user row.
    let identity = UserIdentity {
        issuer: provider_id.clone(),
        external_id: claims.sub.clone(),
        email: claims.email.clone(),
        display_name: claims.name.clone().or(claims.preferred_username.clone()),
    };
    let user = state
        .users
        .ensure_user(&identity)
        .await
        .map_err(|e| ApiError::internal(format!("ensure_user: {e}")))?;

    // 7. Mint opaque session token.
    let session = registry
        .auth
        .mint_session_for(user.id)
        .await
        .map_err(|e| ApiError::internal(format!("mint_session: {e}")))?;

    // 8. Insert handoff row (60s TTL).
    let handoff_raw = b64url_random(32);
    let code_hash = sha256_hex(&handoff_raw);
    let handoff_expires_at = chrono::Utc::now() + chrono::Duration::seconds(60);
    registry
        .handoffs
        .insert(
            &code_hash,
            user.id,
            &session.raw,
            session.expires_at,
            handoff_expires_at,
        )
        .await
        .map_err(|e| ApiError::internal(format!("handoff insert: {e}")))?;

    // 9. Clear the state cookie + 302 the browser back to the FE.
    let cleared = clear_state_cookie(state.env_is_production);
    let redirect_url = next_with_handoff(&payload.next, &handoff_raw);
    Ok((cookies.add(cleared), Redirect::to(&redirect_url)))
}

async fn exchange_code(
    p: &OidcProvider,
    code: &str,
    pkce_verifier: &str,
) -> Result<TokenResponse, ApiError> {
    let token_url = format!("{}/token/", p.config.issuer.trim_end_matches('/'));
    let resp = p
        .http
        .post(&token_url)
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", p.config.redirect_uri.as_str()),
            ("client_id", p.config.client_id.as_str()),
            ("client_secret", p.config.client_secret.as_str()),
            ("code_verifier", pkce_verifier),
        ])
        .send()
        .await
        .map_err(|e| ApiError::bad_gateway(format!("idp /token: {e}")))?;
    if !resp.status().is_success() {
        return Err(ApiError::bad_gateway(format!(
            "idp /token returned {}",
            resp.status()
        )));
    }
    resp.json::<TokenResponse>()
        .await
        .map_err(|e| ApiError::bad_gateway(format!("idp /token body: {e}")))
}

fn clear_state_cookie(secure: bool) -> Cookie<'static> {
    let mut c = Cookie::new("loseit_oidc_state", "");
    c.set_http_only(true);
    c.set_same_site(SameSite::Lax);
    c.set_max_age(time::Duration::ZERO);
    c.set_path("/api/v1/auth/oidc");
    if secure {
        c.set_secure(true);
    }
    c
}

fn next_with_handoff(next: &str, handoff: &str) -> String {
    let mut url = url::Url::parse(next).expect("next validated at start");
    url.query_pairs_mut().append_pair("oidc_code", handoff);
    url.to_string()
}

fn next_with_error(next: &str, err: &str) -> String {
    let mut url = url::Url::parse(next).expect("next validated at start");
    url.query_pairs_mut().append_pair("oidc_error", err);
    url.to_string()
}

// ── OIDC exchange ─────────────────────────────────────────────────────────────

async fn oidc_exchange(
    State(state): State<AppState>,
    Json(body): Json<ExchangeBody>,
) -> Result<Json<ExchangeResponse>, ApiError> {
    let registry = state.oidc.as_ref().ok_or_else(|| ApiError::not_found())?;
    let code_hash = sha256_hex(&body.code);
    let claim = registry
        .handoffs
        .claim(&code_hash)
        .await
        .map_err(|e| ApiError::internal(format!("handoff claim: {e}")))?
        .ok_or_else(|| ApiError::unauthorized("invalid or expired handoff code"))?;
    Ok(Json(ExchangeResponse {
        token: claim.raw_token,
        expires_at: claim.token_expires_at,
    }))
}

fn sha256_hex(input: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(input.as_bytes())
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect()
}

async fn providers(State(state): State<AppState>) -> Json<ProvidersResponse> {
    let local = LocalProviderDescriptor {
        enabled: state.local_login_enabled,
    };
    let oidc = state
        .oidc
        .as_ref()
        .map(|r| {
            r.providers
                .values()
                .map(|p| OidcProviderDescriptor {
                    id: p.config.id.clone(),
                    display_name: p.config.display_name.clone(),
                    icon_url: p.config.icon_url.clone(),
                    start_url: format!("/api/v1/auth/oidc/{}/start", p.config.id),
                })
                .collect()
        })
        .unwrap_or_default();
    Json(ProvidersResponse { local, oidc })
}
