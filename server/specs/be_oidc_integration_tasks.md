# BE-OIDC — Authentik OIDC Integration (Ask 8) Task Breakdown

15 sequential tasks on branch `be-oidc-integration`. Each maps to one
commit; each ends green on `cargo check --workspace` minimum, with tests
added in their dedicated tasks. T11 is split into T11a and T11b per the
architect's explicit recommendation (see Notes).

Design reference: [`be_oidc_integration_design.md`](be_oidc_integration_design.md)
Ledger: [`backend_tickets_ledger.md`](backend_tickets_ledger.md) — BE-OIDC / Ask 8

---

## T01 — Workspace deps

**Subject:** Add `hmac`, `subtle`, `axum-extra`, and `url` to workspace Cargo.toml; wire into loseit-api.

**What changes:**
- `server/Cargo.toml` `[workspace.dependencies]`: add `hmac = "0.12"`, `subtle = "2"`, `axum-extra = { version = "0.10", features = ["cookie"] }`, `url = "2"`.
- `server/crates/loseit-api/Cargo.toml` `[dependencies]`: add `hmac.workspace = true`, `subtle.workspace = true`, `axum-extra.workspace = true`, `url.workspace = true`.
- No other Rust files modified.

**Acceptance:**
- `cargo check --workspace` green.
- No Rust source files changed.

**Files touched:** 2

**Depends on:** none

**Design ref:** §9.3 of be_oidc_integration_design.md

---

## T02 — Migration

**Subject:** Add migration `0009_oidc_handoff_codes.sql` for the one-time bearer ferry table.

**What changes:**
- Create `server/migrations/0009_oidc_handoff_codes.sql` verbatim per §7.1's final SQL. The table: `code_hash TEXT PRIMARY KEY`, `user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE`, `raw_token TEXT NOT NULL`, `token_expires_at TIMESTAMPTZ NOT NULL`, `expires_at TIMESTAMPTZ NOT NULL`, `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`. Plus a `CREATE INDEX IF NOT EXISTS oidc_handoff_codes_expires_idx` on `expires_at`.

**Key implementation notes:**
- Two `expires_at`-style columns: `expires_at` is the 60s handoff-code TTL; `token_expires_at` is the 30-day opaque bearer kill date returned on exchange.
- No Rust changes.
- All DDL is idempotent (`IF NOT EXISTS`).
- No background sweeper this ticket — `oidc_handoff_codes_expires_idx` is in place for a future one; the exchange handler's `WHERE expires_at > now()` filter handles runtime cleanup.

**Acceptance:**
- File exists at `server/migrations/0009_oidc_handoff_codes.sql`.
- `cargo check --workspace` still green.
- Re-running the file against an already-migrated DB is a no-op.

**Files touched:** 1

**Depends on:** none (parallelizable with T01 — different concerns, no shared file)

**Design ref:** §7.1, §9.1 of be_oidc_integration_design.md

---

## T03 — OidcHandoffRepository trait + in-memory fake

**Subject:** Add `repo/oidc_handoff.rs` to loseit-core; add `InMemoryOidcHandoffRepository` to loseit-testing.

**What changes:**
- Create `server/crates/loseit-core/src/repo/oidc_handoff.rs` with the `OidcHandoffRepository` async trait (`insert`, `claim`) and the `HandoffClaim` struct per §7.2. Extend `HandoffClaim` with `token_expires_at: DateTime<Utc>` to carry the bearer kill date from the final SQL shape.
- Re-export from `server/crates/loseit-core/src/repo/mod.rs`.
- Create `server/crates/loseit-testing/src/oidc_handoff.rs` with `InMemoryOidcHandoffRepository` — a `Mutex<HashMap<String, HandoffRow>>` impl mirroring the trait surface. The `claim` method filters `expires_at > now()` and atomically removes the row.
- Re-export from `server/crates/loseit-testing/src/lib.rs`.

