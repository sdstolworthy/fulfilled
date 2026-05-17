# BE-008 — `POST /api/v1/auth/login` — Architect Design

Local-credentials login. Lands `POST /api/v1/auth/login` against a new
`users_local_auth` table, mints opaque server-issued bearer tokens against
a new `local_auth_tokens` table, and adds a third `Authenticator` impl
that resolves those tokens back to local identities. The TPM should be
able to slice this into ordered, single-engineer tasks without coming
back for clarifications.

---

## 1. Overview

The FE has picked **option (b) local-creds** (`backend_tasks.md`
Asks 1+2). The deploy stops sideloading the static `dev-token` and
starts round-tripping a real bearer minted by `POST /api/v1/auth/login`.
Wire shape is fixed (`backend_tasks.md:119-167`): request
`{username, password}`, response 200 `{token, expires_at?}`, 401 on
bad creds, argon2id with `Argon2::default()` (`m=19456, t=2, p=1`).
Route under `security: []`. JWKS code path
(`server/crates/loseit-api/src/auth/jwks.rs`) is untouched so the v1.1
OIDC swap survives.

**Token shape — opaque DB tokens.** Closed-beta scale + a single small
Postgres makes the per-request `SELECT` free; the gain we want is
**revocability**. JWT is stateless but a leaked token can't be killed
without rotating the HMAC secret. An opaque token in `local_auth_tokens`
is killed with `DELETE WHERE token_hash = $1`. 30-day sliding-window
TTL. The `Authenticator` trait
(`server/crates/loseit-core/src/auth.rs:27-30`) is the seam that lets
us swap to JWT later without touching handlers.

**Schema — separate `users_local_auth` + `local_auth_tokens` tables,
not column adds on `users`.** OIDC users don't have a username +
password row; keeping local-auth fields out of `users` means the OIDC
join is a pure row with no implication that "this user also has a
local password." Both new tables `ON DELETE CASCADE` from `users(id)`
so `DELETE /me` (`routes/profile.rs:124`) needs no further cleanup.

**Authenticator integration — explicit `AuthConfig::Local` variant,
keyed off `LOSEIT_AUTH_BACKEND=local|jwks`.** Honours the Ask 1
constraint that the JWKS code path stays intact. `DEV_AUTH_BYPASS=true`
still wins (CI / local-dev escape hatch); otherwise
`LOSEIT_AUTH_BACKEND` is read with default `local`. Two existing
`Authenticator` impls unchanged.

**Seed — runtime, not SQL.** The dev user's UUID is non-deterministic
— minted by `ensure_user` (`service/user.rs:24-29`) against
`gen_random_uuid()` (`migrations/0001_initial.sql:22`). Embedding Rust
in sqlx migrations is a code-smell we don't have elsewhere. Instead, a
one-shot startup seed in `main.rs` gated on
`LOSEIT_AUTH_BACKEND=local` + `LOSEIT_SEED_DEV_AUTH=true`: call
`ensure_user(dev_identity)` (already idempotent), then upsert the
credential row. CI / local-dev sets the flag; prod sets it on first
deploy and then unsets it.

**Out of scope** (explicit, per FE asks):

- Password reset / recovery flow. FE has not asked for it; we keep the
  closed-beta scope.
- Account lockout / rate limiting on `/auth/login`. We will add an
  unsharded sleep on miss for timing parity (§3.5) but no per-IP
  bucketing — the deploy already sits behind Coolify's reverse proxy
  which absorbs abusive bursts.
- Signup endpoint. The FE has not asked for `POST /auth/register`. The
  dev user is seeded at server start; future users get provisioned via
  OIDC (v1.1) or out-of-band.
- Password change endpoint. Closed-beta scope; the dev user's password
  is `dev` by fiat.

---

## 2. Schema migration — `server/migrations/0007_local_auth.sql`

Single migration. Idempotent so a re-run on an already-migrated
database is a no-op. CHECKs are named so a future migration can
`DROP CONSTRAINT` them by name — the same precedent
`0006_user_units.sql:15-21` set.

