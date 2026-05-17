# BE-OIDC — Authentik / OIDC integration — Architect Design

Ask 8 (`backend_tasks.md:463+`). Backend-as-RP OAuth 2.1 / OIDC code flow
with PKCE, signed-cookie state, one-time handoff-code ferry to the FE,
and a 60s-TTL `oidc_handoff_codes` table. `AuthConfig` is refactored
from a single-method enum into a multi-method struct so OIDC coexists
with the existing local-creds flow (BE-008) and the dev-bypass escape
hatch on the same deploy. OIDC users mint opaque bearers via the same
`AuthService` path as `/auth/login`, so the FE has one token type and
the server has one revocation surface. No in-repo Authentik blueprint:
the user provisions the provider in Authentik's UI and the backend
reads `issuer`, `client_id`, `client_secret` from env.

---

## 1. Overview

**In scope.**

- Backend-as-RP shape: the FE sees only a list of providers and a
  per-provider `start_url`. The browser bounces FE → BE `/start` → IdP
  authorize → IdP login → BE `/callback` → FE `<next>?oidc_code=…` →
  FE `POST /auth/oidc/exchange` → opaque bearer token. `client_secret`
  never leaves the BE.
- PKCE mandatory even for the confidential client (RFC 9700 / OAuth 2.1
  BCP).
- State management: HMAC-SHA256-signed `loseit_oidc_state` cookie. No
  Redis, no in-memory map.
- Token ferry: opaque token does **not** appear in any URL the browser
  history sees. A 32-byte handoff code is the only thing in the
  redirect; the real bearer is fetched by the FE over POST.
- `AuthConfig` becomes a struct (`{dev_bypass, local, oidc: Vec<…>}`)
  so any combination of methods coexists on the same boot.
- OIDC users land in the existing `users(issuer, external_id)` table
  via `ensure_user(&UserIdentity)`. Token mint goes through
  `AuthService::mint_session_for(user_id)` — an extraction of the
  bearer-issue path inside `AuthService::login`. One token table
  (`local_auth_tokens`), one revocation surface.
- One migration: `0009_oidc_handoff_codes.sql`.
- Four new routes, all `security: []`:
  - `GET /api/v1/auth/providers`
  - `GET /api/v1/auth/oidc/{id}/start`
  - `GET /api/v1/auth/oidc/{id}/callback`
  - `POST /api/v1/auth/oidc/exchange`

**Out of scope (explicit, deferred to v1.1 per FE asks).**

- Authentik provisioning. No blueprint YAML, no Coolify automation of
  the IdP-side configuration. The operator sets up the provider +
  application in Authentik's UI and fills env vars.
- Refresh-token rotation. We mint a 30-day opaque session at callback
  and let the existing sliding-window logic carry. The IdP refresh
  token is discarded post-exchange.
- Multi-IdP-per-user account linking. Each `(issuer, external_id)` is
  its own `users` row. A user who signs in via Authentik on Monday and
  via local-creds on Tuesday gets two distinct rows. Flag in §13.
- IdP-side logout / single-logout. Pressing "sign out" in the app
  drops the BE token; the IdP session lives until Authentik decides.
- `/auth/oidc/{id}/end_session` or back-channel logout endpoints.

**What's not changing.**

- `local_auth_tokens` schema. The handoff table holds the raw token
  for 60s; the existing token row is created normally.
- `JwksAuthenticator`. Untouched. The OIDC code path verifies ID tokens
  with a per-provider JWKS verifier reused from the same machinery (see
  §4) — but the existing `JwksAuthenticator` bearer-validation surface
  is not part of the request path for OIDC users. Once minted, OIDC
  users authenticate via `LocalAuthenticator` like everyone else.
- `LocalAuthenticator` / `AuthService::verify_token` / the sliding-
  window TTL.
- The `Authenticator` trait. OIDC is composition glue, not a new
  validator surface.

---

## 2. `AuthConfig` refactor — `server/crates/loseit-api/src/config.rs`

**Enum → struct.** The old `AuthConfig::Local | Jwks | DevBypass`
enforced "exactly one mode." Ask 8 needs "any subset." The struct lets
`load_auth` validate "at least one method" and "dev-bypass not in
production" independently.

```rust
#[derive(Debug, Clone, Default)]
pub struct AuthConfig {
    /// `Some(_)` when `DEV_AUTH_BYPASS=true`. Refused in production.
    pub dev_bypass: Option<DevBypassConfig>,
    /// `Some(LocalConfig)` when the local-creds path is on. Today this
    /// is `LocalConfig` (no fields) — the presence of the row turns the
    /// `/auth/login` route + seed on.
    pub local: Option<LocalConfig>,
    /// One entry per OIDC provider. Empty when no `OIDC_PROVIDERS` env.
    pub oidc: Vec<OidcProviderConfig>,
}

#[derive(Debug, Clone)]
pub struct DevBypassConfig {
    pub token: String,
    pub issuer: String,
    pub external_id: String,
    pub email: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct LocalConfig {} // marker today; field-bag for future tuning

#[derive(Debug, Clone)]
pub struct OidcProviderConfig {
    /// URL-safe slug, e.g. "authentik". Used in route paths
    /// (`/auth/oidc/{id}/start`). `[a-z0-9_-]{1,32}` enforced at
    /// load time so we don't generate routes containing path
    /// metacharacters.
    pub id: String,
    pub display_name: String,
    /// Issuer URL, e.g.
    /// `https://authentik.stolworthy.co/application/o/fulfilled/`.
    /// This is also the `iss` claim we validate on the ID token.
    pub issuer: String,
    pub client_id: String,
    pub client_secret: String,
    /// Provider JWKS URL. Defaults to `<issuer>/jwks/` (Authentik
    /// shape) if `OIDC_<ID>_JWKS_URL` is unset.
    pub jwks_url: String,
    /// OUR callback URL, e.g.
    /// `https://api.coolify.stolworthy.co/api/v1/auth/oidc/authentik/callback`.
    /// Must match the redirect URI registered in the provider exactly.
    pub redirect_uri: String,
    pub icon_url: Option<String>,
    pub scopes: Vec<String>,
}

/// Required when `!auth.oidc.is_empty()`. Refuse boot otherwise.
#[derive(Debug, Clone)]
pub struct OidcCommonConfig {
    /// HMAC-SHA256 key (32+ bytes after decode) for the
    /// `loseit_oidc_state` cookie signature.
    pub state_secret: SecretBytes,
    /// Origin we'll redirect the browser back to after a successful
    /// callback. The `next` query parameter on `/start` is validated
    /// against this. Example: `https://app.coolify.stolworthy.co`.
    pub fe_origin: String,
    /// Outgoing HTTP timeout when talking to the IdP's `/token` and
    /// JWKS endpoints. Default 10s. Surfaced for testability.
    pub http_timeout_secs: u64,
}
```

`AppConfig` gains one field:

```rust
pub struct AppConfig {
    // … existing …
    pub auth: AuthConfig,
    pub oidc_common: Option<OidcCommonConfig>, // Some(_) iff !auth.oidc.is_empty()
}
```

### 2.1 Env parsing — `load_auth`

```rust
fn load_auth(env_name: &str) -> Result<(AuthConfig, Option<OidcCommonConfig>)> {
    let mut cfg = AuthConfig::default();

    // 1. Dev-bypass — same precedence as today (highest).
    if env_bool("DEV_AUTH_BYPASS", false) {
        if env_name == "production" {
            return Err(anyhow!("DEV_AUTH_BYPASS with RUST_ENV=production"));
        }
        cfg.dev_bypass = Some(DevBypassConfig {
            token: env::var("DEV_AUTH_TOKEN").unwrap_or_else(|_| "dev-token".into()),
            issuer: env::var("DEV_AUTH_ISSUER").unwrap_or_else(|_| "dev".into()),
            external_id: env::var("DEV_AUTH_USER_ID").unwrap_or_else(|_| "dev-user".into()),
            email: env::var("DEV_AUTH_EMAIL").ok(),
            display_name: env::var("DEV_AUTH_DISPLAY_NAME").ok(),
        });
    }

    // 2. Local-creds — controlled by LOSEIT_AUTH_LOCAL=true (default true).
    if env_bool("LOSEIT_AUTH_LOCAL", true) {
        cfg.local = Some(LocalConfig {});
    }

    // 3. OIDC providers — comma-separated ids in OIDC_PROVIDERS.
    let raw = env::var("OIDC_PROVIDERS").unwrap_or_default();
    for id in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        cfg.oidc.push(load_oidc_provider(id)?);
    }
    // ID uniqueness + shape.
    for p in &cfg.oidc {
        if !id_is_url_safe(&p.id) {
            return Err(anyhow!("OIDC_PROVIDERS id `{}` must match [a-z0-9_-]{{1,32}}", p.id));
        }
    }
    if has_duplicate_ids(&cfg.oidc) {
        return Err(anyhow!("OIDC_PROVIDERS contains duplicates"));
    }

    // 4. At least one method must be active.
    if cfg.dev_bypass.is_none() && cfg.local.is_none() && cfg.oidc.is_empty() {
        return Err(anyhow!(
            "no auth method configured (set LOSEIT_AUTH_LOCAL=true, DEV_AUTH_BYPASS=true, or OIDC_PROVIDERS=…)"
        ));
    }

    // 5. OIDC common — required when OIDC is non-empty.
    let common = if cfg.oidc.is_empty() {
        None
    } else {
        Some(OidcCommonConfig {
            state_secret: load_state_secret()?, // 32+ bytes, base64-or-raw
            fe_origin: env::var("LOSEIT_FE_ORIGIN")
                .context("LOSEIT_FE_ORIGIN required when OIDC_PROVIDERS is non-empty")?,
            http_timeout_secs: env::var("LOSEIT_OIDC_HTTP_TIMEOUT_SECS")
                .ok().and_then(|v| v.parse().ok()).unwrap_or(10),
        })
    };

    Ok((cfg, common))
}

