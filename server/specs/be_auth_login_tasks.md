# BE-008 — Auth Login Task Breakdown

12 sequential tasks on branch `be-auth-login`. Each maps to one commit;
each ends green on `cargo check --workspace` minimum, with tests added
in their dedicated tasks.

Design reference: [`be_auth_login_design.md`](be_auth_login_design.md)
Ledger: [`backend_tickets_ledger.md`](backend_tickets_ledger.md) — BE-008

---

## T01 — Workspace deps

**Subject:** Add argon2 + rand to workspace Cargo.toml; wire into loseit-core.

**What changes:**
- `server/Cargo.toml` `[workspace.dependencies]`: add `argon2 = "0.5"` and `rand = "0.8"`.
- `server/crates/loseit-core/Cargo.toml` `[dependencies]`: add `argon2.workspace = true`, `rand.workspace = true`, `sha2.workspace = true`, `base64.workspace = true`. (`sha2` and `base64` are already workspace-level; this just wires them into loseit-core.)

**Acceptance:**
- `cargo check --workspace` green.
- No other Rust files modified.

**Files touched:** 2

**Depends on:** none

**Design ref:** §6.2 of be_auth_login_design.md

---

## T02 — Migration

**Subject:** Add migration 0007_local_auth.sql for users_local_auth + local_auth_tokens.

**What changes:**
- Create `server/migrations/0007_local_auth.sql` verbatim per §2 of the design. The file introduces two tables (`users_local_auth`, `local_auth_tokens`), a named CHECK constraint, three indexes, and a trigger. All DDL is idempotent (`IF NOT EXISTS`, `DROP CONSTRAINT IF EXISTS` before re-adding).

**Key implementation notes:**
- Token hash column is `sha256(raw_token)` hex-encoded — raw bearer never persisted.
- `ON DELETE CASCADE` from `users(id)` on both tables; `DELETE /me` needs no extra cleanup.
- The `set_updated_at()` trigger function already exists (see earlier migrations); do not redefine it.
- No Rust changes.

**Acceptance:**
- File exists at `server/migrations/0007_local_auth.sql`.
- `cargo check --workspace` still green (no Rust touched).
- Re-running the file against an already-migrated DB is a no-op.

**Files touched:** 1

**Depends on:** none (parallelizable with T01 — different concerns, no shared file)

**Design ref:** §2 of be_auth_login_design.md

---

## T03 — Domain types + repo trait

**Subject:** Add domain/auth.rs and repo/local_auth.rs; re-export from their mod.rs files.

**What changes:**
- Create `server/crates/loseit-core/src/domain/auth.rs` with `Username`, `LocalAuthToken`, and `LocalAuthCredential` (§3.1).
- Create `server/crates/loseit-core/src/repo/local_auth.rs` with the `LocalAuthRepository` async trait: `find_by_username`, `upsert_credential`, `insert_token`, `touch_token`, `delete_token` (§3.2).
- Re-export from `domain/mod.rs` and `repo/mod.rs`.

**Key implementation notes:**
- `Username::parse` enforces lower-case + 1–64 char bounds. Returns `Option<Self>` — no panic path.
- `LocalAuthRepository` is `Send + Sync + 'static` so it can live behind `Arc<dyn ...>`.
- `find_by_username` returns `Ok(None)` for unknown usernames (not an error) so the caller can run a constant-time dummy verify.