```sql
-- Local-credentials authentication tables. Lives alongside `users`
-- rather than augmenting it so that OIDC users (future) don't carry
-- nullable username/password_hash columns. Both tables hang off
-- users(id) with ON DELETE CASCADE so DELETE /me cleans them up.
--
-- Tokens are stored as a SHA-256 hash of the random 32-byte opaque
-- bearer, *never* the raw token. Compromised DB still can't replay
-- bearers — the hash is one-way. The bearer is 256 bits of entropy
-- (43 base64url chars after stripping padding); brute-force is not a
-- threat at any reasonable wall-clock horizon.

CREATE TABLE IF NOT EXISTS users_local_auth (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    username        TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE users_local_auth
    DROP CONSTRAINT IF EXISTS users_local_auth_username_lower_check;
ALTER TABLE users_local_auth
    ADD CONSTRAINT users_local_auth_username_lower_check
        CHECK (username = lower(username));

CREATE UNIQUE INDEX IF NOT EXISTS users_local_auth_username_unique
    ON users_local_auth(username);

CREATE TRIGGER users_local_auth_set_updated_at
    BEFORE UPDATE ON users_local_auth
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Opaque bearer tokens. token_hash is `sha256(raw_token)` hex-encoded;
-- raw_token is never persisted. expires_at is the absolute kill date;
-- the sliding-window refresh on each authed request is implemented as
-- an UPDATE … SET expires_at = greatest(expires_at, now() + interval
-- '30 days') in the lookup path.

CREATE TABLE IF NOT EXISTS local_auth_tokens (
    token_hash      TEXT PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS local_auth_tokens_user_idx
    ON local_auth_tokens(user_id);
CREATE INDEX IF NOT EXISTS local_auth_tokens_expires_idx
    ON local_auth_tokens(expires_at);
```

Notes:

- No raw `token TEXT` column. A DB read can't replay sessions. SHA-256
  is fine here — 256 bits of bearer entropy makes a slow KDF
  unnecessary. argon2 is reserved for password verification where the
  entropy floor is "user-chosen short string."
- No partial unique index on `username`. Every row carries one (`NOT
  NULL`); OIDC users simply don't get a row.
- `users_local_auth_username_unique` is a standalone `CREATE UNIQUE
  INDEX` so a future migration can `DROP INDEX IF EXISTS` cleanly if
  we ever case-fold differently.
- `local_auth_tokens_expires_idx` is in place for an eventual sweeper
  (`DELETE FROM local_auth_tokens WHERE expires_at < now()`). Not
  shipped in this ticket.
- All `CREATE TABLE` / `CREATE INDEX` guarded by `IF NOT EXISTS`; the
  named CHECK is dropped + re-added so a re-run is a no-op.

---

## 3. Domain / service / repo changes

### 3.1 New domain types — `server/crates/loseit-core/src/domain/auth.rs`

A new module (sibling to `domain/user.rs`) holding the local-auth
domain types. Re-exported from `domain/mod.rs`.

```rust
/// Always lower-cased; constructor enforces this. Empty / >64-char
/// input is rejected by returning `None`. Malformed-username failures
/// land as 401 (not 400) at the API layer so "user does not exist" and
/// "user exists but wrong password" are wire-indistinguishable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Username(String);

impl Username {
    pub fn parse(raw: &str) -> Option<Self> {
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.len() > 64 { return None; }
        Some(Self(trimmed.to_ascii_lowercase()))
    }
    pub fn as_str(&self) -> &str { &self.0 }
}

/// Newly-minted token. `raw` is only seen at issue time; persistence
/// is by sha256(raw).
#[derive(Debug, Clone)]
pub struct LocalAuthToken {
    pub raw: String,
    pub user_id: Uuid,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct LocalAuthCredential {
    pub user_id: Uuid,
    pub username: Username,
    pub password_hash: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}
```

### 3.2 New repository port — `server/crates/loseit-core/src/repo/local_auth.rs`

New trait, sibling to `repo/user.rs`. Re-exported from `repo/mod.rs`.

```rust
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::domain::{LocalAuthCredential, Username};
use crate::CoreResult;

#[async_trait]
pub trait LocalAuthRepository: Send + Sync + 'static {
    /// Fetch the credential row for a username, if any. Returns
    /// `Ok(None)` for unknown usernames — caller must still perform
    /// a constant-time argon2 verify against a dummy hash to avoid
    /// user-enumeration via timing.
    async fn find_by_username(
        &self,
        username: &Username,
    ) -> CoreResult<Option<LocalAuthCredential>>;

    /// Upsert a credential row. Used by the runtime seed and any
    /// future password-change flow. `(user_id, username,
    /// password_hash)` overwrite each other.
    async fn upsert_credential(
        &self,
        user_id: Uuid,
        username: &Username,
        password_hash: &str,
    ) -> CoreResult<LocalAuthCredential>;

    /// Persist an opaque token. `token_hash` is sha256(raw) hex-
    /// encoded; the raw token is never sent to the repo.
    async fn insert_token(
        &self,
        token_hash: &str,
        user_id: Uuid,
        expires_at: DateTime<Utc>,
    ) -> CoreResult<()>;

    /// Resolve a token hash to a user id, refreshing `expires_at`
    /// under the sliding-window policy. Returns `Ok(None)` if the
    /// token does not exist or is expired.
    async fn touch_token(
        &self,
        token_hash: &str,
        new_expires_at: DateTime<Utc>,
    ) -> CoreResult<Option<Uuid>>;

    /// Drop a single token. Used by an eventual `POST /auth/logout`;
    /// not wired by this ticket but the trait method ships now so the
    /// route is a pure handler-side addition.
    async fn delete_token(&self, token_hash: &str) -> CoreResult<()>;
}
```

### 3.3 New service — `server/crates/loseit-core/src/service/auth.rs`

Owns the login / verify-token rules. Argon2 work happens here, not in
the repo, so the repo stays a pure data port. Re-exported from
`service/mod.rs`. The `argon2` crate's `Argon2::default()` is the exact
`m=19456, t=2, p=1` configuration the FE pinned
(`backend_tasks.md:143-145`).

```rust
pub const TOKEN_TTL: Duration = Duration::days(30);