**Key implementation notes:**
- `OidcHandoffRepository` is `Send + Sync + 'static` to live behind `Arc<dyn ...>`.
- `claim` returns `Ok(None)` for both unknown hashes and expired rows — wire-indistinguishable, matches the Pg `DELETE … WHERE expires_at > now() RETURNING` semantics.
- Add `server/crates/loseit-testing/tests/in_memory_oidc_handoff.rs` with 4 cases per §11.2: `insert_then_claim_returns_token`, `claim_deletes_row`, `claim_filters_expired`, `claim_for_missing_code_returns_none`.

**Acceptance:**
- `cargo check -p loseit-core -p loseit-testing` green.
- `cargo test -p loseit-testing --test in_memory_oidc_handoff` passes (4 cases).

**Files touched:** 5

**Depends on:** T01 (workspace deps must exist for loseit-testing compilation)

**Design ref:** §7.2, §11.2 of be_oidc_integration_design.md

---

## T04 — Pg handoff repository

**Subject:** Add `PgOidcHandoffRepository` in loseit-db; export from lib.rs.

**What changes:**
- Create `server/crates/loseit-db/src/oidc_handoff_repo.rs` with `PgOidcHandoffRepository { pool: PgPool }` and `impl OidcHandoffRepository`.
- `insert` SQL: `INSERT INTO oidc_handoff_codes (code_hash, user_id, raw_token, token_expires_at, expires_at) VALUES ($1, $2, $3, $4, $5)`.
- `claim` SQL: `DELETE FROM oidc_handoff_codes WHERE code_hash = $1 AND expires_at > now() RETURNING user_id, raw_token, token_expires_at` — single round trip, race-free.
- Export from `server/crates/loseit-db/src/lib.rs`.

**Key implementation notes:**
- Reuse the existing `map_sqlx` error helper.
- `claim` uses `fetch_optional` — returns `Ok(None)` on miss or expiry.
- No migration needed (T02 provides the DDL).

**Acceptance:**
- `cargo check --workspace` green. This is the task that closes the OidcHandoffRepository compilation gap for loseit-db.

**Files touched:** 2

**Depends on:** T02 (migration provides the table contract), T03 (trait must exist before the impl)

**Design ref:** §7.2 of be_oidc_integration_design.md

---

## T05 — AuthService::mint_session_for extraction

**Subject:** Extract the bearer-issue tail of `AuthService::login` into a new `mint_session_for` method; add 3 core service tests.

**What changes:**
- Edit `server/crates/loseit-core/src/service/auth.rs`: lift the 13-line bearer-issue block (`let raw_token = …` through `Ok(LocalAuthToken { … })`) into `pub async fn mint_session_for(&self, user_id: Uuid) -> Result<LocalAuthToken, AuthError>`. Rewrite `login` to call `self.mint_session_for(cred.user_id).await` at its tail.
- Edit `server/crates/loseit-core/tests/auth_service.rs`: add 3 cases per §11.1: `mint_session_for_returns_opaque_token`, `mint_session_for_then_verify_round_trips`, `login_still_works_after_extraction`.

**Key implementation notes:**
- Pure extract-method refactor — no new logic. All existing auth_service tests must still pass unchanged.
- `mint_session_for` is the shared token-mint surface for both the local-creds login path and the OIDC callback. Keeping it on `AuthService` (not duplicated into the OIDC handler) is the architect's explicit call (§3).

**Acceptance:**
- `cargo check -p loseit-core` green.
- `cargo test -p loseit-core --test auth_service` passes (existing 11 cases + 3 new = 14 total).

**Files touched:** 2

**Depends on:** none (standalone refactor, does not block any other task except T11a)

**Design ref:** §3, §11.1 of be_oidc_integration_design.md

---

## T06 — JwksVerifier extraction

**Subject:** Lift the JWKS cache + refresh + key-lookup logic from `JwksAuthenticator` into a new `JwksVerifier` type; rewrite `JwksAuthenticator` to hold it.

