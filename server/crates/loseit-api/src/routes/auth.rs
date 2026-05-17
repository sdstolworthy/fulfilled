use axum::extract::{Path, Query, State};
use axum::response::Redirect;
use axum::routing::{get, post};
use axum::{Json, Router};
use axum_extra::extract::cookie::{Cookie, SameSite};
use axum_extra::extract::CookieJar;
use chrono::{DateTime, Utc};
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