pub struct AuthService {
    users: Arc<dyn UserRepository>,
    local: Arc<dyn LocalAuthRepository>,
    /// argon2id hash of "unused", pre-computed at construction so the
    /// "username unknown" branch runs the same verify cost as the
    /// "wrong password" branch. Constant-time-equivalent timing.
    dummy_hash: String,
}

impl AuthService {
    pub fn new(users: Arc<dyn UserRepository>, local: Arc<dyn LocalAuthRepository>) -> Self;

    /// Wire-indistinguishable failure paths: unknown username, wrong
    /// password, malformed username all return `AuthError::Invalid`.
    /// On unknown username, verify runs against `dummy_hash` so timing
    /// leaks nothing.
    pub async fn login(&self, username_raw: &str, password: &str)
        -> Result<LocalAuthToken, AuthError>;

    /// Resolve a raw bearer to a `User`, refreshing the sliding
    /// window. Called by `LocalAuthenticator` on every authed request.
    pub async fn verify_token(&self, raw: &str) -> Result<User, AuthError>;

    /// Idempotent helper used by the runtime seed. Hashes `password`
    /// with argon2id and upserts the credential row.
    pub async fn seed_credential(
        &self, user_id: Uuid, username_raw: &str, password: &str,
    ) -> CoreResult<()>;
}
```

Implementation notes (free functions in the same module):

- `hash_password(plain) -> Result<String, _>` — `Argon2::default()
  .hash_password(plain.as_bytes(), &SaltString::generate(&mut OsRng))`,
  serialised via `to_string()` for storage.
- `verify_password(plain, encoded) -> bool` — `PasswordHash::new(encoded)`
  then `Argon2::default().verify_password(...)`. Returns `false` on
  any error including a malformed encoded string.
- `mint_raw_token() -> String` — 32 bytes from `OsRng`, base64url-
  encoded without padding (43 chars, 256 bits of entropy).
- `sha256_hex(input) -> String` — `Sha256::digest`, lower-hex
  encoded. The token hash that lands in the DB.
- `TOKEN_TTL` is applied on both issue (`login`) and renew
  (`verify_token`) by computing `Utc::now() + TOKEN_TTL` and passing
  to the repo. The Pg `UPDATE` uses `greatest(expires_at, $new)` so
  clock skew never shortens an active session (§3.4).

`argon2` and `rand` are added to `loseit-core`'s `Cargo.toml`. `sha2`
(`server/Cargo.toml:47`) and `base64` (`Cargo.toml:48`) are already
in workspace deps.

### 3.4 Pg repository — `server/crates/loseit-db/src/local_auth_repo.rs`

Sibling to `user_repo.rs`. Same shape: `PgLocalAuthRepository { pool:
PgPool }`, a `#[derive(sqlx::FromRow)] struct CredRow { ... }`, an
`impl From<CredRow> for LocalAuthCredential`, and the four
`UserRepository`-style trait method bodies. `map_sqlx` reused for
error translation. Export from `loseit-db/src/lib.rs`. Key SQL:

```rust
const SELECT_CRED_COLUMNS: &str =
    "user_id, username, password_hash, created_at, updated_at";

// find_by_username
"SELECT {SELECT_CRED_COLUMNS} FROM users_local_auth WHERE username = $1"

// upsert_credential
"INSERT INTO users_local_auth (user_id, username, password_hash) \
 VALUES ($1, $2, $3) \
 ON CONFLICT (user_id) DO UPDATE SET \
    username = EXCLUDED.username, \
    password_hash = EXCLUDED.password_hash, \
    updated_at = now() \
 RETURNING {SELECT_CRED_COLUMNS}"

// insert_token
"INSERT INTO local_auth_tokens (token_hash, user_id, expires_at) \
 VALUES ($1, $2, $3)"

// touch_token — atomic check-and-refresh; greatest() prevents a clock
// skew from shortening an active session. Returns NULL on miss or
// expiry.
"UPDATE local_auth_tokens \
 SET last_seen_at = now(), \
     expires_at = greatest(expires_at, $2) \
 WHERE token_hash = $1 AND expires_at > now() \
 RETURNING user_id"

// delete_token
"DELETE FROM local_auth_tokens WHERE token_hash = $1"
```