**What changes:**
- Create `server/crates/loseit-api/src/auth/jwks_verifier.rs` with `JwksVerifier { jwks_url, cache_ttl, cache, refresh_lock, http }`, the `OidcClaims` struct, and `pub async fn verify(&self, token, iss, aud, nonce) -> Result<OidcClaims, AuthError>` per §4. Move `JwksCacheState`, `key_for`, `is_stale`, `refresh_now`, and `is_usable` items from `jwks.rs` into this file.
- Edit `server/crates/loseit-api/src/auth/jwks.rs`: rewrite `JwksAuthenticator` to hold `JwksVerifier` internally and call `self.verifier.verify(token, &self.iss, &self.aud, None).await` in its `authenticate` shim.
- Add `pub mod jwks_verifier;` to `server/crates/loseit-api/src/auth/mod.rs`.

**Key implementation notes:**
- All existing `JwksAuthenticator` tests must pass unchanged — the public API contract is preserved.
- `OidcClaims.aud` is `serde_json::Value` (handles string or array from production providers).
- `nonce` parameter is `Option<&str>` — `None` for the `JwksAuthenticator` shim, `Some(nonce)` from the OIDC callback.
- The `JwksAuthenticator` runtime path is no longer reachable from middleware after T08 lands, but the type is kept (it is the engine of `JwksVerifier` and its tests remain).

**Acceptance:**
- `cargo check -p loseit-api` green.
- All pre-existing `JwksAuthenticator` tests pass.

**Files touched:** 3

**Depends on:** none (standalone refactor)

**Design ref:** §4, §2.2 of be_oidc_integration_design.md

---

## T07 — AuthConfig struct refactor

**Subject:** Rewrite `config.rs` from enum-based `AuthConfig` to struct-based; introduce `OidcProviderConfig`, `OidcCommonConfig`, `SecretBytes`, and the new `load_auth`.

**What changes:**
- Edit `server/crates/loseit-api/src/config.rs`: replace `AuthConfig` enum with the struct per §2.1 (`dev_bypass: Option<DevBypassConfig>`, `local: Option<LocalConfig>`, `oidc: Vec<OidcProviderConfig>`). Add `DevBypassConfig`, `LocalConfig` (marker struct), `OidcProviderConfig`, `OidcCommonConfig`, `SecretBytes` types. Rewrite `load_auth` to the multi-method parsing shape with the "at least one method" guard. Add `oidc_common: Option<OidcCommonConfig>` to `AppConfig`.
- Add helper functions `load_oidc_provider`, `load_state_secret`, `id_is_url_safe`, `has_duplicate_ids`, `capitalize` to `config.rs`.

**Key implementation notes:**
- `SecretBytes(Vec<u8>)` must implement `Debug` as `SecretBytes(<redacted, N bytes>)` — never leaks to logs.
- `LOSEIT_AUTH_BACKEND` env var is **removed** (breaking). No migration path — the current deploy uses local-creds (BE-008), not JWKS-only. Note in PR.
- `LOSEIT_AUTH_LOCAL` defaults `true` on missing env var.
- `id` in `OidcProviderConfig` enforces `[a-z0-9_-]{1,32}` at parse time via `id_is_url_safe`.
- No callers of `AuthConfig` change yet — compilation will break in T08 where `server.rs` pattern-matches on the old enum. That breakage is expected and resolved in T08.