fn load_oidc_provider(id: &str) -> Result<OidcProviderConfig> {
    let key = |suffix: &str| format!("OIDC_{}_{}", id.to_ascii_uppercase(), suffix);
    let issuer = env::var(key("ISSUER"))
        .with_context(|| format!("{} required", key("ISSUER")))?;
    let client_id = env::var(key("CLIENT_ID"))
        .with_context(|| format!("{} required", key("CLIENT_ID")))?;
    let client_secret = env::var(key("CLIENT_SECRET"))
        .with_context(|| format!("{} required", key("CLIENT_SECRET")))?;
    let redirect_uri = env::var(key("REDIRECT_URI"))
        .with_context(|| format!("{} required", key("REDIRECT_URI")))?;

    let jwks_url = env::var(key("JWKS_URL"))
        .unwrap_or_else(|_| format!("{}jwks/", issuer.trim_end_matches('/').to_owned() + "/"));
    let display_name = env::var(key("DISPLAY_NAME"))
        .unwrap_or_else(|_| capitalize(id));
    let icon_url = env::var(key("ICON_URL")).ok();
    let scopes = env::var(key("SCOPES"))
        .ok()
        .map(|raw| raw.split(',').map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()).collect())
        .unwrap_or_else(|| vec!["openid".into(), "profile".into(), "email".into()]);

    Ok(OidcProviderConfig {
        id: id.to_string(),
        display_name, issuer, client_id, client_secret, jwks_url,
        redirect_uri, icon_url, scopes,
    })
}

fn load_state_secret() -> Result<SecretBytes> {
    let raw = env::var("LOSEIT_AUTH_STATE_SECRET")
        .context("LOSEIT_AUTH_STATE_SECRET required when OIDC providers configured")?;
    // Accept either raw bytes (≥32 chars) or base64-encoded bytes.
    let decoded = STANDARD.decode(&raw).unwrap_or_else(|_| raw.as_bytes().to_vec());
    if decoded.len() < 32 {
        bail!("LOSEIT_AUTH_STATE_SECRET must decode to >= 32 bytes");
    }
    Ok(SecretBytes(decoded))
}
```

`SecretBytes(Vec<u8>)` is a newtype that implements `Debug` as
`SecretBytes(<redacted, N bytes>)` so the secret never leaks to a log
line.

`capitalize` is a one-liner that returns `"Authentik"` from `"authentik"`.

### 2.2 Composition root churn

`build_authenticator` returns `(DynAuthenticator, Option<Arc<AuthService>>)`
today (`server.rs:154`). It will now also need to surface the OIDC
provider map — but that's not the authenticator's concern. Instead:

```rust
pub struct AppState {
    // … existing …
    pub authenticator: DynAuthenticator,
    pub auth: Option<Arc<AuthService>>,
    pub oidc: Option<Arc<OidcRegistry>>, // None iff auth.oidc.is_empty()
}

pub struct OidcRegistry {
    pub providers: HashMap<String, Arc<OidcProvider>>,
    pub state_signer: Arc<StateSigner>,
    pub fe_origin: String,
    pub handoffs: Arc<dyn OidcHandoffRepository>,
    pub auth: Arc<AuthService>, // for mint_session_for
}

pub struct OidcProvider {
    pub config: OidcProviderConfig,
    pub jwks: Arc<JwksVerifier>, // a JWKS-only verifier sliced out of JwksAuthenticator
    pub http: reqwest::Client,
}
```

`JwksVerifier` is a refactor of the JWKS *cache + refresh + key
lookup* parts of `JwksAuthenticator` into a standalone type. The OIDC
flow needs JWKS verification with bring-your-own `iss` and `aud`
(both differ per provider; `aud` is the provider's `client_id` here),
so the existing audience-baked-in shape of `JwksAuthenticator::authenticate`
doesn't fit. Two options:

- **Recommended.** Extract `JwksVerifier` as a pure `(jwks_url,
  cache_ttl) → fn verify(token, iss, aud) → Claims` type. The existing
  `JwksAuthenticator` keeps its public API, holding a `JwksVerifier`
  internally and pre-binding `iss` + `aud` from its constructor.
- **Fallback.** Duplicate the JWKS code into `oidc/jwks.rs`. Costs
  ~80 LOC of duplication and the next refresh test we write will need
  to live in both places.

The refactor is straightforward (lift the `JwksCacheState`, `key_for`,
`is_stale`, `refresh_now`, and `is_usable` items as-is; turn
`authenticate` into a thin shim that builds `Validation` and calls
the new `verify`). One commit, one PR. Recommend it.

`build_state` gets the OIDC wiring (see §3 for the composition):

```rust
pub async fn build_state(pool: PgPool, config: &AppConfig) -> Result<AppState> {
    // … existing repos …
    let local_auth: Arc<dyn LocalAuthRepository> = Arc::new(PgLocalAuthRepository::new(pool.clone()));
    let handoffs: Arc<dyn OidcHandoffRepository> = Arc::new(PgOidcHandoffRepository::new(pool.clone()));

    let auth_service = if config.auth.local.is_some() || !config.auth.oidc.is_empty() {
        Some(Arc::new(AuthService::new(users.clone(), local_auth)))
    } else {
        None
    };

    let authenticator = pick_authenticator(&config.auth, &config.env_name, &auth_service).await?;

    let oidc = if config.auth.oidc.is_empty() {
        None
    } else {
        let common = config.oidc_common.as_ref().expect("checked at load");
        let mut providers = HashMap::new();
        for p in &config.auth.oidc {
            let jwks = Arc::new(
                JwksVerifier::new(p.jwks_url.clone(), Duration::from_secs(600)).await?
            );
            let http = reqwest::Client::builder()
                .timeout(Duration::from_secs(common.http_timeout_secs))
                .build()?;
            providers.insert(p.id.clone(), Arc::new(OidcProvider { config: p.clone(), jwks, http }));
        }
        Some(Arc::new(OidcRegistry {
            providers,
            state_signer: Arc::new(StateSigner::new(common.state_secret.clone())),
            fe_origin: common.fe_origin.clone(),
            handoffs,
            auth: auth_service.clone().expect("auth_service set because oidc non-empty"),
        }))
    };

    Ok(AppState::from_ports(/* …, authenticator, auth_service, oidc */))
}
```

`pick_authenticator` is `build_authenticator` renamed + tightened to
the precedence: dev-bypass → local → first-OIDC-issuer-as-JWKS
(unused at the auth-middleware seam — OIDC users authenticate via the
local opaque-token path post-callback). When only OIDC is configured
(no local, no dev), we still wire `LocalAuthenticator` because
`local_auth_tokens` is what authed requests resolve against.

```rust
async fn pick_authenticator(
    auth: &AuthConfig,
    env_name: &str,
    auth_service: &Option<Arc<AuthService>>,
) -> Result<DynAuthenticator> {
    if let Some(dev) = &auth.dev_bypass {
        if env_name == "production" { return Err(anyhow!("dev bypass in prod")); }
        return Ok(Arc::new(DevAuthenticator::new(dev.token.clone(), dev.identity())));
    }
    // Either local-creds or OIDC (or both) → resolve opaque tokens
    // against local_auth_tokens.
    let auth = auth_service.clone().ok_or_else(|| anyhow!("no auth method configured"))?;
    Ok(Arc::new(LocalAuthenticator::new(auth)))
}
```

The `JwksAuthenticator` runtime path is no longer reachable from the
middleware. We keep the type (and its tests) — it's the engine of
`JwksVerifier` via the §2.2 refactor — but no `AuthConfig` variant
constructs the top-level `Authenticator` from it anymore. **This is a
deliberate breaking change to the deploy contract**: a deploy that
sets `LOSEIT_AUTH_BACKEND=jwks` today will refuse to boot under the
new config. Coolify env-var migration (§9) handles it.

---

## 3. `AuthService::mint_session_for` extraction

**Goal.** A `pub async fn mint_session_for(&self, user_id: Uuid)
-> Result<LocalAuthToken, AuthError>` that the OIDC callback handler
calls after `ensure_user`, with the same effect as `login` minus
password verification.

**Read of `service/auth.rs:35-77`.** The bearer-issue block at the
tail of `login` is exactly 13 lines (`let raw_token = …` through `Ok(LocalAuthToken { … })`). Lifting it is mechanical:

```rust
impl AuthService {
    pub async fn mint_session_for(&self, user_id: Uuid)
        -> Result<LocalAuthToken, AuthError>
    {
        let raw_token = mint_raw_token();
        let token_hash = sha256_hex(&raw_token);
        let expires_at = Utc::now() + TOKEN_TTL;

        self.local
            .insert_token(&token_hash, user_id, expires_at)
            .await
            .map_err(|e| AuthError::Upstream(format!("local-auth db: {e}")))?;

        Ok(LocalAuthToken { raw: raw_token, user_id, expires_at })
    }