### 3.5 In-memory fake — `server/crates/loseit-testing/src/local_auth.rs`

A new `InMemoryLocalAuthRepository` (`Mutex<HashMap<...>>` shape,
mirroring `users.rs`). Re-exported from `loseit-testing`'s `lib.rs`.
Same trait surface; the `touch_token` impl drops rows whose
`expires_at < now()` before returning so the expired-token test path
matches Pg semantics.

---

## 4. Authenticator changes

### 4.1 New `LocalAuthenticator` — `server/crates/loseit-api/src/auth/local.rs`

Third sibling to `dev.rs` / `jwks.rs`. Thin — the heavy lifting lives
in `AuthService::verify_token`, this just adapts the trait shape and
returns a `UserIdentity` for the existing middleware.

```rust
use std::sync::Arc;

use async_trait::async_trait;
use loseit_core::auth::{AuthError, Authenticator};
use loseit_core::domain::UserIdentity;
use loseit_core::service::AuthService;

pub struct LocalAuthenticator {
    auth: Arc<AuthService>,
}

impl LocalAuthenticator {
    pub fn new(auth: Arc<AuthService>) -> Self {
        Self { auth }
    }
}

#[async_trait]
impl Authenticator for LocalAuthenticator {
    async fn authenticate(&self, token: &str) -> Result<UserIdentity, AuthError> {
        let user = self.auth.verify_token(token).await?;
        Ok(user.identity)
    }
}
```