**Acceptance:**
- `cargo check -p loseit-api` green (caller sites haven't changed yet — T08 resolves that).

**Files touched:** 1

**Depends on:** none

**Design ref:** §2.1 of be_oidc_integration_design.md

---

## T08 — Composition root and AppState wiring

**Subject:** Rewrite `server.rs` for the struct `AuthConfig`; add `AppState.oidc: Option<Arc<OidcRegistry>>`; update all `from_ports` call sites.

**What changes:**
- Edit `server/crates/loseit-api/src/server.rs` per §2.2:
  - Add `pub oidc: Option<Arc<OidcRegistry>>` and `pub local_login_enabled: bool` to `AppState`.
  - Add `oidc: Option<Arc<OidcRegistry>>` and `local_login_enabled: bool` parameters to `AppState::from_ports`.
  - Add `OidcRegistry` and `OidcProvider` structs to `server.rs` (or a new `server/crates/loseit-api/src/oidc.rs` module).
  - Rewrite `build_state` to construct `PgOidcHandoffRepository`, build `OidcProvider` per configured provider (each gets its own `JwksVerifier::new` call and `reqwest::Client`), assemble `OidcRegistry`.
  - Rename `build_authenticator` → `pick_authenticator`; rewrite to the new precedence: dev-bypass → local-or-oidc (`LocalAuthenticator`). `JwksAuthenticator` is no longer reachable from middleware.
  - `auth_service` is `Some` when either `local` or any `oidc` provider is configured.
- Edit every existing `AppState::from_ports` call site to pass `None, false` (or appropriate defaults) for the new parameters. Call sites are in:
  - `server/crates/loseit-api/tests/http.rs`
  - `server/crates/loseit-api/tests/http_foods.rs`
  - `server/crates/loseit-api/tests/http_jwks.rs`
  - `server/crates/loseit-api/tests/http_log.rs`
  - `server/crates/loseit-api/tests/http_profile.rs` (2 call sites)
  - `server/crates/loseit-api/tests/http_servings.rs`
  - `server/crates/loseit-api/tests/http_weights.rs`

**Key implementation notes:**
- `JwksVerifier::new` makes an HTTP call at boot; the `build_state` call for each OIDC provider will fail fast if the IdP is unreachable at deploy time — this is intentional (§13: refuse-to-boot is safer than silent 503).
- Test envs that previously set `LOSEIT_AUTH_BACKEND=jwks` must be cleaned up in the test harness. Grep for that env var.
- `local_login_enabled` is surfaced to `AppState` so the `/auth/providers` handler can return `local.enabled` accurately without re-reading config at request time.

**Acceptance:**
- `cargo check --workspace` green — this is the integration point that closes compilation across all crates.
- All pre-existing test files still compile with the updated `from_ports` signature.

**Files touched:** ~9 (server.rs + 7 test files, plus possibly a new oidc.rs module)

**Depends on:** T04 (PgOidcHandoffRepository), T06 (JwksVerifier), T07 (AuthConfig struct)

**Design ref:** §2.2 of be_oidc_integration_design.md

---

## T09 — State cookie module

**Subject:** Add `auth/oidc/state.rs` with `StateSigner`, `StatePayload`, sign/verify, and inline unit tests.

**What changes:**
- Create `server/crates/loseit-api/src/auth/oidc/` directory and `server/crates/loseit-api/src/auth/oidc/state.rs` with `StateSigner`, `StatePayload`, and the HMAC sign/verify functions per §5.1. `sign` returns `"<b64url(payload_json)>.<b64url(hmac)>"`. `verify` does constant-time HMAC compare via `subtle::ConstantTimeEq`, JSON parse, and `exp > now` check.
- Add `pub mod oidc;` to `server/crates/loseit-api/src/auth/mod.rs` and `pub mod state;` to `server/crates/loseit-api/src/auth/oidc/mod.rs`.
- Add inline `#[cfg(test)] mod tests` per §11.3: `sign_then_verify_round_trips`, `verify_rejects_truncated_signature`, `verify_rejects_truncated_payload`, `verify_rejects_expired`, `sign_is_url_safe`.

**Key implementation notes:**
- HMAC is over `b64url(payload_json)` — the verify path re-checks the serialized form, not re-serialized JSON (order-stable).
- Cookie attributes per §5.2: `HttpOnly; Secure; SameSite=Lax; Max-Age=600; Path=/api/v1/auth/oidc`. Drop `Secure` when `env_name != "production"`.
- `StatePayload.exp` is epoch seconds (i64); TTL is 600 seconds from creation.

**Acceptance:**
- `cargo check -p loseit-api` green.
- `cargo test -p loseit-api` (in-module tests): 5 state signer cases pass.

**Files touched:** 3

**Depends on:** T01 (hmac + subtle + axum-extra workspace deps)

**Design ref:** §5.1, §5.2, §11.3 of be_oidc_integration_design.md

---

## T10 — /auth/providers handler

**Subject:** Add the `providers` handler and descriptor types to `routes/auth.rs`; mount it unconditionally.

**What changes:**
- Edit `server/crates/loseit-api/src/routes/auth.rs`: add `ProvidersResponse`, `LocalProviderDescriptor`, `OidcProviderDescriptor` structs and the `providers` handler per §8.1.
- `local.enabled` reads `state.local_login_enabled` (threaded through `AppState` in T08).
- Mount `GET /auth/providers` in `routes::auth::router()` unconditionally (always present; returns `local.enabled=false, oidc=[]` as a graceful fallback when nothing is configured, per §8.5).

**Key implementation notes:**
- `start_url` is a relative URL: `format!("/api/v1/auth/oidc/{}/start", p.config.id)`.
- Handler returns `Json<ProvidersResponse>` (no `Result` wrapper — always 200).
- Order of OIDC entries in the response is HashMap iteration order; no stability guarantee is needed for v1.

**Acceptance:**
- `cargo check --workspace` green.
- Route appears at `GET /api/v1/auth/providers`.

**Files touched:** 1

**Depends on:** T08 (AppState.oidc and local_login_enabled must exist)

**Design ref:** §8.1, §8.5 of be_oidc_integration_design.md

---

## T11a — /start handler

**Subject:** Add the `oidc_start` handler, PKCE helpers, `next_url` validator, and cookie-build functions to `routes/auth.rs` (or a new `routes/auth/oidc.rs` submodule).

**What changes:**
- Add `oidc_start` handler per §8.2: extract `OidcRegistry` from state, look up provider by `provider_id`, call `resolve_next`, generate PKCE verifier + code challenge + CSRF state + nonce, build `StatePayload`, sign via `StateSigner`, build authorize URL via `build_authorize_url`, set state cookie, 302 to IdP.
- Add `resolve_next(fe_origin, next) -> Result<String, ApiError>` per §6: accepts path-only (`/`) or same-origin absolute URL; rejects scheme-relative (`//`) and backslash. Default is `/`.
- Add `build_authorize_url` and cookie-builder helpers (`build_state_cookie`, `clear_state_cookie`).
- Add `b64url_random(n)` and `b64url_sha256(s)` utility fns (used here and in T11b).
- Mount `GET /auth/oidc/:id/start` in `router()` conditionally when `state.oidc.is_some()` (or always mount and 404 defensively — prefer the conditional mount per §8.5).

**Key implementation notes:**
- PKCE: `pkce_verifier` = 32 random bytes b64url-no-pad (43 chars). `code_challenge` = `b64url(sha256(verifier))`, method `S256`.
- `SameSite=Lax` is correct for OAuth top-level redirects — the IdP 302s to `/callback`, which is a top-level navigation that needs the cookie. `Strict` would drop it.
- Authorize URL hard-codes Authentik's `<issuer>/authorize/` pattern (§8.2 note). Discovery doc parsing is deferred to v1.1.

**Acceptance:**
- `cargo check --workspace` green.
- Route appears at `GET /api/v1/auth/oidc/:id/start`.

**Files touched:** 1–2 (depending on whether a submodule is created)

**Depends on:** T08 (AppState + OidcRegistry), T09 (StateSigner)

**Design ref:** §8.2, §5.3, §6 of be_oidc_integration_design.md

---

## T11b — /callback handler

**Subject:** Add the `oidc_callback` handler, `exchange_code` IdP call, and post-callback redirect helpers.

**What changes:**
- Add `oidc_callback` handler per §8.3: read + verify state cookie, CSRF check, handle IdP error passthrough (302 to `<next>?oidc_error=…`), `exchange_code` at IdP `/token` endpoint, verify ID token via `provider.jwks.verify(…, Some(&payload.nonce))`, upsert user via `ensure_user`, `mint_session_for`, insert handoff row, clear cookie, 302 to `<next>?oidc_code=<handoff_raw>`.
- Add `exchange_code(provider, code, pkce_verifier) -> Result<TokenResponse, ApiError>` using `reqwest` form POST.
- Add `next_with_handoff(next, handoff)` and `next_with_error(next, err)` URL-builder helpers (use `url::Url` to handle `next` paths that may already contain a query string).
- Mount `GET /auth/oidc/:id/callback` in `router()`.

**Key implementation notes:**
- Handoff row lifetime: `expires_at = now + 60s`, `token_expires_at = session.expires_at` (from `mint_session_for`'s returned `LocalAuthToken`).
- State cookie is always cleared on callback exit regardless of outcome (set `Max-Age=0`).
- IdP token endpoint is `format!("{}token/", issuer.trim_end_matches('/'))` — same Authentik pattern as authorize. Discovery deferred.
- `UserIdentity.issuer` uses the provider slug (`provider_id`), not the full IdP URL. See §13 / Notes for the open-question callout.

**Acceptance:**
- `cargo check --workspace` green.
- Route appears at `GET /api/v1/auth/oidc/:id/callback`.

**Files touched:** 1–2

**Depends on:** T05 (mint_session_for), T06 (JwksVerifier), T08 (AppState + OidcRegistry), T09 (StateSigner)

**Design ref:** §8.3, §7.3 of be_oidc_integration_design.md

---

## T12 — /exchange handler

**Subject:** Add the `oidc_exchange` handler to `routes/auth.rs`; mount it.

**What changes:**
- Edit `server/crates/loseit-api/src/routes/auth.rs`: add `ExchangeBody { code: String }`, `ExchangeResponse { token: String, expires_at: DateTime<Utc> }`, and `oidc_exchange` handler per §8.4.
- Handler: hash `body.code` via `sha256_hex`, call `registry.handoffs.claim(&code_hash)`, return 401 on `None`, return `ExchangeResponse { token: claim.raw_token, expires_at: claim.token_expires_at }` on success.
- Mount `POST /auth/oidc/exchange` in `router()`.

**Key implementation notes:**
- `claim` is the atomic `DELETE … RETURNING` path — the call is inherently single-use.
- 401 (not 404) on unknown/expired code to avoid distinguishing expiry from non-existence to callers.
- `ExchangeResponse` deliberately matches `LoginResponse`'s wire shape — the FE gets one token format for both auth methods.

**Acceptance:**
- `cargo check --workspace` green.
- Route appears at `POST /api/v1/auth/oidc/exchange`.

**Files touched:** 1

**Depends on:** T04 (OidcHandoffRepository), T08 (AppState + OidcRegistry)

**Design ref:** §8.4, §8.5 of be_oidc_integration_design.md

---

## T13 — HTTP tests

**Subject:** Add `tests/http_oidc.rs` with 19 end-to-end HTTP test cases using a wiremock Authentik double.

**What changes:**
- Create `server/crates/loseit-api/tests/http_oidc.rs` — 19 cases per §11.4.
- Wire a `wiremock::MockServer` serving three endpoints: `GET /jwks/` (test-generated RSA public key), `POST /token/` (returns signed ID token for valid code+verifier), `GET /authorize/` (never followed — asserted by redirect URL shape).
- Test harness uses `InMemoryUserRepository`, `InMemoryLocalAuthRepository`, `InMemoryOidcHandoffRepository`, and the wiremock MockServer as the per-provider `http` client target.
- Add `wiremock` to `loseit-api/Cargo.toml` `[dev-dependencies]`.

**Key implementation notes:**
- Reuse the RSA-key generation helpers from `auth/jwks.rs#tests` for signed ID token generation.
- All tests use `tower::ServiceExt::oneshot` like `tests/http_profile.rs`.
- Cookie surface uses `axum_extra::CookieJar` in/out per the handler design.
- T13 is ~700 LOC — the largest single file in this ticket. Budget accordingly.

**Test cases (§11.4):**
1. `providers_lists_local_when_local_only`
2. `providers_lists_oidc_when_configured`
3. `start_returns_302_to_authorize_with_pkce`
4. `start_sets_state_cookie`
5. `start_rejects_bad_next`
6. `start_accepts_path_next`
7. `start_404_for_unknown_provider`
8. `callback_happy_path`
9. `callback_state_cookie_tampered_rejected_400`
10. `callback_state_query_mismatch_rejected_400`
11. `callback_expired_state_rejected_400`
12. `callback_idp_token_failure_returns_502`
13. `callback_id_token_invalid_sig_rejected_400`
14. `callback_nonce_mismatch_rejected_400`
15. `callback_propagates_idp_error_query`
16. `exchange_returns_token_then_404_on_replay`
17. `exchange_404_on_unknown_code`
18. `exchange_404_on_expired_handoff`
19. `callback_then_exchange_then_get_me`

**Acceptance:**
- `cargo test -p loseit-api --test http_oidc` passes (all 19 cases).

**Files touched:** 1 (~700 LOC) + `loseit-api/Cargo.toml` dev-dep addition

**Depends on:** T10, T11a, T11b, T12

**Design ref:** §11.4 of be_oidc_integration_design.md

---

## T14 — OpenAPI + compose + Cargo.lock

**Subject:** Apply the OpenAPI delta (4 paths + 4 schemas); apply `compose.coolify.yaml` edits; commit Cargo.lock churn.

**What changes:**
- Edit `server/specs/openapi.yaml`:
  - Insert the four new path blocks after the existing `/auth/login` block (line 117): `/auth/providers`, `/auth/oidc/{provider_id}/start`, `/auth/oidc/{provider_id}/callback`, `/auth/oidc/exchange` per §10.1.
  - Insert the four new schemas after `LoginResponse` (line 927): `AuthProviders`, `LocalProviderDescriptor`, `OidcProviderDescriptor`, `OidcExchangeRequest` per §10.2.
- Edit `compose.coolify.yaml`: replace the existing `--- Auth ---` block and the four old `OIDC_*` lines with the new multi-method block per §9.2. **Breaking**: removes `LOSEIT_AUTH_BACKEND`, `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_JWKS_CACHE_TTL_SECS`. Adds `OIDC_PROVIDERS`, `LOSEIT_AUTH_STATE_SECRET`, `LOSEIT_FE_ORIGIN`, and per-provider `OIDC_AUTHENTIK_*` vars.
- Commit `Cargo.lock` churn from T01's new `hmac`, `subtle`, `axum-extra`, `url` additions.
- Check whether `COOLIFY.md` exists at repo root; if so, add the operator runbook section for Authentik UI setup per §9.2 note. If it does not exist, skip (the compose comment block is sufficient).

**Key implementation notes:**
- The removal of `LOSEIT_AUTH_BACKEND` is a deliberate breaking change to the deploy contract. PR description must list the exact env var migration steps for the Coolify operator.
- `LoginResponse` is reused as the schema reference for `/auth/oidc/exchange`'s 200 response — no new schema needed.
- No Rust changes.

**Acceptance:**
- `cargo check --workspace` still green.
- OpenAPI spec lints clean (run existing lint tooling in `server/scripts/` if present).
- Four new paths and four new schemas are present in `openapi.yaml`.

**Files touched:** 3 (openapi.yaml, compose.coolify.yaml, Cargo.lock) + optionally COOLIFY.md

**Depends on:** T12 (Rust wire must exist before spec reflects it — keeps spec and impl in sync)

**Design ref:** §9.2, §10 of be_oidc_integration_design.md

---

## Notes for engineers

**T11 split: kept as 11a + 11b (15 tasks total).** The architect
explicitly flagged T11 as splittable. The `/start` and `/callback`
handlers are large enough (~200 LOC each) that splitting gives a
reviewable commit boundary and makes bisecting failures easier. T11a
lands the `/start` handler, PKCE helpers, and open-redirect validator.
T11b lands the `/callback` handler, the IdP code exchange, and the
handoff insert. Both compile to green individually. T13 depends on both
being in before the HTTP tests run.

**T08 is the integration bottleneck.** It requires T04 (Pg handoff
repo), T06 (JwksVerifier), and T07 (AuthConfig struct) to all be merged
before it can compile. T01, T02, T05, T06, T07, and T09 are all
independently startable in parallel — the first convergence point is
T08. Engineers should not start T10–T12 until T08 lands.

**Dependency graph vs. architect's chain.** The architect's list is
taken at face value with one clarification: the architect listed T12
(`/exchange` handler) as depending on "#4, #8" (Pg handoff repo,
composition root). That is correct and preserved here. T14 (OpenAPI)
depends on T12 in this tracker — keeping spec and Rust in the same
merge window rather than landing spec ahead of the wire. No other
dependency changes.

**`LOSEIT_AUTH_BACKEND` is gone — Coolify env migration required.** The
old `LOSEIT_AUTH_BACKEND=local | jwks` toggle is removed in T07. The
current production deploy uses `LOSEIT_AUTH_LOCAL=true` (set in BE-008).
No `jwks`-only deployment is in the wild (§13), so the removal is safe.
The operator must remove `LOSEIT_AUTH_BACKEND` from Coolify's env panel
after this branch ships; the server will refuse to boot on an unknown
env var only if the old code path still validates for it. Mention in PR.

**`UserIdentity.issuer` uses the provider slug, not the full IdP URL.**
The OIDC callback stores `provider_id` (e.g., `"authentik"`) in
`users.issuer`, not the full `https://authentik.stolworthy.co/...` URL.
This diverges from the legacy `JwksAuthenticator` convention which
wrote the full `iss` claim. The architect recommends keeping the slug
(stable across IdP URL rotations). Flag this for review in the PR and
update the `users.issuer` column documentation if a schema comment
exists.

**`JwksAuthenticator` is no longer reachable from middleware after T08.**
The type and its tests are kept — it is now an internal engine of
`JwksVerifier`. If a reviewer questions why the type exists after T08,
point to §2.2 of the design.

**No Pg integration tests.** The `DELETE … RETURNING` SQL in `PgOidcHandoffRepository` is exercised only at deploy time. Same gap as BE-008. If CI Postgres is wired later, add `pg_handoff_claim_is_single_use` and `pg_handoff_claim_filters_expired` as `#[sqlx::test]` cases.

**Boot-time IdP reachability.** `JwksVerifier::new` makes an HTTP call
at startup to warm its JWKS cache. A deploy against an unreachable
Authentik will fail at boot (not at first request). This is intentional
per §13 — refuse to boot is safer than silently serving 503 on every
callback. A future lazy-warm mode is a half-day fix.

**OIDC logout UX is deferred — out of scope for this branch.** The
architect flagged "what does log out look like for an OIDC user?" as
the single most important open question (§13). The controller has
explicitly deferred this to a daylight call. Do NOT add an
`end_session` task or a `GET /auth/oidc/{id}/end_session` handler to
this branch. The current behaviour (drop bearer locally, IdP session
persists) is acceptable for closed-beta. Revisit before public launch.

**Final verification commands:**

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