**Acceptance:**
- `cargo check -p loseit-core` green.
- Workspace as a whole will not fully compile yet (loseit-db and loseit-api don't have impls yet) — expected.

**Files touched:** 4

**Depends on:** T01 (argon2/rand/sha2/base64 in loseit-core Cargo.toml)

**Design ref:** §3.1, §3.2 of be_auth_login_design.md

---

## T04 — AuthService

**Subject:** Add service/auth.rs with login, verify_token, and seed_credential; re-export from service/mod.rs.

**What changes:**
- Create `server/crates/loseit-core/src/service/auth.rs` (§3.3).
- Re-export `AuthService` from `service/mod.rs`.

**Key implementation notes (all free functions + impl live in auth.rs):**
- `hash_password` — `Argon2::default().hash_password(...)` with `SaltString::generate(&mut OsRng)`.
- `verify_password` — `Argon2::default().verify_password(...)`; returns `false` on any error.
- `mint_raw_token` — 32 bytes from `OsRng`, base64url-encoded without padding (43 chars).
- `sha256_hex` — `Sha256::digest` lower-hex encoded. Used by both `login` (to store) and `verify_token` (to look up).
- `TOKEN_TTL = Duration::days(30)` — applied on issue and renew.
- `AuthService::new` pre-computes a `dummy_hash` of `"unused"` at construction so unknown-username and wrong-password branches run the same argon2 verify cost (timing parity, §3.5 of design).
- `login` failure paths (malformed username, unknown user, wrong password) all return `AuthError::Invalid` — wire-indistinguishable.

**Acceptance:**
- `cargo check -p loseit-core` green.

**Files touched:** 2

**Depends on:** T03

**Design ref:** §3.3 of be_auth_login_design.md

---

## T05 — In-memory fake

**Subject:** Add InMemoryLocalAuthRepository in loseit-testing; re-export from lib.rs.

**What changes:**
- Create `server/crates/loseit-testing/src/local_auth.rs` (§3.5).
- Re-export from `loseit-testing/src/lib.rs`.

**Key implementation notes:**
- Shape: `Mutex<HashMap<...>>` mirroring `users.rs`.
- `touch_token` drops expired rows before returning, matching Pg semantics (`WHERE expires_at > now()`).
- Add a `pub fn peek_expires_at(&self, token_hash: &str) -> Option<DateTime<Utc>>` test helper — required by the `verify_token_refreshes_sliding_window` test in T07.
- `upsert_credential` conflicts on `user_id` (same `ON CONFLICT (user_id) DO UPDATE` semantics as the Pg impl).

**Acceptance:**
- `cargo check -p loseit-testing` green.

**Files touched:** 2

**Depends on:** T03

**Design ref:** §3.5 of be_auth_login_design.md

---

## T06 — Pg repository

**Subject:** Add PgLocalAuthRepository in loseit-db; export from lib.rs.

**What changes:**
- Create `server/crates/loseit-db/src/local_auth_repo.rs` (§3.4): `PgLocalAuthRepository { pool: PgPool }`, a `#[derive(sqlx::FromRow)] struct CredRow { ... }`, `impl From<CredRow> for LocalAuthCredential`, and all five trait method bodies.
- Export from `loseit-db/src/lib.rs`.

**Key implementation notes:**
- Reuse the existing `map_sqlx` error helper for error translation.
- `touch_token` SQL uses `greatest(expires_at, $2)` to prevent clock skew from shortening an active session; returns `NULL` on miss or expiry — use `fetch_optional`.
- The five SQL strings are in §3.4; copy them verbatim. `SELECT_CRED_COLUMNS` constant reduces duplication.
- `delete_token` is a no-op if the row doesn't exist — `execute` (not `fetch_one`).

**Acceptance:**
- `cargo check --workspace` green. This is the task that closes the compilation gap — after T06 lands, the full workspace compiles end-to-end for the first time on this branch.

**Files touched:** 2

**Depends on:** T03 (trait must exist before the impl can reference it)

**Note:** T06 is **required before T09** (composition root). `build_state` in `server.rs` constructs a `PgLocalAuthRepository` directly; without T06 the binary does not link. The architect's dependency graph listed T06 as parallel with T04/T05 and not gating T09 — this is incorrect. T09 must wait for T06. See Notes for Engineers below.

**Design ref:** §3.4 of be_auth_login_design.md

---

## T07 — Core + in-memory tests

**Subject:** Add tests/auth_service.rs (loseit-core) and tests/in_memory_local_auth.rs (loseit-testing).

**What changes:**
- Create `server/crates/loseit-core/tests/auth_service.rs` — 11 cases from §8.1.
- Create `server/crates/loseit-testing/tests/in_memory_local_auth.rs` — 6 cases from §8.2.

**Key test cases (§8.1):**
- `login_returns_token_on_correct_creds`
- `login_returns_invalid_on_wrong_password`
- `login_returns_invalid_on_unknown_username`
- `login_returns_invalid_on_malformed_username` (`""`, whitespace, >64 chars)
- `login_timing_parity_with_unknown_user` — `#[ignore]`; ratio of unknown-user vs wrong-password wall-clock stays in `0.5..2.0`
- `verify_token_returns_user_on_active_token`
- `verify_token_returns_invalid_on_unknown_token`
- `verify_token_returns_invalid_on_expired_token`
- `verify_token_refreshes_sliding_window` — uses `peek_expires_at` added in T05
- `seed_credential_is_idempotent`
- `seed_credential_rejects_invalid_username`

**Key test cases (§8.2):**
- `find_by_username_returns_none_for_unknown`
- `upsert_credential_inserts_then_updates`
- `touch_token_returns_none_for_unknown`
- `touch_token_refreshes_expires_at`
- `touch_token_returns_none_after_expiry`
- `delete_token_is_idempotent`

All tests use `InMemoryUserRepository` + `InMemoryLocalAuthRepository`. No Postgres needed.

**Acceptance:**
- `cargo test -p loseit-core -p loseit-testing` passes (excluding `#[ignore]` tests).

**Files touched:** 2

**Depends on:** T04 (AuthService), T05 (InMemoryLocalAuthRepository)

**Design ref:** §8.1, §8.2 of be_auth_login_design.md

---

## T08 — LocalAuthenticator + AuthConfig::Local

**Subject:** Add auth/local.rs; add Local variant to AuthConfig and rewrite load_auth.

**What changes:**
- Create `server/crates/loseit-api/src/auth/local.rs` with `LocalAuthenticator` (§4.1). Thin adapter: delegates `authenticate(&self, token)` to `AuthService::verify_token`, returns `user.identity`.
- Edit `server/crates/loseit-api/src/config.rs`: add `AuthConfig::Local` variant (no fields); rewrite `load_auth` to check `DEV_AUTH_BYPASS` first, then dispatch on `LOSEIT_AUTH_BACKEND` (`"local"` → default, `"jwks"` → existing branch) (§4.2).

**Key implementation notes:**
- `AuthConfig::Local` carries no fields — everything it needs comes from the Pg pool at composition time.
- The `DEV_AUTH_BYPASS=true` branch still short-circuits everything else, preserving CI / local-dev escape hatch.
- `LOSEIT_AUTH_BACKEND` defaults to `"local"` on missing env var.
- `auth/mod.rs` gets a `pub mod local;` line.

**Acceptance:**
- `cargo check -p loseit-api` green.

**Files touched:** 3 (`auth/local.rs` new, `auth/mod.rs` mod declaration, `config.rs` edited)

**Depends on:** T04 (AuthService type)

**Design ref:** §4.1, §4.2 of be_auth_login_design.md

---

## T09 — Composition root

**Subject:** Wire AppState.auth: Option<Arc<AuthService>>, update build_state and all from_ports call sites.

**What changes:**
- Edit `server/crates/loseit-api/src/server.rs` (§4.3):
  - Add `pub auth: Option<Arc<AuthService>>` to `AppState`.
  - Add `auth_service: Option<Arc<AuthService>>` parameter to `AppState::from_ports`.
  - Extend `build_state` to construct `PgLocalAuthRepository`, call new `build_authenticator` helper that returns `(DynAuthenticator, Option<Arc<AuthService>>)`.
  - `build_authenticator` returns `Some(auth)` only for `AuthConfig::Local`; `DevBypass` and `Jwks` branches return `None`.
- Update every existing `AppState::from_ports` call site to pass `None` as the final arg. There are **8 call sites** across 7 test files:
  - `tests/http.rs`
  - `tests/http_foods.rs`
  - `tests/http_jwks.rs`
  - `tests/http_log.rs`
  - `tests/http_profile.rs` (2 call sites)
  - `tests/http_servings.rs`
  - `tests/http_weights.rs`

**Acceptance:**
- `cargo check --workspace` green.
- All pre-existing test files still compile with `None` passed.

**Files touched:** ~9 (server.rs + 7 test files)

**Depends on:** T06 (PgLocalAuthRepository must exist before build_state can construct it), T08 (AuthConfig::Local + LocalAuthenticator)

**Design ref:** §4.3 of be_auth_login_design.md

---

## T10 — Login route + module mount

**Subject:** Add routes/auth.rs with POST /auth/login; mount conditionally in server::router.

**What changes:**
- Create `server/crates/loseit-api/src/routes/auth.rs` (§5.1): `LoginBody`, `LoginResponse`, `login` handler, `router()` function.
- Add `pub mod auth;` to `server/crates/loseit-api/src/routes/mod.rs`.
- Edit `server::router` in `server.rs` to conditionally merge `routes::auth::router()` into the public (unauthenticated) group only when `state.auth.is_some()` (§5.1 second snippet).

**Key implementation notes:**
- The login handler takes `State(state): State<AppState>` and does a `let Some(auth) = state.auth.clone() else { return Err(ApiError::not_found()); }` defensive guard — the route is normally not mounted when `auth` is `None`, but the guard prevents a panic if somehow it is.
- `ApiError::from(AuthError)` translation is already in `error.rs:81-96`; no new error mapping needed.
- Route is mounted in the `public` group (no `require_auth` middleware).
- `LoginResponse` includes `token: String` + `expires_at: DateTime<Utc>` (returned unconditionally per §10 open question — FE ignores it, costs nothing to include).

**Acceptance:**
- `cargo check --workspace` green.
- Route appears at `POST /api/v1/auth/login`.

**Files touched:** 3

**Depends on:** T09

**Design ref:** §5.1, §5.2 of be_auth_login_design.md

---

## T11 — HTTP tests

**Subject:** Add tests/http_auth.rs with 10 end-to-end HTTP test cases.

**What changes:**
- Create `server/crates/loseit-api/tests/http_auth.rs` — 10 cases from §8.3.

**Test harness setup:** Build the router with in-memory fakes + an `AuthService` wired against them; `AppState::from_ports(..., Some(Arc::new(auth_service)))`. Use `tower::ServiceExt::oneshot` exactly like `tests/http_profile.rs`.

**Cases (§8.3):**
- `login_returns_200_with_token_on_correct_creds` — body has `token` string + `expires_at` ISO-8601
- `login_returns_401_on_wrong_password` — body matches `{"code":"unauthorized","message":"invalid credential"}`
- `login_returns_401_on_unknown_username`
- `login_does_not_require_authorization_header` — verifies `security: []`
- `login_rejects_missing_body_fields_400` — axum's `Json<LoginBody>` rejects on missing keys
- `bearer_with_valid_token_passes_authenticate` — login, then `GET /me` with returned bearer; 200, `issuer == "dev"`
- `bearer_with_invalid_token_returns_401`
- `bearer_with_expired_token_returns_401` — inject via in-memory repo's test-only helper
- `login_then_two_protected_calls_use_same_token` — sliding-window refresh doesn't invalidate mid-session
- `login_route_absent_when_auth_service_unset` — `AppState.auth = None`, POST `/auth/login` returns 404

**Acceptance:**
- `cargo test -p loseit-api --test http_auth` passes (all 10 cases).

**Files touched:** 1 (~250 LOC)

**Depends on:** T10

**Design ref:** §8.3 of be_auth_login_design.md

---

## T12 — Seed + compose + OpenAPI + Cargo.lock

**Subject:** Add seed.rs; wire into main.rs; apply compose.coolify.yaml edits; apply OpenAPI delta; commit Cargo.lock.

**What changes:**
- Create `server/crates/loseit-api/src/seed.rs` with `seed_dev_local_auth(pool: &PgPool)` (§7). Constructs `PgUserRepository`, `PgLocalAuthRepository`, `UserService`, and `AuthService` locally; calls `ensure_user(dev_identity)` then `auth_service.seed_credential(user.id, "dev", "dev")`. Both are idempotent.
- Edit `server/crates/loseit-api/src/main.rs`: add `mod seed;`; after `run_migrations` and before `build_router`, gate the seed call on `matches!(config.auth, AuthConfig::Local) && env_bool("LOSEIT_SEED_DEV_AUTH", false)`.
- Edit `compose.coolify.yaml` `services.api.environment` (§6.1): flip `DEV_AUTH_BYPASS` default to `false`; add `LOSEIT_AUTH_BACKEND: ${LOSEIT_AUTH_BACKEND:-local}`; add `LOSEIT_SEED_DEV_AUTH: ${LOSEIT_SEED_DEV_AUTH:-true}`; replace the block comment at lines 37–40 to describe the new tri-state.
- Edit `server/specs/openapi.yaml` (§5.3):
  - Add `Auth` tag to the top-level `tags` list (~line 48).
  - Insert `/auth/login` path block after the `/health` block (~line 89).
  - Add `LoginRequest` and `LoginResponse` schemas under `components.schemas` after `HeightUnit` (~line 864).
- Commit `Cargo.lock` churn from T01's new `argon2` + `rand` additions.

**Key implementation notes:**
- `seed.rs` creates its own short-lived service instances — it does not use `AppState` or `build_state`. This keeps `main.rs` clean and the seed reusable in tests.
- The seed is idempotent: `ensure_user` uses `ON CONFLICT (issuer, external_id) DO UPDATE` and `seed_credential` uses `ON CONFLICT (user_id) DO UPDATE`. Re-deploy is safe.
- `LOSEIT_SEED_DEV_AUTH=true` is the production first-boot default in compose; operators set it to `false` after the first successful deploy.

**Acceptance:**
- `cargo check --workspace` green.
- Final verification commands pass:
  ```bash
  export PATH="$HOME/.cargo/bin:$PATH"
  cargo check --manifest-path /workplace/fulfilled/server/Cargo.toml --workspace
  cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
              -p loseit-core -p loseit-testing
  cargo test  --manifest-path /workplace/fulfilled/server/Cargo.toml \
              -p loseit-api --test http_auth
  ```
- FE acceptance gate passes (see §9 of design for curl commands against the deployed API).

**Files touched:** 5

**Depends on:** T10 (login route + AuthConfig::Local must exist for main.rs seed gating)

**Design ref:** §5.3, §6.1, §7 of be_auth_login_design.md

---

## Notes for engineers

**Sequencing fix vs. architect's graph — T06 gates T09.**
The architect's dependency chain stated T06 (Pg repo) could land in parallel with T04/T05 and that T09 (composition root) only needed T08. This is incorrect. `build_state` in `server.rs` directly constructs `PgLocalAuthRepository::new(pool.clone())`. Until T06 exists, the `loseit-api` binary cannot link and `cargo check --workspace` will fail after T09 is applied. The corrected gate is: **T09 depends on both T06 and T08**. Engineers should not start T09 until both land.

**T09 touches 9 files but net LOC delta is small (~80 LOC).** The volume is test-harness boilerplate — each of the 8 existing `AppState::from_ports(...)` call sites gets one extra `None` argument. Grep for `from_ports` to find them all; they're in `tests/http*.rs` files only.

**`expires_at` on LoginResponse is non-optional in this implementation.** The BE-008 ledger entry marks `expires_at` as optional in the wire contract. The design (§10) chose to return it unconditionally since it costs nothing. FE ignores it. If FE later asks for it to be omitted, flip `LoginResponse.expires_at` to `Option<DateTime<Utc>>` — one-line change.

**No Postgres CI.** There are no Pg integration tests for `PgLocalAuthRepository`. The SQL in T06 is exercised only at deploy time. If CI Postgres is wired later, add: `pg_local_auth_rejects_uppercase_username_with_check_violation` and `pg_local_auth_tokens_cascade_delete_with_user` (§8.4 of design).

**Timing-parity test is `#[ignore]` by default.** `login_timing_parity_with_unknown_user` in T07 is a smoke probe that validates the dummy-hash constant-time guard. It is `#[ignore]` so it doesn't slow CI; run it manually with `cargo test -- --ignored login_timing_parity` before declaring the security posture correct.