Note: the middleware will then call `ensure_user` on the returned
identity (`auth/mod.rs:44`). For a local-auth-issued token this is a
no-op — the user row already exists by construction (you can't mint a
token for a `user_id` that isn't in `users`). The double lookup is
cheap and keeps the middleware's shape unchanged.

### 4.2 `AuthConfig::Local` variant — `server/crates/loseit-api/src/config.rs`

Third variant on the enum (`config.rs:16-36`). No fields required —
the local-auth backend's wiring comes from the Pg pool that's already
in scope at composition time; no env vars beyond `LOSEIT_AUTH_BACKEND`
itself.

```rust
pub enum AuthConfig {
    DevBypass { … },
    Jwks      { … },
    /// Local credentials backed by `users_local_auth` + `local_auth_tokens`.
    /// Issued at `POST /api/v1/auth/login`, verified by [`LocalAuthenticator`].
    Local,
}
```

`load_auth` (`config.rs:62-94`) gains a new branch:

```rust
fn load_auth(env_name: &str) -> Result<AuthConfig> {
    if env_bool("DEV_AUTH_BYPASS", false) {
        // … existing DevBypass branch, unchanged …
    }

    let backend = env::var("LOSEIT_AUTH_BACKEND")
        .unwrap_or_else(|_| "local".to_string());
    match backend.as_str() {
        "local" => Ok(AuthConfig::Local),
        "jwks" => {
            // … existing JWKS branch, lifted out of the top-level if/else …
        }
        other => Err(anyhow!(
            "LOSEIT_AUTH_BACKEND must be one of local|jwks (got {other})"
        )),
    }
}
```

Default is `local` (new deploys). Existing CI / local-dev paths set
`DEV_AUTH_BYPASS=true` and skip this branch entirely. Anyone explicitly
wiring OIDC sets `LOSEIT_AUTH_BACKEND=jwks` plus the four `OIDC_*` env
vars the JWKS branch already consumes.

### 4.3 Composition root — `server/crates/loseit-api/src/server.rs`

The shape of `AppState` grows by one optional field: `auth_service:
Option<Arc<AuthService>>`. The login handler needs a concrete
`AuthService` (not just `DynAuthenticator`) so it can call `login`. We
inject it as `Option` because the `DevBypass` / `Jwks` code paths
don't have one — the field is `Some(_)` only when `AuthConfig::Local`
is picked. The router only mounts the `/auth/login` route when
`auth_service.is_some()` (§5.1).

```rust
#[derive(Clone)]
pub struct AppState {
    pub users: Arc<UserService>,
    pub weights: Arc<WeightService>,
    pub goals: Arc<GoalService>,
    pub foods: Arc<FoodService>,
    pub servings: Arc<ServingService>,
    pub logs: Arc<LogService>,
    pub authenticator: DynAuthenticator,
    pub auth: Option<Arc<AuthService>>,
}
```

`AppState::from_ports` gains an extra optional arg. Existing tests
pass `None`; the production build_state path passes `Some(_)` when
the local backend is selected.

`build_state` (`server.rs:94`) gains an `Arc<dyn LocalAuthRepository>`
local repo wire-up and constructs an `AuthService` when the config
asks for it:

```rust
pub async fn build_state(pool: PgPool, config: &AppConfig) -> Result<AppState> {
    let users: Arc<dyn UserRepository> = Arc::new(PgUserRepository::new(pool.clone()));
    let local_auth: Arc<dyn LocalAuthRepository> =
        Arc::new(PgLocalAuthRepository::new(pool.clone()));
    // … existing repo wiring …

    let (authenticator, auth_service) =
        build_authenticator(&config.auth, &config.env_name, users.clone(), local_auth)
            .await?;
    // … assemble AppState with auth_service …
}
```

`build_authenticator` (`server.rs:142`) returns a tuple:

```rust
async fn build_authenticator(
    cfg: &AuthConfig,
    env_name: &str,
    users: Arc<dyn UserRepository>,
    local_auth: Arc<dyn LocalAuthRepository>,
) -> Result<(DynAuthenticator, Option<Arc<AuthService>>)> {
    match cfg {
        AuthConfig::DevBypass { … } => { /* unchanged */ Ok((dev, None)) }
        AuthConfig::Jwks { … }       => { /* unchanged */ Ok((jwks, None)) }
        AuthConfig::Local => {
            let auth = Arc::new(AuthService::new(users, local_auth));
            let authn: DynAuthenticator = Arc::new(LocalAuthenticator::new(auth.clone()));
            Ok((authn, Some(auth)))
        }
    }
}
```

---

## 5. Handler + OpenAPI

### 5.1 New module — `server/crates/loseit-api/src/routes/auth.rs`

```rust
pub fn router() -> Router<AppState> {
    Router::new().route("/auth/login", post(login))
}

#[derive(Deserialize)]
struct LoginBody { username: String, password: String }

#[derive(Serialize)]
struct LoginResponse {
    token: String,
    expires_at: DateTime<Utc>,
}

async fn login(
    State(state): State<AppState>,
    Json(body): Json<LoginBody>,
) -> Result<Json<LoginResponse>, ApiError> {
    let Some(auth) = state.auth.clone() else {
        // OIDC / dev-bypass deploy — route is normally not mounted in
        // that case; this is a defensive guard.
        return Err(ApiError::not_found());
    };
    let token = auth.login(&body.username, &body.password).await
        .map_err(ApiError::from)?;
    Ok(Json(LoginResponse {
        token: token.raw,
        expires_at: token.expires_at,
    }))
}
```

Route registration in `router` (`server.rs:116-133`): the login route
goes into the `public` group (no `require_auth` middleware) and only
when `state.auth.is_some()`:

```rust
let public = routes::health::router();
let public = if state.auth.is_some() {
    public.merge(routes::auth::router())
} else {
    public
};
```

This is why `AppState.auth: Option<...>` is `Option`: an OIDC deploy
mounts the JWKS authenticator and exposes no `/auth/login`.

### 5.2 `ApiError` translation

`From<AuthError> for ApiError` (`error.rs:81-96`) is already exactly
what we want. `AuthError::Invalid` maps to
`unauthorized("invalid credential")`. `AuthError::Upstream(_)` maps to
503 (`auth_unavailable`). For the login route specifically the FE
documented `401` for bad creds — the existing mapping delivers that.
No edit needed.

### 5.3 OpenAPI delta — `server/specs/openapi.yaml`

Two edits.

**Edit A — new path block, insert after the `/health` block at line
89:**

```yaml
  /auth/login:
    post:
      tags: [Auth]
      operationId: login
      summary: Sign in with username + password
      description: |
        Exchanges a local username + password for an opaque server-issued
        bearer token. Use the returned `token` in `Authorization: Bearer
        <token>` headers on subsequent requests. Tokens have a sliding-
        window expiry refreshed on each authenticated request.
      security: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/LoginRequest" }
      responses:
        "200":
          description: Credentials accepted; token issued.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/LoginResponse" }
        "401": { $ref: "#/components/responses/Unauthorized" }
        "400": { $ref: "#/components/responses/BadRequest" }
```

**Edit B — two new schemas, insert into `components.schemas` after
`HeightUnit` at line 864:**

```yaml
    LoginRequest:
      type: object
      required: [username, password]
      properties:
        username: { type: string, minLength: 1, maxLength: 64 }
        password: { type: string, minLength: 1 }

    LoginResponse:
      type: object
      required: [token]
      properties:
        token:
          type: string
          description: |
            Opaque bearer token. Send back as
            `Authorization: Bearer <token>` on subsequent requests.
        expires_at:
          type: string
          format: date-time
          description: Absolute kill date for the token, in UTC.
```

A new `Auth` tag is added to the top-level `tags` list (around line 48
in the existing spec) so the route renders cleanly in Redocly:

```yaml
  - name: Auth
    description: Sign-in and token issuance.
```

---

## 6. Compose / env changes

### 6.1 `compose.coolify.yaml`

Three edits to `services.api.environment`:

```yaml
      # --- Auth -----------------------------------------------------------
      # Production flips DEV_AUTH_BYPASS off and uses the local-creds
      # backend (POST /api/v1/auth/login → opaque bearer). Set
      # LOSEIT_AUTH_BACKEND=jwks to switch to OIDC; see COOLIFY.md.
      DEV_AUTH_BYPASS: ${DEV_AUTH_BYPASS:-false}
      LOSEIT_AUTH_BACKEND: ${LOSEIT_AUTH_BACKEND:-local}
      LOSEIT_SEED_DEV_AUTH: ${LOSEIT_SEED_DEV_AUTH:-true}

      # Dev-bypass escape hatch (only honoured when DEV_AUTH_BYPASS=true).
      DEV_AUTH_TOKEN: ${DEV_AUTH_TOKEN:-dev-token}
      DEV_AUTH_ISSUER: ${DEV_AUTH_ISSUER:-dev}
      DEV_AUTH_USER_ID: ${DEV_AUTH_USER_ID:-dev-user}
      DEV_AUTH_EMAIL: ${DEV_AUTH_EMAIL:-dev@example.com}
      DEV_AUTH_DISPLAY_NAME: ${DEV_AUTH_DISPLAY_NAME:-Dev User}

      OIDC_ISSUER: ${OIDC_ISSUER:-}
      OIDC_AUDIENCE: ${OIDC_AUDIENCE:-}
      OIDC_JWKS_URL: ${OIDC_JWKS_URL:-}
      OIDC_JWKS_CACHE_TTL_SECS: ${OIDC_JWKS_CACHE_TTL_SECS:-600}
```

Concretely:

- `DEV_AUTH_BYPASS` default flips from `true` (line 41) to `false`. FE
  acceptance gate: `backend_tasks.md:151-154`.
- `LOSEIT_AUTH_BACKEND` added with default `local`. Read by
  `config.rs::load_auth`.
- `LOSEIT_SEED_DEV_AUTH` added with default `true`. Read by `main.rs`'s
  seed step (§7). Set to `false` once the deploy has booted at least
  once.

The block comment at `compose.coolify.yaml:37-40` is replaced to
describe the new tri-state.

### 6.2 `server/Cargo.toml` workspace deps

Add to `[workspace.dependencies]`:

```toml
argon2 = "0.5"
rand = "0.8"
```

(`rand` is already used transitively by `jsonwebtoken` and the JWKS
test code; pulling it into workspace deps lets `loseit-core` use it
without a per-crate version.)

`loseit-core/Cargo.toml` `[dependencies]` gains:

```toml
argon2.workspace = true
rand.workspace = true
sha2.workspace = true
base64.workspace = true
```

`loseit-db/Cargo.toml` already has the deps it needs.

---

## 7. Seed strategy

Runtime seed in `loseit-api`'s `main.rs`, gated on
`LOSEIT_AUTH_BACKEND=local` and `LOSEIT_SEED_DEV_AUTH=true`. Runs after
migrations and before `axum::serve`. Lives in a new module
`server/crates/loseit-api/src/seed.rs` so `main.rs` stays small.

```rust
// main.rs, after run_migrations and before build_router:
if matches!(config.auth, AuthConfig::Local)
    && env_bool("LOSEIT_SEED_DEV_AUTH", false)
{
    seed::seed_dev_local_auth(&pool).await.context("seeding dev local-auth")?;
}

// seed.rs
pub async fn seed_dev_local_auth(pool: &PgPool) -> Result<()> {
    let users: Arc<dyn UserRepository> = Arc::new(PgUserRepository::new(pool.clone()));
    let local: Arc<dyn LocalAuthRepository> = Arc::new(PgLocalAuthRepository::new(pool.clone()));
    let user_service = UserService::new(users.clone());
    let auth_service = AuthService::new(users, local);

    let identity = UserIdentity {
        issuer: "dev".into(),
        external_id: "dev-user".into(),
        email: Some("dev@example.com".into()),
        display_name: Some("Dev User".into()),
    };
    let user = user_service.ensure_user(&identity).await?;
    auth_service.seed_credential(user.id, "dev", "dev").await?;
    Ok(())
}
```

`ensure_user` (`service/user.rs:24-29`) is already idempotent — it
returns the existing row if one matches `(issuer, external_id)`, else
creates it. `seed_credential` (§3.3) is idempotent via the `ON
CONFLICT (user_id) DO UPDATE` in §3.4. A re-run on a database that
already has both rows is a no-op apart from `updated_at` ticking.

This sidesteps the "embed Rust in SQL migrations" trap and keeps the
dev-user UUID as the database's gen_random_uuid() default — which is
the only sane behaviour given the dev user was minted at first request
on the existing deploy and may already exist with a random UUID.

---

## 8. Test plan

Four layers, in the order an engineer should add them.

### 8.1 Core service tests — `server/crates/loseit-core/tests/auth_service.rs`

New test file. All against `InMemoryUserRepository` +
`InMemoryLocalAuthRepository`. Cases:

- `login_returns_token_on_correct_creds`
- `login_returns_invalid_on_wrong_password`
- `login_returns_invalid_on_unknown_username`
- `login_returns_invalid_on_malformed_username` — `""`, whitespace,
  >64-char input
- `login_timing_parity_with_unknown_user` — `#[ignore]` smoke probe;
  ratio of unknown-user wall-clock vs wrong-password wall-clock stays
  in `0.5..2.0`
- `verify_token_returns_user_on_active_token`
- `verify_token_returns_invalid_on_unknown_token`
- `verify_token_returns_invalid_on_expired_token`
- `verify_token_refreshes_sliding_window` — requires the in-memory
  repo to expose a test-only `peek_expires_at(token_hash)` helper
- `seed_credential_is_idempotent`
- `seed_credential_rejects_invalid_username`

### 8.2 In-memory repo tests — `server/crates/loseit-testing/tests/in_memory_local_auth.rs`

- `find_by_username_returns_none_for_unknown`
- `upsert_credential_inserts_then_updates`
- `touch_token_returns_none_for_unknown`
- `touch_token_refreshes_expires_at`
- `touch_token_returns_none_after_expiry`
- `delete_token_is_idempotent`

### 8.3 HTTP-level tests — `server/crates/loseit-api/tests/http_auth.rs`

New test file. Builds the router with in-memory fakes + an
`AuthService` wired against them; uses `tower::ServiceExt::oneshot`
exactly like `tests/http_profile.rs`.

- `login_returns_200_with_token_on_correct_creds` — body has `token`
  string + `expires_at` ISO-8601
- `login_returns_401_on_wrong_password` — body matches
  `{"code":"unauthorized","message":"invalid credential"}`
- `login_returns_401_on_unknown_username`
- `login_does_not_require_authorization_header` — verifies `security: []`
- `login_rejects_missing_body_fields_400` — axum's
  `Json<LoginBody>` rejects on missing keys
- `bearer_with_valid_token_passes_authenticate` — login, then
  `GET /me` with the returned bearer; 200, `issuer == "dev"`
- `bearer_with_invalid_token_returns_401`
- `bearer_with_expired_token_returns_401` — inject via the in-memory
  repo's test-only helper
- `login_then_two_protected_calls_use_same_token` — sliding-window
  refresh doesn't invalidate mid-session
- `login_route_absent_when_auth_service_unset` — `AppState.auth =
  None`, POST `/auth/login` returns 404

### 8.4 Postgres-level coverage

No CI Postgres today (`v1_finishup_design.md:13` documents the gap),
so no `loseit-db`-level integration test is added. The CHECK
constraint is exercised at deploy time by the migration. If we wire
CI Postgres later, two cases to add:
`pg_local_auth_rejects_uppercase_username_with_check_violation` and
`pg_local_auth_tokens_cascade_delete_with_user`.

---

## 9. Sequenced task list

Twelve tasks. Each is 1–3 files and well under 300 LOC. Dependencies
mean "must merge before the next can compile"; everything is on the
`be-auth-login` branch.

1. **Workspace deps** — Add `argon2 = "0.5"` and `rand = "0.8"` to
   `server/Cargo.toml` `[workspace.dependencies]`. Add the four new
   `loseit-core` deps in §6.2. `cargo check --workspace` must pass.
   (2 files, ~10 LOC.) No dependents.

2. **Migration** — Add `server/migrations/0007_local_auth.sql`
   verbatim per §2. No Rust changes. (1 file, ~40 LOC.) Depends on
   nothing.

3. **Domain types + repo trait** — Add
   `server/crates/loseit-core/src/domain/auth.rs` (§3.1) and
   `server/crates/loseit-core/src/repo/local_auth.rs` (§3.2);
   re-export from `domain/mod.rs` and `repo/mod.rs`. `cargo check -p
   loseit-core` must pass. (4 files, ~120 LOC.) Depends on #1.

4. **`AuthService`** — Add
   `server/crates/loseit-core/src/service/auth.rs` (§3.3); re-export
   from `service/mod.rs`. `cargo check -p loseit-core` must pass.
   (2 files, ~200 LOC.) Depends on #3.

5. **In-memory fake** — Add
   `server/crates/loseit-testing/src/local_auth.rs` per §3.5;
   re-export from `lib.rs`. (2 files, ~120 LOC.) Depends on #3.

6. **Pg repo** — Add
   `server/crates/loseit-db/src/local_auth_repo.rs` per §3.4; export
   from `lib.rs`. (2 files, ~150 LOC.) Depends on #3. Workspace
   compiles end-to-end after this lands.

7. **Core + in-memory tests** — Cases from §8.1 + §8.2. Run
   `cargo test -p loseit-core -p loseit-testing`. (2 files, ~300
   LOC.) Depends on #4 and #5.

8. **`LocalAuthenticator` + `AuthConfig::Local`** — Add
   `server/crates/loseit-api/src/auth/local.rs` (§4.1); add the
   `Local` variant in `config.rs` and rewrite `load_auth` per §4.2.
   (3 files, ~80 LOC.) Depends on #4.

9. **Composition root** — Edit `server.rs` per §4.3: `AppState.auth:
   Option<Arc<AuthService>>`, `from_ports` extra arg, `build_state`
   wiring, `build_authenticator` returns a tuple. Update every
   existing call site of `AppState::from_ports` (in `tests/http.rs`,
   `tests/http_profile.rs`, …) to pass `None`. `cargo check
   --workspace` must pass. (≥7 files, ~80 LOC of net change because
   each test harness gets a one-line edit.) Depends on #8.

10. **Login route + module mount** — Add
    `server/crates/loseit-api/src/routes/auth.rs` per §5.1; add
    `pub mod auth;` to `routes/mod.rs`; conditionally merge the
    router in `server::router` per §5.1's second snippet. (3 files,
    ~80 LOC.) Depends on #9.