    pub async fn login(&self, username_raw: &str, password: &str)
        -> Result<LocalAuthToken, AuthError>
    {
        // … existing username parse + cred lookup + verify …
        if !verify_password(password, &cred.password_hash) {
            return Err(AuthError::Invalid);
        }
        self.mint_session_for(cred.user_id).await
    }
}
```

**Verification.** The existing core tests
(`tests/auth_service.rs`'s `login_returns_token_on_correct_creds`,
`verify_token_returns_user_on_active_token`) keep passing — the
refactor is a pure extract-method. One new test added in §11.

**Falling back to duplication is not justified.** The extraction is
~15 LOC of move + one call-site rewrite. Doing duplication for fear of
churn would leave us re-doing it the next time we want a token-mint
path (logout-then-reauth flow, eventual admin impersonation tooling).
Choose the extraction.

---

## 4. ID-token verification — `JwksVerifier`

Lifted out of `JwksAuthenticator` per §2.2.

```rust
// server/crates/loseit-api/src/auth/jwks_verifier.rs

pub struct JwksVerifier {
    jwks_url: String,
    cache_ttl: Duration,
    cache: Arc<RwLock<JwksCacheState>>,
    refresh_lock: Arc<Mutex<()>>,
    http: reqwest::Client,
}

#[derive(Debug, Deserialize)]
pub struct OidcClaims {
    pub iss: String,
    pub sub: String,
    #[serde(default)] pub email: Option<String>,
    #[serde(default)] pub name: Option<String>,
    #[serde(default)] pub preferred_username: Option<String>,
    pub aud: serde_json::Value,
    pub exp: i64,
    #[serde(default)] pub iat: Option<i64>,
    #[serde(default)] pub nbf: Option<i64>,
    #[serde(default)] pub nonce: Option<String>,
}

impl JwksVerifier {
    pub async fn new(jwks_url: String, cache_ttl: Duration) -> anyhow::Result<Self> { /* … */ }

    /// Validate `token` claiming issuer `iss` and audience `aud`.
    /// Returns full claims on success. The OIDC code-flow path passes
    /// the per-provider `client_id` as `aud`.
    pub async fn verify(
        &self,
        token: &str,
        iss: &str,
        aud: &str,
        nonce: Option<&str>,
    ) -> Result<OidcClaims, AuthError> {
        // … same as JwksAuthenticator::authenticate, but iss/aud are
        // parameters and we return the whole claims struct …
        // Also verifies `nonce` matches when `nonce` is Some.
    }
}
```

`JwksAuthenticator` is rewritten to hold `JwksVerifier` and bake its
`iss` + `aud` into a `verify` call.

`OidcClaims.aud` keeps the `serde_json::Value` shape (string or array)
that production providers actually emit. The validation library handles
either; we just need to surface the rest of the claim set.

---

## 5. State cookie — `loseit_oidc_state`

### 5.1 Payload + signature

```rust
// server/crates/loseit-api/src/auth/oidc/state.rs

#[derive(Serialize, Deserialize)]
pub struct StatePayload {
    pub provider_id: String,
    pub state: String,         // CSRF token, 32 random bytes, b64url-no-pad
    pub pkce_verifier: String, // 43-char b64url-no-pad random
    pub nonce: String,         // OIDC nonce — 32 random bytes b64url
    pub next: String,          // FE path or absolute URL (validated, §6)
    pub exp: i64,              // epoch seconds; ttl = 600
}

pub struct StateSigner {
    key: hmac::Hmac<Sha256>,
}

impl StateSigner {
    pub fn new(secret: SecretBytes) -> Self { /* … */ }

    /// Returns `"<b64url(payload_json)>.<b64url(hmac)>"`.
    pub fn sign(&self, payload: &StatePayload) -> String;

    /// Constant-time HMAC verify + JSON parse + `exp > now` check.
    pub fn verify(&self, signed: &str) -> Result<StatePayload, StateError>;
}
```

HMAC is over `b64url(payload_json)` (so verification doesn't need to
re-serialize). Constant-time tag compare via `subtle::ConstantTimeEq`
or `hmac::Mac::verify`.

### 5.2 Cookie attributes

- **Name.** `loseit_oidc_state`.
- **Value.** `sign(payload)` (see §5.1).
- **Attributes.** `HttpOnly; Secure; SameSite=Lax; Max-Age=600;
  Path=/api/v1/auth/oidc`. `Path` scopes the cookie to the OIDC route
  family so it's never sent to `/api/v1/foods/…` etc.
- **In development** (`env_name != "production"`), `Secure` is dropped
  so the local-dev `http://localhost:8080` flow works against an
  Authentik on `http://localhost:9000`. Gated on the same `env_name`
  guard the dev-bypass already uses.
- **`SameSite=Lax`** is correct for an OAuth top-level redirect (the
  IdP issues a 302 to our `/callback`, which is a top-level navigation).
  `SameSite=Strict` would drop the cookie on that callback.
- **Set on `/start`. Deleted on `/callback` (set to empty,
  `Max-Age=0`) regardless of outcome.**

### 5.3 PKCE generation

`pkce_verifier`: 32 random bytes, base64url-no-pad (43 chars after
encoding). `code_challenge` is `b64url(sha256(verifier))`, sent on
`/start` with `code_challenge_method=S256`.

---

## 6. `next_url` validation

Open-redirect is the primary risk vector. The callback always
redirects the browser somewhere — that "somewhere" must be ours.

**Rule.** Accept `next` if and only if one of:

1. `next` starts with `/` (path-only). The callback redirects to
   `fe_origin + next`.