11. **HTTP tests** — Add `tests/http_auth.rs` per §8.3. Run
    `cargo test -p loseit-api --test http_auth`. (1 file, ~250 LOC.)
    Depends on #10.

12. **Seed + compose + OpenAPI + Cargo lock** — Add
    `server/crates/loseit-api/src/seed.rs` (§7); wire it into
    `main.rs`; apply the `compose.coolify.yaml` edits in §6.1;
    apply the OpenAPI delta in §5.3; commit the `Cargo.lock` churn.
    (5 files, ~120 LOC.) Depends on #10.

Final verification:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
cargo check --manifest-path /workplace/fulfilled/server/Cargo.toml --workspace
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-core -p loseit-testing
cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
            -p loseit-api --test http_auth
```

FE acceptance gate (post-deploy, per `backend_tasks.md:156-167`):

```bash
curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"username":"dev","password":"dev"}' \
  https://api.coolify.stolworthy.co/api/v1/auth/login
# expect: 200, body has "token"

TOKEN=$(curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"username":"dev","password":"dev"}' \
  https://api.coolify.stolworthy.co/api/v1/auth/login | jq -r .token)

curl -sS -H "Authorization: Bearer $TOKEN" \
  https://api.coolify.stolworthy.co/api/v1/me
# expect: 200, dev user

curl -sS -X POST -H 'Content-Type: application/json' \
  -d '{"username":"dev","password":"WRONG"}' \
  https://api.coolify.stolworthy.co/api/v1/auth/login -o /dev/null -w '%{http_code}\n'
# expect: 401
```

---

## 10. Risks / open questions

- **Existing prod dev-user collision.** The deployed Coolify Postgres
  already has a `users` row for `(issuer='dev', external_id='dev-user')`
  with the UUID minted on first request. The runtime seed (§7) uses
  `ensure_user` which is idempotent under that key, so the seed picks
  up the existing row's UUID and writes the credential against it. No
  data loss, no UUID drift. **Not blocking.**

- **`AppState::from_ports` signature churn.** Adding `Option<Arc<
  AuthService>>` breaks every test harness's call site by one line.
  Counted in task #9; expect a touch list of ~7 test files. **Not
  blocking.**

- **Token sweeper.** Expired `local_auth_tokens` rows are filtered out
  at lookup (`touch_token` `WHERE expires_at > now()`) but never
  deleted. Index `local_auth_tokens_expires_idx` (§2) is in place for
  the eventual sweep. Closed-beta scale; one row per `/auth/login`
  call. **Not blocking — separate ticket if needed.**

- **Open question for the user.** FE spec phrases "`expires_at`
  (optional)" on the 200 response (`backend_tasks.md:122`). This
  design returns it unconditionally because clients may want a
  "next sign-in" hint and it costs nothing. FE's `BadCredentialsError`
  wiring (`auth_token.dart:158-167`) is the only documented consumer
  and doesn't read the field. If FE wants it omitted, flip to
  `Option<DateTime<Utc>>` on `LoginResponse`. **Worth one morning
  glance to confirm.**