2. `next` is an absolute URL whose `origin` (scheme + host + port)
   equals the configured `LOSEIT_FE_ORIGIN`.

Reject anything else with 400 at `/start`. Default `next` is `/` when
the query param is absent.

```rust
fn resolve_next(fe_origin: &str, next: Option<&str>) -> Result<String, ApiError> {
    let raw = next.unwrap_or("/");
    if raw.starts_with("//") || raw.contains('\\') {
        // `//foo.com/x` is a scheme-relative URL; the browser would
        // jump to host `foo.com`. Refuse.
        return Err(ApiError::bad_request("invalid `next`"));
    }
    if raw.starts_with('/') {
        return Ok(format!("{}{}", fe_origin.trim_end_matches('/'), raw));
    }
    // Absolute URL must match fe_origin exactly.
    let url = url::Url::parse(raw).map_err(|_| ApiError::bad_request("invalid `next`"))?;
    let origin = format!("{}://{}{}",
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
```

Validated **once** at `/start` (its result is what lands in the cookie
payload's `next` field). `/callback` doesn't re-validate — the cookie
HMAC already covers it.

---

## 7. Handoff codes

### 7.1 Storage shape

```sql
-- server/migrations/0009_oidc_handoff_codes.sql
--
-- One-time bearer-token ferry from the OIDC callback (which has the
-- raw opaque bearer) to the FE's POST /auth/oidc/exchange.
--
-- The raw bearer lives in this row for at most 60 seconds. The handoff
-- code itself (the value the browser carries in the redirect URL) is
-- stored as sha256(code) so the row can't replay the bearer if the DB
-- is read out of band.
--
-- Rows are single-use: the exchange handler DELETEs by code_hash and
-- returns the raw bearer in the same RETURNING-clause read. Any second
-- attempt with the same handoff code 404s.

CREATE TABLE IF NOT EXISTS oidc_handoff_codes (
    code_hash   TEXT PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    raw_token   TEXT NOT NULL,
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS oidc_handoff_codes_expires_idx
    ON oidc_handoff_codes(expires_at);
```

**Decision: store raw_token plaintext.** Rejected alternatives:

- *Encrypt `raw_token` with a `LOSEIT_AUTH_STATE_SECRET`-derived key.*
  Encryption-at-rest in a 60-second TTL row is theater — anyone who can
  read the DB can also read `LOSEIT_AUTH_STATE_SECRET` from the same
  pod's env. Cost: AES wiring + tests, all for no real-world threat.
- *In-memory map keyed by handoff hash.* Loses on restart, which a 60s
  TTL almost-but-doesn't-quite paper over (a deploy rolls a container
  mid-flow). The Pg row is exactly-once, restart-safe, and the column
  is just a string.
- *Restructure `local_auth_tokens` to store raw.* Bigger blast radius
  (the local-creds login flow already works, we'd be undoing §2 of
  BE-008's "tokens by hash only" invariant).

Plaintext-for-60s is the cleanest shape. The row is `DELETE … RETURNING
raw_token` so a successful exchange evicts immediately; expired rows
are filtered at lookup (`WHERE expires_at > now()`) and swept later
(no sweeper this ticket; `oidc_handoff_codes_expires_idx` is in place
for one).

### 7.2 Repository port

```rust
// server/crates/loseit-core/src/repo/oidc_handoff.rs

#[async_trait]
pub trait OidcHandoffRepository: Send + Sync + 'static {
    async fn insert(
        &self, code_hash: &str, user_id: Uuid, raw_token: &str,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()>;

    /// Atomic claim: returns the row's `(user_id, raw_token)` and
    /// deletes it in the same statement. Returns `Ok(None)` for
    /// missing/expired codes.
    async fn claim(&self, code_hash: &str) -> CoreResult<Option<HandoffClaim>>;
}

pub struct HandoffClaim {
    pub user_id: Uuid,
    pub raw_token: String,
}
```

Pg impl uses `DELETE … WHERE code_hash = $1 AND expires_at > now()
RETURNING user_id, raw_token`. One round trip, race-free.

In-memory fake mirrors the trait surface for handler-level tests.

### 7.3 Lifecycle

1. `/callback` succeeds → `auth.mint_session_for(user.id)` → raw
   `LocalAuthToken`.
2. Generate `handoff_raw` (32 random bytes, b64url-no-pad).
3. `code_hash = sha256_hex(handoff_raw)`.
4. `handoffs.insert(code_hash, user.id, raw_token, now + 60s)`.
5. 302 → `<fe_origin>/<next>?oidc_code=<handoff_raw>`. (The `next`
   path may already have a query string; in that case use `&` —
   construct via `url::Url`.)
6. FE `POST /auth/oidc/exchange {code: handoff_raw}` →
   `handoffs.claim(sha256_hex(code))` →
   `{token: raw_token, expires_at: <30 days from issue>}`.

The `expires_at` returned on exchange is recomputed from the token
row: the FE will get the same shape as the local-creds login (token +
absolute kill date). Mechanically we re-fetch through
`AuthService::token_expiry(raw_token)` — a new tiny helper that does
the same `sha256_hex` + repo lookup the middleware does, returning
just the `expires_at`. Adding this is one method on
`LocalAuthRepository` (`get_expiry(token_hash) -> Option<DateTime<Utc>>`)
or — simpler — `mint_session_for` already returns the
`LocalAuthToken {raw, expires_at}` so we cache the `expires_at` on the
handoff row.

**Easier shape**: extend the handoff table to also carry `expires_at`
of the *token*:

```sql
ALTER TABLE oidc_handoff_codes ADD COLUMN token_expires_at TIMESTAMPTZ NOT NULL;
```

Easier still: `claim` returns `(user_id, raw_token, token_expires_at)`,
no second lookup. Folded into §7.1.

```sql
CREATE TABLE IF NOT EXISTS oidc_handoff_codes (
    code_hash         TEXT PRIMARY KEY,
    user_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    raw_token         TEXT NOT NULL,
    token_expires_at  TIMESTAMPTZ NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Two `expires_at` columns: `expires_at` is the handoff-code TTL (60s);
`token_expires_at` is the opaque bearer's 30-day kill date that the FE
will surface to users. Both columns are TIMESTAMPTZ-with-UTC by
convention.

---

## 8. Handlers

All four routes live under `server/crates/loseit-api/src/routes/auth.rs`
alongside the existing `/auth/login`.

### 8.1 `GET /api/v1/auth/providers`

Public discovery. Always returns 200 with a list. Empty `oidc` array
when no providers configured.

```rust
#[derive(Serialize)]
struct ProvidersResponse {
    local: LocalProviderDescriptor,
    oidc: Vec<OidcProviderDescriptor>,
}

#[derive(Serialize)]
struct LocalProviderDescriptor { enabled: bool }

#[derive(Serialize)]
struct OidcProviderDescriptor {
    id: String,
    display_name: String,
    icon_url: Option<String>,
    /// Relative URL the FE puts behind the button — a plain anchor
    /// works (the browser will navigate to it with the existing
    /// session, no JS required).
    start_url: String,
}

async fn providers(State(state): State<AppState>) -> Json<ProvidersResponse> {
    let local = LocalProviderDescriptor { enabled: state.auth.is_some() };
    let oidc = state.oidc.as_ref().map(|r| {
        r.providers.values().map(|p| OidcProviderDescriptor {
            id: p.config.id.clone(),
            display_name: p.config.display_name.clone(),
            icon_url: p.config.icon_url.clone(),
            start_url: format!("/api/v1/auth/oidc/{}/start", p.config.id),
        }).collect()
    }).unwrap_or_default();
    Json(ProvidersResponse { local, oidc })
}
```

Note: `local.enabled` is `state.auth.is_some()` — true when `Local`
*or* `Oidc` is configured (both share `AuthService`). The FE uses this
flag to decide whether to render the username/password form. **The
config doesn't track local vs oidc separately at the descriptor level**
— we add a `local_login_enabled: bool` on the descriptor so the FE
only renders the password form when local-creds are on:

```rust
struct LocalProviderDescriptor {
    /// `true` when POST /auth/login is mounted (`config.local.is_some()`).
    enabled: bool,
}
```

`enabled` is `config.local.is_some()` (read off the parsed config,
threaded into `AppState` as a new bool field `local_login_enabled`).

### 8.2 `GET /api/v1/auth/oidc/{id}/start`

```rust
async fn oidc_start(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Query(params): Query<StartParams>,
    cookies: CookieJar,
) -> Result<(CookieJar, Redirect), ApiError> {
    let registry = state.oidc.as_ref().ok_or_else(|| ApiError::not_found())?;
    let provider = registry.providers.get(&provider_id)
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
        exp: (Utc::now() + Duration::seconds(600)).timestamp(),
    };
    let signed = registry.state_signer.sign(&payload);

    let authorize_url = build_authorize_url(
        provider,
        &state_csrf,
        &code_challenge,
        &nonce,
    );

    let cookie = build_state_cookie(signed, /* secure = */ state.env_is_production);
    Ok((cookies.add(cookie), Redirect::to(&authorize_url)))
}

#[derive(Deserialize)]
struct StartParams { next: Option<String> }

fn build_authorize_url(
    p: &OidcProvider,
    state: &str,
    code_challenge: &str,
    nonce: &str,
) -> String {
    let mut url = url::Url::parse(&p.config.issuer)
        .expect("issuer URL validated at boot");
    // Authentik convention: <issuer>/authorize/. Most providers expose
    // a `.well-known/openid-configuration` we could parse — that's a
    // v1.1 enhancement; for now the URL is `<issuer> + "authorize/"`.
    url.path_segments_mut().unwrap().pop_if_empty().push("authorize");
    url.query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", &p.config.client_id)
        .append_pair("redirect_uri", &p.config.redirect_uri)
        .append_pair("scope", &p.config.scopes.join(" "))
        .append_pair("state", state)
        .append_pair("nonce", nonce)
        .append_pair("code_challenge", code_challenge)
        .append_pair("code_challenge_method", "S256");
    url.to_string()
}
```

**Issuer URL assumption.** Authentik's discovery doc lives at
`<issuer>/.well-known/openid-configuration`. We could fetch it once at
boot and cache `authorization_endpoint` / `token_endpoint` /
`jwks_uri`. For v1 we hard-code Authentik's `<issuer>/authorize/` and
`<issuer>/token/` pattern. The user provisions Authentik (Ask 8a) so
this is safe; we flag `LOSEIT_OIDC_DISCOVER=true` as a future
enhancement that fetches `.well-known/...` and overrides these
hard-coded paths. Out of scope for v1.

### 8.3 `GET /api/v1/auth/oidc/{id}/callback`

```rust
async fn oidc_callback(
    State(state): State<AppState>,
    Path(provider_id): Path<String>,
    Query(params): Query<CallbackParams>,
    cookies: CookieJar,
) -> Result<(CookieJar, Redirect), ApiError> {
    let registry = state.oidc.as_ref().ok_or_else(|| ApiError::not_found())?;
    let provider = registry.providers.get(&provider_id)
        .ok_or_else(|| ApiError::not_found())?;

    // 1. Read + verify state cookie.
    let signed = cookies.get("loseit_oidc_state")
        .ok_or_else(|| ApiError::bad_request("missing state cookie"))?;
    let payload = registry.state_signer.verify(signed.value())
        .map_err(|_| ApiError::bad_request("invalid state cookie"))?;

    // 2. Same-provider + CSRF check.
    if payload.provider_id != provider_id {
        return Err(ApiError::bad_request("provider mismatch"));
    }
    if !constant_time_eq(payload.state.as_bytes(), params.state.as_bytes()) {
        return Err(ApiError::bad_request("state mismatch"));
    }

    // 3. Either the IdP told us about an error, or we have a code.
    if let Some(err) = params.error.as_deref() {
        // The user denied consent or the IdP refused. We bubble this
        // back to the FE by 302ing to `next` with an `oidc_error=…` qs
        // — so the FE can show a friendly error.
        let cleared = clear_state_cookie(state.env_is_production);
        let url = next_with_error(&payload.next, err);
        return Ok((cookies.add(cleared), Redirect::to(&url)));
    }
    let code = params.code.ok_or_else(|| ApiError::bad_request("missing code"))?;

    // 4. Exchange code at the IdP's /token endpoint.
    let token_resp = exchange_code(provider, &code, &payload.pkce_verifier).await?;

    // 5. Verify ID token via JWKS, checking iss + aud + nonce.
    let claims = provider.jwks
        .verify(&token_resp.id_token, &provider.config.issuer, &provider.config.client_id, Some(&payload.nonce))
        .await
        .map_err(|_| ApiError::bad_request("invalid id_token"))?;

    // 6. Upsert local user row.
    let identity = UserIdentity {
        issuer: provider_id.clone(), // not the full URL — see §13 open Q
        external_id: claims.sub.clone(),
        email: claims.email.clone(),
        display_name: claims.name.clone().or(claims.preferred_username.clone()),
    };
    let user = state.users.ensure_user(&identity).await?;

    // 7. Mint opaque session token.
    let session = registry.auth.mint_session_for(user.id).await?;

    // 8. Insert handoff row.
    let handoff_raw = b64url_random(32);
    let code_hash = sha256_hex(&handoff_raw);
    registry.handoffs.insert(
        &code_hash, user.id, &session.raw,
        session.expires_at, /* handoff expiry = */ Utc::now() + Duration::seconds(60),
    ).await?;

    // 9. Clear the state cookie + 302 the browser back to the FE.
    let cleared = clear_state_cookie(state.env_is_production);
    let redirect_url = next_with_handoff(&payload.next, &handoff_raw);
    Ok((cookies.add(cleared), Redirect::to(&redirect_url)))
}

#[derive(Deserialize)]
struct CallbackParams {
    code: Option<String>,
    state: String,
    error: Option<String>,
    error_description: Option<String>,
}

async fn exchange_code(
    p: &OidcProvider,
    code: &str,
    pkce_verifier: &str,
) -> Result<TokenResponse, ApiError> {
    let token_url = format!("{}token/", p.config.issuer.trim_end_matches('/'));
    let resp = p.http.post(&token_url)
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", &p.config.redirect_uri),
            ("client_id", &p.config.client_id),
            ("client_secret", &p.config.client_secret),
            ("code_verifier", pkce_verifier),
        ])
        .send().await
        .map_err(|e| ApiError::bad_gateway(format!("idp /token: {e}")))?;
    if !resp.status().is_success() {
        return Err(ApiError::bad_gateway(format!(
            "idp /token returned {}", resp.status()
        )));
    }
    resp.json::<TokenResponse>().await
        .map_err(|e| ApiError::bad_gateway(format!("idp /token body: {e}")))
}

#[derive(Deserialize)]
struct TokenResponse {
    id_token: String,
    // We don't keep access_token or refresh_token. Authentik
    // userinfo_endpoint is unused; ID token's `email` + `name` cover
    // everything the FE wants.
}
```

### 8.4 `POST /api/v1/auth/oidc/exchange`

```rust
#[derive(Deserialize)]
struct ExchangeBody { code: String }

#[derive(Serialize)]
struct ExchangeResponse {
    token: String,
    expires_at: DateTime<Utc>,
}

async fn oidc_exchange(
    State(state): State<AppState>,
    Json(body): Json<ExchangeBody>,
) -> Result<Json<ExchangeResponse>, ApiError> {
    let registry = state.oidc.as_ref().ok_or_else(|| ApiError::not_found())?;
    let code_hash = sha256_hex(&body.code);
    let claim = registry.handoffs.claim(&code_hash).await?
        .ok_or_else(|| ApiError::unauthorized("invalid or expired handoff code"))?;
    Ok(Json(ExchangeResponse {
        token: claim.raw_token,
        expires_at: claim.token_expires_at,
    }))
}
```

`claim` is the `DELETE … RETURNING …` so the call is single-use.

### 8.5 Routing

```rust
// routes/auth.rs
pub fn router() -> Router<AppState> {
    Router::new()
        // mounted iff state.auth.is_some()
        .route("/auth/login", post(login))
        // mounted iff state.oidc.is_some()
        .route("/auth/providers", get(providers))
        .route("/auth/oidc/:id/start", get(oidc_start))
        .route("/auth/oidc/:id/callback", get(oidc_callback))
        .route("/auth/oidc/exchange", post(oidc_exchange))
}
```

`/auth/providers` is always mounted (returns `local.enabled=false,
oidc=[]` when nothing is configured — though the rest of the stack
won't boot without at least one method per §2.1). The composition root
mounts the OIDC routes only when `state.oidc.is_some()`; the
`/auth/providers` route is always there so the FE can render "no
auth configured" gracefully (this is also useful for the
`docker compose up` smoke test).

---

## 9. Migration + compose / env

### 9.1 Migration — `server/migrations/0009_oidc_handoff_codes.sql`

See §7.1's final SQL (with `token_expires_at` column).

### 9.2 `compose.coolify.yaml` diff

Replace the existing `--- Auth ---` block and the four old `OIDC_*`
lines with:

```yaml
      # --- Auth -----------------------------------------------------------
      # Multi-method: any of dev-bypass, local-creds, OIDC can be on. At
      # least one is required. Local + OIDC commonly coexist on prod.
      DEV_AUTH_BYPASS: ${DEV_AUTH_BYPASS:-false}
      DEV_AUTH_TOKEN: ${DEV_AUTH_TOKEN:-dev-token}
      DEV_AUTH_ISSUER: ${DEV_AUTH_ISSUER:-dev}
      DEV_AUTH_USER_ID: ${DEV_AUTH_USER_ID:-dev-user}
      DEV_AUTH_EMAIL: ${DEV_AUTH_EMAIL:-dev@example.com}
      DEV_AUTH_DISPLAY_NAME: ${DEV_AUTH_DISPLAY_NAME:-Dev User}

      LOSEIT_AUTH_LOCAL: ${LOSEIT_AUTH_LOCAL:-true}
      LOSEIT_SEED_DEV_AUTH: ${LOSEIT_SEED_DEV_AUTH:-true}

      # --- OIDC -----------------------------------------------------------
      # Comma-separated provider IDs. Each ID has matching OIDC_<ID>_*
      # env vars. Empty = no OIDC. See server/specs/be_oidc_integration_design.md.
      OIDC_PROVIDERS: ${OIDC_PROVIDERS:-}

      # Shared OIDC infrastructure (required iff OIDC_PROVIDERS is non-empty).
      LOSEIT_AUTH_STATE_SECRET: ${LOSEIT_AUTH_STATE_SECRET:-}
      LOSEIT_FE_ORIGIN: ${LOSEIT_FE_ORIGIN:-}

      # Per-provider — substitute <ID> with each entry in OIDC_PROVIDERS.
      # Example for OIDC_PROVIDERS=authentik:
      OIDC_AUTHENTIK_DISPLAY_NAME: ${OIDC_AUTHENTIK_DISPLAY_NAME:-Authentik}
      OIDC_AUTHENTIK_ISSUER: ${OIDC_AUTHENTIK_ISSUER:-}
      OIDC_AUTHENTIK_CLIENT_ID: ${OIDC_AUTHENTIK_CLIENT_ID:-}
      OIDC_AUTHENTIK_CLIENT_SECRET: ${OIDC_AUTHENTIK_CLIENT_SECRET:-}
      OIDC_AUTHENTIK_REDIRECT_URI: ${OIDC_AUTHENTIK_REDIRECT_URI:-}
      OIDC_AUTHENTIK_JWKS_URL: ${OIDC_AUTHENTIK_JWKS_URL:-}
      OIDC_AUTHENTIK_ICON_URL: ${OIDC_AUTHENTIK_ICON_URL:-}
      OIDC_AUTHENTIK_SCOPES: ${OIDC_AUTHENTIK_SCOPES:-}
```

The four old `OIDC_ISSUER` / `OIDC_AUDIENCE` / `OIDC_JWKS_URL` /
`OIDC_JWKS_CACHE_TTL_SECS` env vars are **removed**. The old
`LOSEIT_AUTH_BACKEND` env var is **removed** — the new struct config
doesn't have a "which backend" toggle; methods are independently
toggled by their own gates. (Setting both `LOSEIT_AUTH_LOCAL=false` and
`OIDC_PROVIDERS=` empty is what disables local-creds.)

`COOLIFY.md` (if it exists in the repo — check at impl time) gets a
parallel update walking the operator through the Authentik UI setup.
Out-of-spec note: if `COOLIFY.md` does not exist, we skip the doc
update — the comment block above is the operator runbook.

### 9.3 Workspace deps

Already in `[workspace.dependencies]`: `reqwest`, `serde_json`,
`sha2`, `base64`, `chrono`, `tokio`, `axum`, `tower-http`, `url`,
`uuid`, `tracing`.

Add:

```toml
hmac = "0.12"
subtle = "2"        # constant-time HMAC compare
axum-extra = { version = "0.10", features = ["cookie"] }   # CookieJar extractor
url = "2"
```

`hmac` and `subtle` are new. `axum-extra` is new (existing routes
don't touch cookies). `url` is new at the workspace level (today
hand-rolled string concatenation handles URL construction).

`loseit-api/Cargo.toml` `[dependencies]`:

```toml
hmac.workspace = true
subtle.workspace = true
axum-extra.workspace = true
url.workspace = true
```

`loseit-core/Cargo.toml`: no new deps (the handoff trait lives in
core but the HMAC/URL bits stay in `loseit-api`).

`loseit-db/Cargo.toml`: no new deps.

`loseit-testing` gains the in-memory handoff fake (~50 LOC).

---

## 10. OpenAPI delta — `server/specs/openapi.yaml`

Four new path blocks and four new schemas.

### 10.1 Paths

Insert after the existing `/auth/login` block (line 117):

```yaml
  /auth/providers:
    get:
      tags: [Auth]
      operationId: list_auth_providers
      summary: Discover configured auth providers
      description: |
        Returns the set of authentication methods this deployment
        accepts. Called by the FE before sign-in; drives whether the
        local credentials form is rendered and the per-provider OIDC
        button list.
      security: []
      responses:
        "200":
          description: Provider catalogue.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/AuthProviders" }

  /auth/oidc/{provider_id}/start:
    get:
      tags: [Auth]
      operationId: oidc_start
      summary: Start an OIDC sign-in flow
      description: |
        Sets an HMAC-signed `loseit_oidc_state` cookie carrying the
        PKCE verifier + CSRF state + return-to URL, then 302s to the
        provider's authorize endpoint with `code_challenge_method=S256`.
        FE renders this as a plain anchor — the browser follows the
        302 to Authentik and the user signs in.
      security: []
      parameters:
        - in: path
          name: provider_id
          required: true
          schema: { type: string }
        - in: query
          name: next
          required: false
          schema: { type: string, default: "/" }
          description: |
            Path or absolute URL to land at after a successful sign-in.
            Validated against `LOSEIT_FE_ORIGIN`. Rejected with 400 if
            it points elsewhere.
      responses:
        "302":
          description: Redirect to the provider's authorize endpoint.
        "400": { $ref: "#/components/responses/BadRequest" }
        "404":
          description: Unknown `provider_id` or OIDC not configured.

  /auth/oidc/{provider_id}/callback:
    get:
      tags: [Auth]
      operationId: oidc_callback
      summary: Provider redirect target after sign-in
      description: |
        Hit by the browser after the IdP redirects back to us. Verifies
        the signed state cookie, exchanges `code` + `pkce_verifier` at
        the provider's `/token` endpoint, validates the returned ID
        token via JWKS, upserts the local user row, mints an opaque
        bearer, stores it under a one-time handoff code, and 302s the
        browser to `<next>?oidc_code=<handoff>`.
      security: []
      parameters:
        - in: path
          name: provider_id
          required: true
          schema: { type: string }
        - in: query
          name: code
          required: false
          schema: { type: string }
        - in: query
          name: state
          required: true
          schema: { type: string }
        - in: query
          name: error
          required: false
          schema: { type: string }
        - in: query
          name: error_description
          required: false
          schema: { type: string }
      responses:
        "302":
          description: Redirect to the FE with a handoff code.
        "400": { $ref: "#/components/responses/BadRequest" }
        "404":
          description: Unknown `provider_id` or OIDC not configured.
        "502":
          description: Upstream IdP failure (`/token` unreachable).

  /auth/oidc/exchange:
    post:
      tags: [Auth]
      operationId: oidc_exchange
      summary: Swap an OIDC handoff code for an opaque bearer
      description: |
        One-time exchange. The handoff code is the value the callback
        302'd to the FE in the URL. The opaque bearer returned here is
        the same shape as the local-creds `/auth/login` response — the
        FE stores it and uses it on every subsequent authenticated
        request.
      security: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/OidcExchangeRequest" }
      responses:
        "200":
          description: Bearer issued.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/LoginResponse" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "400": { $ref: "#/components/responses/BadRequest" }
```

### 10.2 Schemas

Insert after `LoginResponse` (line 927):

```yaml
    AuthProviders:
      type: object
      required: [local, oidc]
      properties:
        local: { $ref: "#/components/schemas/LocalProviderDescriptor" }
        oidc:
          type: array
          items: { $ref: "#/components/schemas/OidcProviderDescriptor" }

    LocalProviderDescriptor:
      type: object
      required: [enabled]
      properties:
        enabled:
          type: boolean
          description: |
            `true` when `POST /auth/login` is accepted on this deploy.

    OidcProviderDescriptor:
      type: object
      required: [id, display_name, start_url]
      properties:
        id:
          type: string
          description: URL-safe slug; appears in `start_url`.
        display_name: { type: string }
        icon_url:
          type: [string, "null"]
          format: uri
        start_url:
          type: string
          description: |
            Relative URL the FE puts behind the per-provider button.
            Hitting it begins the redirect chain; no JS required.

    OidcExchangeRequest:
      type: object
      required: [code]
      properties:
        code:
          type: string
          description: |
            One-time handoff code from the `oidc_code` query parameter
            on the FE callback URL.
```

`LoginResponse` is reused for the exchange — it's the same wire shape
(`{token, expires_at}`).

---

## 11. Test plan per layer

Four layers, increasing scope.

### 11.1 Core service tests — `loseit-core/tests/auth_service.rs`

Extend the existing file (BE-008's tests):

- `mint_session_for_returns_opaque_token` — calls
  `mint_session_for(uuid)`; asserts `raw` is a 43-char b64url string,
  `expires_at == now + 30d`, and the row landed via
  `find_via_touch_token`.
- `mint_session_for_then_verify_round_trips` — mint, then
  `verify_token` returns the user.
- `login_still_works_after_extraction` — sanity check the refactor
  didn't break the existing happy-path.

### 11.2 In-memory + Pg repository tests

`loseit-testing/tests/in_memory_oidc_handoff.rs`:

- `insert_then_claim_returns_token`
- `claim_deletes_row` — second `claim` returns `None`
- `claim_filters_expired` — insert with `expires_at = past`, claim
  returns `None`
- `claim_for_missing_code_returns_none`

No Pg integration tests (same gap as BE-008, `v1_finishup_design.md:13`).
The `DELETE … RETURNING` SQL is exercised by the HTTP-level callback
test against the in-memory fake.

### 11.3 State signer unit tests — `loseit-api/src/auth/oidc/state.rs#mod tests`

- `sign_then_verify_round_trips`
- `verify_rejects_truncated_signature` — flip a byte in the HMAC
- `verify_rejects_truncated_payload` — flip a byte in the b64url
  payload
- `verify_rejects_expired` — set `payload.exp = now - 1s`
- `sign_is_url_safe` — no `+/=` in the output

### 11.4 HTTP-level tests — `loseit-api/tests/http_oidc.rs`

The richest layer. Uses an in-memory `OidcHandoffRepository`, an
in-memory `UserRepository`, an in-memory `LocalAuthRepository`, and a
**`wiremock::MockServer` standing in for Authentik**. The mock serves
three endpoints:

- `GET /jwks/` — our test-generated RSA public key
- `POST /token/` — accepts our `code` + `pkce_verifier`, returns a
  signed ID token
- `GET /authorize/` — never hit (we 302 here but the test client doesn't
  follow), but we assert the redirect URL's shape

Test cases:

1. `providers_lists_local_when_local_only` — config has local on,
   OIDC off; response has `local.enabled=true, oidc=[]`.
2. `providers_lists_oidc_when_configured` — config has local on +
   authentik OIDC; response includes a descriptor for authentik.
3. `start_returns_302_to_authorize_with_pkce` — assert the redirect's
   URL contains `code_challenge=...`, `code_challenge_method=S256`,
   `state=…`, `nonce=…`, `client_id=…`, `redirect_uri=…`.
4. `start_sets_state_cookie` — `loseit_oidc_state` cookie present with
   `HttpOnly`, `SameSite=Lax`, `Max-Age=600`, `Path=/api/v1/auth/oidc`.
5. `start_rejects_bad_next` — `?next=https://evil.example/` returns
   400.
6. `start_accepts_path_next` — `?next=/foods` → cookie payload has
   `next=https://fe.example/foods`.
7. `start_404_for_unknown_provider`.
8. `callback_happy_path` — sign a synthetic state cookie carrying
   `state=S, pkce_verifier=V`, hit callback with `?code=C&state=S`,
   mock the IdP `/token` to return a valid ID token signed by the JWKS
   mock; assert the response is 302 to `<fe_origin>/?oidc_code=<…>` +
   the handoff row exists.
9. `callback_state_cookie_tampered_rejected_400` — flip a byte in the
   cookie HMAC.
10. `callback_state_query_mismatch_rejected_400` — `?state=` doesn't
    match `payload.state`.
11. `callback_expired_state_rejected_400`.
12. `callback_idp_token_failure_returns_502`.
13. `callback_id_token_invalid_sig_rejected_400`.
14. `callback_nonce_mismatch_rejected_400`.
15. `callback_propagates_idp_error_query` — `?error=access_denied`
    redirects to `<fe>?oidc_error=access_denied` and the handoff row
    is NOT created.
16. `exchange_returns_token_then_404_on_replay`.
17. `exchange_404_on_unknown_code`.
18. `exchange_404_on_expired_handoff` — insert with `expires_at = past`.
19. `callback_then_exchange_then_get_me` — full E2E: the bearer
    returned by exchange authenticates `GET /me` and the user row
    has `issuer="authentik"`, `external_id=<sub>` from the ID token.

All HTTP tests use `tower::ServiceExt::oneshot` like
`tests/http_profile.rs`. The cookie surface is `axum_extra::CookieJar`
in-and-out.

---

## 12. Sequenced task list

Engineer-sized. 14 tasks. Each touches 1–4 files and stays under ~300
LOC. Dependencies mean "must merge before the next can compile."

1. **Workspace deps.** Add `hmac`, `subtle`, `axum-extra`, `url` to
   `[workspace.dependencies]`; wire into `loseit-api/Cargo.toml`.
   `cargo check --workspace` must pass. (~5 LOC.) No dependents.

2. **Migration.** Add `server/migrations/0009_oidc_handoff_codes.sql`
   per §7.1's final SQL. (1 file, ~25 LOC.) No dependents.

3. **`OidcHandoffRepository` trait + in-memory fake.** Add
   `loseit-core/src/repo/oidc_handoff.rs`; re-export from
   `repo/mod.rs`. Add `loseit-testing/src/oidc_handoff.rs` with an
   in-memory impl. (3 files, ~140 LOC.) Depends on #1.

4. **Pg handoff repo.** Add `loseit-db/src/oidc_handoff_repo.rs`;
   export from `lib.rs`. (2 files, ~100 LOC.) Depends on #2, #3.

5. **`AuthService::mint_session_for` extraction.** Edit
   `loseit-core/src/service/auth.rs` per §3; one new test in
   `loseit-core/tests/auth_service.rs`. (2 files, ~50 LOC net.)
   Depends on nothing — does not block any later task except #11.

6. **`JwksVerifier` extraction.** Lift the cache + refresh + key
   lookup parts of `JwksAuthenticator` into
   `loseit-api/src/auth/jwks_verifier.rs`; rewrite `JwksAuthenticator`
   to use it. Existing jwks tests pass unchanged. (3 files, ~250 LOC
   net — most is moving code.) Depends on nothing.

7. **`AuthConfig` struct refactor.** Rewrite
   `loseit-api/src/config.rs` per §2.1; introduce
   `OidcCommonConfig` + `OidcProviderConfig` + `SecretBytes` + the new
   `load_auth` shape. Update `AppConfig` with `oidc_common`. (1 file,
   ~250 LOC; lots of new code, no callers change yet.) Depends on
   nothing.

8. **Composition root + `AppState`.** Edit `server.rs` per §2.2:
   `AppState.oidc: Option<Arc<OidcRegistry>>`, `pick_authenticator`,
   `build_state` wires `OidcProvider`s + state signer. Update every
   `AppState::from_ports` call site in tests to pass `None`. (≥8 files,
   ~120 LOC.) Depends on #4, #6, #7. (Note: at this point we've removed
   `LOSEIT_AUTH_BACKEND`; the test envs that set it need cleanup.)

9. **State cookie module.** Add `loseit-api/src/auth/oidc/state.rs`
   (or `loseit-api/src/auth/state.rs`) with `StateSigner`,
   `StatePayload`, the HMAC sign/verify functions, and the in-file
   `#[cfg(test)] mod tests` per §11.3. (1 file, ~200 LOC.) Depends
   on #1.

10. **`/auth/providers` handler.** Add the descriptor types + handler
    to `routes/auth.rs`. Mount it in `routes::auth::router()`. (2
    files, ~60 LOC.) Depends on #8.

11. **`/start` + `/callback` handlers.** Add to `routes/auth.rs`. The
    `exchange_code` and `next_with_handoff` helpers go in a new
    `routes/auth/oidc.rs` submodule. (3 files, ~350 LOC — this is the
    chonky task; split into 11a and 11b if a single engineer wants
    smaller bites.) Depends on #5, #6, #8, #9.

12. **`/exchange` handler.** Add to `routes/auth.rs`. (1 file, ~30
    LOC.) Depends on #4, #8.

13. **HTTP tests.** Add `tests/http_oidc.rs` per §11.4. Wire a
    `wiremock::MockServer` for the IdP; reuse the
    `loseit-api/src/auth/jwks.rs#tests` RSA-key helpers. Run `cargo
    test -p loseit-api --test http_oidc`. (1 file, ~700 LOC — this is
    by far the largest LOC count of the ticket.) Depends on #10–#12.

14. **OpenAPI + compose + lockfile.** Apply the OpenAPI delta in §10;
    apply the `compose.coolify.yaml` edits in §9.2; commit the
    `Cargo.lock` churn. (3 files, ~150 LOC.) Depends on #12.

**Final verification:**

```bash
export PATH="$HOME/.cargo/bin:$PATH"
cargo check --manifest-path /workplace/fulfilled/server/Cargo.toml --workspace
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-core --test auth_service
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-testing
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-api --test http_oidc
```

FE acceptance gate (post-deploy, the user has provisioned Authentik):

```bash
# Provider catalogue
curl -sS https://api.coolify.stolworthy.co/api/v1/auth/providers | jq
# → { local: {enabled: true}, oidc: [{id: "authentik", display_name: "Authentik", icon_url: null, start_url: "/api/v1/auth/oidc/authentik/start"}] }

# Manual / browser flow:
open "https://api.coolify.stolworthy.co/api/v1/auth/oidc/authentik/start?next=/today"
# → bounces through Authentik → lands at https://app.coolify.stolworthy.co/today?oidc_code=…
# → FE swaps via /auth/oidc/exchange → bearer in localStorage → /today loads
```

---

## 13. Risks / open questions

- **`UserIdentity.issuer` shape — provider slug vs full URL.** The
  existing `JwksAuthenticator` writes `iss` (the full URL) into
  `UserIdentity.issuer`. The OIDC callback in §8.3 writes the
  provider's slug (`"authentik"`) instead, so the `users.issuer` column
  carries the same value across every Authentik user regardless of
  which Authentik tenant they signed into. **Recommended**: keep the
  slug. The slug is stable across IdP URL rotations (Authentik moves
  hosts) and matches the column for OIDC-callback-minted users
  consistently. The `jwks` runtime path is no longer reachable from
  middleware (§2.2), so the historical "iss=URL" convention only lives
  on for rows minted under the old wiring. **Flag for review.**

- **Open-redirect.** The `next` validation in §6 is the primary
  defence. Both `path-only` and `same-origin-as-fe_origin` are
  permissive enough for the FE's needs (it might want to land on a
  deep link like `/foods/abc`). Scheme-relative URLs (`//evil.com/x`)
  are explicitly rejected; `\` is rejected to defeat WHATWG-URL
  quirks where `\` is treated as `/` in some implementations.

- **Refresh-token rotation deferred.** The OIDC callback throws away
  the IdP's refresh token. Our 30-day opaque bearer expires
  independently; when it does the user re-runs the OIDC flow and gets
  a new IdP login (assuming the IdP still has a session). Symptom: a
  user who's been signed into Authentik via SSO and signed into our
  app simultaneously will see two re-prompts at day-30 — one in the
  app (mandatory) and possibly one at Authentik (depends on its
  session lifetime). Acceptable for closed-beta.

- **Multi-IdP-per-user.** A user who signs into Authentik on Monday
  and `/auth/login`s with username `alice` on Tuesday gets *two*
  `users` rows: `(issuer='authentik', external_id=<sub>)` and
  `(issuer='dev'/'local', external_id=<uuid>)`. There's no account-
  linking flow. The user can hold two `/me`s with separate weights /
  goals / logs. **Open question**: do we want a deferred "link these
  two identities" admin tool? Probably yes, but not in v1. Flag.

- **Multi-provider race conditions.** The state cookie is scoped to
  `Path=/api/v1/auth/oidc`, not per provider. If a user opens two
  tabs and starts sign-in flows against two different providers
  near-simultaneously, the second `/start`'s `Set-Cookie` overwrites
  the first. Whichever tab's callback fires second sees a
  `provider_id mismatch` in the cookie payload and 400s. Worst-case
  UX: one of the two tabs shows an error and the user retries.
  Acceptable; documented.

- **`JwksAuthenticator` deprecation breakage.** Removing
  `LOSEIT_AUTH_BACKEND=jwks` as a config knob breaks a Coolify deploy
  that was using JWKS-as-the-only-auth-method. Today's deploy is on
  local-creds (BE-008 shipped); no `jwks`-mode deployment is in the
  wild. Safe to remove.

- **Boot-time IdP unreachability.** `JwksVerifier::new` warms its
  cache via an initial HTTP fetch (carry-over from
  `JwksAuthenticator`). If Authentik is down at deploy time, the
  backend boot fails. **Recommended**: keep the strict-warm behaviour
  for v1 — better to refuse to boot than to 503 every callback. A
  future "lazy-warm" mode (try once, log on failure, refetch on first
  request) is a half-day fix if it becomes a problem.

- **Cookie `Path` and the FE callback.** The state cookie scopes to
  `/api/v1/auth/oidc`. The IdP redirect lands at
  `/api/v1/auth/oidc/<id>/callback` — within scope. The FE never
  needs to read this cookie, and on the exchange POST the FE doesn't
  need the cookie either (it carries the handoff code in the JSON
  body). Good.

- **What if Authentik signs ID tokens with `RS256` but `kid` rotates
  mid-session?** `JwksVerifier` refreshes on unknown `kid` (carry-over
  from `JwksAuthenticator` test
  `refreshes_on_unknown_kid_then_accepts`). Each callback is a fresh
  verify, so a rotation between two sign-ins is handled. Good.

- **Open question for the user: what does "log out" look like for an
  OIDC user?** Today the FE just drops the bearer locally. The IdP's
  Authentik session continues. The next time the user hits "Sign in
  with Authentik" they get the SSO experience (no password prompt).
  Is that the intended UX, or should the FE redirect through
  Authentik's `/end_session` on logout? **Single most important open
  question** — affects whether we need a `GET /auth/oidc/{id}/end_session`
  passthrough in v1.
