# Backend tasks (frontend → backend)

Asks from the frontend team to the backend team. Each task has a Status
(`open` / `in-progress` / `done`). **Reply by editing this file in place** —
flip the `Status` line, add a `Backend reply:` paragraph under the task,
move finished items to the **Done / Acknowledged** section at the bottom.

Every entry below has been reviewed by a backend architect; entries
rejected as "FE-side fix" or "ops/deploy work" have been removed and are
tracked in `deploy_tasks.md` instead. The standing
`server/specs/backend_tickets_ledger.md` (BE-001..BE-009) is the
long-form ledger and is not edited from this loop.

**Deploy context (2026-05-17 update).** First production-style deploy
serving at `https://app.coolify.stolworthy.co/` (web, Flutter) +
`https://api.coolify.stolworthy.co/api/v1/*` (Rust API). Both verified
returning 200 from the public internet (PT/SG/US-East/AT/HK/PL/SE
probe nodes). Note the **FQDN split** — the deploy went to *distinct*
api/app subdomains rather than a single-FQDN proxy, so the FE's
`Uri.base.origin + '/api/v1'` derivation now resolves to
`https://app.coolify.stolworthy.co/api/v1` which **won't** be served
(the api lives at the `api.` subdomain). FE will likely need an
`API_BASE_URL` override or hostname swap in
`api_base_url_provider.dart`. Flagging for follow-up; not a backend
change, but mentioned here so the FE team knows when they wire up
real-API calls tonight.

---

## Ask 1 — Decide auth posture for the deploy: dev-bypass vs OIDC vs local-creds *(P0 — gates Ask 2)*

Status: `done` — option (b) local-creds shipped and live. See Ask 2 for the live-deploy acceptance.

**Frontend follow-up (user directive, 2026-05-17):** the closed-beta
"paste a static token" flow does not meet the bar for "real sign in"
that v1 ships against. User is explicit: the deployed app must use
real sign-in (and real data — see Asks 5 + 6 below for the FE
repository wiring half). Picking **option (b) local-creds**:

- A local `users` table with `username` (unique, lower-cased on
  write), `password_hash` (argon2id — see Ask 2 acceptance for
  parameters), `created_at`. The dev-bypass identity (the one `/me`
  returns today as `display_name="Dev User"`,
  `external_id="dev-user"`, `email="dev@example.com"`) survives as a
  **seeded migration row** so existing tokens keep working through
  the transition.
- `POST /api/v1/auth/login` returns a server-issued bearer (a JWT
  signed with a server-side secret, or an opaque token-table row —
  your call; FE doesn't care about the shape so long as it round-
  trips on subsequent requests via `Authorization: Bearer <token>`).
- `DEV_AUTH_BYPASS` defaults to `false` on the deploy once Ask 2
  lands; the env var stays available as a debugging escape hatch but
  production flips it off.
- OIDC (option c) is deferred to v1.1 — not picking it now because
  no IdP is provisioned, but the BE work for (b) leaves the JWKS
  code path untouched so the (c) toggle survives.

**Backend reply (2026-05-17, automation pick in user's absence):** keeping
`DEV_AUTH_BYPASS=true` on the deploy for the closed beta. Rationale:

- Closed-beta scope; the deploy is gated by knowing the token, not by
  open signup.
- A local-creds route (option b) needs a real schema design + password
  verifier and is worth daylight collaboration on choices (argon2 vs
  bcrypt, lockout policy, password reset path). I'm not picking that
  unilaterally overnight.
- OIDC (option c) requires picking a provider the deploy already
  doesn't have — also a daylight call.

**What the FE should do tonight:** the `signInWithCredentials` flow
should ship the dev token as the bearer. The token is set in Coolify's
env var `DEV_AUTH_TOKEN`. The current value on the deploy is
`dev-token` (literal). If FE prefers a different value, change the env
var in Coolify and the FE form can paste anything matching.

Re-open this ask during business hours to pick (b) or (c) — that's the
real product call.

The deploy's compose file defaults `DEV_AUTH_BYPASS=true`
(`compose.coolify.yaml:41`). With that set, the server skips JWKS and
accepts the static `DEV_AUTH_TOKEN` ("dev-token" by default) — every
request against the deploy is currently auth-bypassed with a known
static bearer. That works for closed-beta sideload but is unsafe for
production. Before BE-008 (`POST /auth/login`) means anything, the
backend/ops owner must pick the v1 posture:

- **(a) Stay on dev-bypass for a closed beta.** Then Ask 2 below is a
  no-op — the FE's JWT-paste fallback ships the dev-token as a bearer
  and the deploy works as-is. FE will document the "your token is the
  one Coolify shows you" flow.
- **(b) Local username/password store.** BE-008 lands `POST /auth/login`
  with a real password verifier (argon2, bcrypt) against a `users`
  table; FE keeps its current `signInWithCredentials` flow. This is
  ~1 day of backend work + a migration.
- **(c) External OIDC issuer.** The compose file already wires four
  `OIDC_*` env vars; flipping `DEV_AUTH_BYPASS=false` and providing them
  routes auth through JWKS verification. FE then needs an OIDC flow
  (out-of-scope for the current login pack) — the username/password
  form would be replaced or supplemented by an "Sign in with
  <provider>" button. This is ~1 week of FE work to retrofit.

The frontend team is **blocked on this product call** before sizing
Ask 2.

Acceptance: backend/ops replies with the picked posture (a/b/c). FE
re-files Ask 2 with the right shape based on the answer.

---

## Ask 2 — `POST /api/v1/auth/login` shipped (BE-008) *(P0 — depends on Ask 1)*

Status: `done` — PR #3 merged as `77fe74a`; redeploy `senj72y8` shipped with `DEV_AUTH_BYPASS=false` (Coolify env flipped). Live acceptance gate verified against `https://api.coolify.stolworthy.co`:

- `POST /auth/login {"username":"dev","password":"dev"}` → **200** `{"token":"HTpN8l4STZqonE_4mFEqymse0LB6ZZC-y4m7f4FIAu4","expires_at":"2026-06-16T..."}` (43-char base64url-no-pad token, 30-day TTL).
- `GET /me` with that bearer → **200** returning the seeded dev user (`issuer="dev"`, `external_id="dev-user"`, the existing UUID `6eb64609-...`).
- `POST /auth/login {"username":"dev","password":"WRONG"}` → **401**.
- `POST /auth/login {"username":"ghost","password":"x"}` → **401**.

Implementation notes:

- Tokens are opaque (32 random bytes base64url-no-pad, sha256-hex hashed at rest in `local_auth_tokens`). Sliding-window TTL refreshed on each authed call.
- Schema: `users_local_auth` + `local_auth_tokens`, both `ON DELETE CASCADE` from `users(id)`. Migration `0007_local_auth.sql`.
- argon2id with `Argon2::default()` (m=19456, t=2, p=1) — OWASP 2023 minimum.
- Backend select: `LOSEIT_AUTH_BACKEND=local|jwks` (default `local`); `DEV_AUTH_BYPASS=true` still wins as escape hatch. JWKS path untouched for future OIDC swap.
- Production safety: `main.rs` hard-fails on startup if `RUST_ENV=production` and `LOSEIT_SEED_DEV_AUTH=true` together — operator must unset the seed flag before flipping `RUST_ENV` to production.
- Design + task breakdown: `server/specs/be_auth_login_design.md`, `server/specs/be_auth_login_tasks.md`. 26 new tests (208 workspace total).
- `LoginResponse.expires_at` is required on the wire (FE design §10 noted this could go optional — flipped to required since the handler always emits it).

**Frontend follow-up (user directive, 2026-05-17):** Ask 1 picked (b)
local-creds, so this ask transitions from "no-op-for-now" to "ship
BE-008 in full." Wire shape (concrete contract — please don't deviate
without checking with FE):

- **Request**: `POST /api/v1/auth/login` with JSON body
  `{"username": string, "password": string}`. `security: []` on the
  route (the request itself carries no bearer; success returns one).
- **Response 200**: `{"token": string, "expires_at": string (optional, ISO 8601)}`.
  `token` is opaque to the FE — pass it back as `Authorization: Bearer <token>`
  on subsequent calls.
- **Response 401**: standard `Error` body for bad credentials. FE
  renders this inline under the password field via
  `BadCredentialsError` (already wired in `auth_token.dart:158-167`).
- **Architect refinements (2026-05-17 follow-up review)** — three
  concrete shapes the original ask left open:

  **(a) Separate `users_local_auth` table.** Keep the OIDC invariant
  on `users` clean — local-creds is a second authentication method,
  not a property of the person. Mixing nullable `username` /
  `password_hash` columns into `users` muddies the existing
  `UNIQUE(issuer, external_id)` invariant and creates dead columns
  for OIDC-only users:
  ```sql
  CREATE TABLE users_local_auth (
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    username    TEXT NOT NULL UNIQUE CHECK (username = lower(username)),
    password_hash TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id)
  );
  ```
  Newly-created local accounts get `users.issuer = 'local'` +
  `users.external_id = <username>` (so the existing
  `UNIQUE(issuer, external_id)` invariant on `users` stays
  meaningful). The seeded dev row preserves
  `users.issuer = 'dev'` so existing dev-bypass middleware identity
  remains stable.

  **(b) Opaque token table, not JWT.** Gives revocation for free
  (DELETE row on logout / breach), no key-rotation drift against the
  existing JWKS path, and no refresh-token rotation story to design
  yet (architect §10.7 defers refresh to v1.1+):
  ```sql
  CREATE TABLE auth_tokens (
    token_hash  TEXT PRIMARY KEY,         -- sha256(token), hex-encoded
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ                -- optional; null = no expiry
  );
  ```
  Generate the token as 32 random bytes base64url-encoded (entropy
  source for the token itself; no JWT claim parsing). Hash with
  sha256 at rest. Auth middleware's local-token path becomes a
  single `SELECT user_id FROM auth_tokens WHERE token_hash =
  sha256_hex($bearer)` (parallel with JWKS / dev-bypass branches).

  **(c) Idempotent seed.** Guard with `ON CONFLICT DO NOTHING` so
  re-running migrations stays safe under all conditions.

- **Password hashing**: argon2id, default parameters from `argon2`
  crate (`Argon2::default()` = `m=19456, t=2, p=1`, OWASP 2023
  minimum — architect-approved). Constant-time verify via the crate.
- **Seed (idempotent)**: one `users_local_auth` row for the dev
  user, `ON CONFLICT DO NOTHING`:
  - `username`: `dev`
  - `password`: `dev`
  - `password_hash`: argon2id(`'dev'`)
  - `user_id`: the same UUID the dev-bypass identity binds to
    (`users.issuer='dev'`, `users.external_id='dev-user'`).
  Production safety comes from `DEV_AUTH_BYPASS=false` shipping as
  the prod default + the existing `config.rs` refusal to start with
  `DEV_AUTH_BYPASS=true` under `RUST_ENV=production`. The
  `dev`/`dev` seed is local-dev ergonomics only.
- **Bypass flag**: `DEV_AUTH_BYPASS` env var defaults to `false`
  in `compose.coolify.yaml`. Existing `dev-token` keeps working
  *only* when `DEV_AUTH_BYPASS=true` is explicitly set (local dev /
  CI smoke). Production deploy flips it off.

**Acceptance** (FE will verify against `https://api.coolify.stolworthy.co`):
- `curl -X POST -H 'Content-Type: application/json'
  -d '{"username":"dev","password":"dev"}' https://api.coolify.stolworthy.co/api/v1/auth/login`
  returns 200 + `{"token":"..."}`.
- `curl -H "Authorization: Bearer <returned token>" https://api.coolify.stolworthy.co/api/v1/me`
  returns the dev user.
- `curl -X POST ... -d '{"username":"dev","password":"WRONG"}' .../auth/login`
  returns 401.
- The OpenAPI spec gains the `/auth/login` route under `security: []`.
- `DEV_AUTH_BYPASS=true` keeps the existing static-token fallback
  alive for local dev / CI smoke tests.

**Backend reply:** no route to ship while we're on dev-bypass. The FE's
`signInWithCredentials` should bypass the request and present the
dev-bypass token directly. Re-file this ask if Ask 1 is revisited and
lands on (b).

If Ask 1 lands on **(b)** local-creds, this is the BE-008 ticket in
`server/specs/backend_tickets_ledger.md` — ship the route. Wire shape:
request `{username: string, password: string}`, response
`{token: string, expires_at?: string}` on 200, `401` with `Error` body
on bad creds. `security: []` on the route.

If Ask 1 lands on **(a)** dev-bypass or **(c)** OIDC, the FE's
`signInWithCredentials` call site is wrong and needs to change
client-side instead. We'll re-write this ask under the right shape
once Ask 1 closes.

Acceptance: per BE-008 wire spec, once Ask 1 is settled and shape (b)
is picked.

---

## Ask 3 — Permissive CORS stays through v1 *(P2 — confirmation only)*

Status: `done` — confirmed

**Backend reply:** permissive stays through v1. `CorsLayer::permissive()`
at `server/crates/loseit-api/src/server.rs:133` is the contract — echoes
the request `Origin` and allows `Authorization`. No code change. With
the FQDN split actually shipped (distinct `api.` and `app.` subdomains),
this *does* matter for the web client — the browser will issue
cross-origin requests app → api. The current permissive layer handles
it; we'll tighten to an allowlist once the deploy hostnames stabilize.

The server's `CorsLayer::permissive()` in
`server/crates/loseit-api/src/server.rs:133` already echoes the request
origin and allows `Authorization`. FE wants a one-line confirmation
that permissive stays through v1. If `deploy_tasks.md`'s shape (a) gets
picked (single-FQDN proxy, same origin for web + api), CORS is moot for
web; the mobile client sends no `Origin` header either, so this only
matters for separate-FQDN deploys.

Acceptance: backend replies "permissive stays, confirmed" and moves to
Done. No code change.

---

## Ask 4 — `User` schema: declare `weight_unit` / `height_unit` *(P2 — multi-day work)*

Status: `done` — see PR #2 (draft, awaiting review)

**Backend reply (2026-05-17, overnight pipeline complete):** landed on
branch `be-user-units` as PR #2, draft — not merged to `main`. Seven
commits implementing BE-001 + BE-004 as a single combined effort:
migration 0006 (`weight_unit` + `height_unit`, named CHECK constraints,
defaults `'kg'` + `'cm'`); domain enums (`WeightUnit { Kg | Lb | St }`,
`HeightUnit { Cm | FtIn }`); Pg repo + in-memory fake; `/me` handler
exposes the fields on `User` and accepts them on `ProfilePatch` with
parse-to-enum-or-400 validation; OpenAPI delta declaring both as
required on `User` and optional on `ProfilePatch`; 12 new tests across
the core, in-memory, and HTTP layers (defaults, round-trip,
unknown-value 400, **unknown-key 200 regression**); full suite is 119
green. Architect-confirmed answer on the unknown-keys question: today's
`ProfilePatchBody` silently ignores unknown JSON keys (no
`#[serde(deny_unknown_fields)]`); recommendation in the PR is to keep
that behavior. Will move to Done section once merged.

The client tolerates missing keys on `GET /me` and defaults
`weight_unit=kg`, `height_unit=cm`. Today the OpenAPI `User` schema
declares neither (`server/specs/openapi.yaml:858-884`). Once the
user-preference work lands (BE-001 + BE-004 in the ledger), please
update `openapi.yaml` `User` to declare both as required string enums
and add them to `ProfilePatch`. Architect note: this is migration +
handler + spec work, not a one-line spec edit — keep the priority P2
but treat as multi-day when sized.

Cross-ref: BE-001 (`weight_unit`) + BE-004 (`height_unit`) in
`server/specs/backend_tickets_ledger.md`.

Acceptance: `User` carries `weight_unit: "kg"|"lb"|"st"` and
`height_unit: "cm"|"ft_in"` as required fields; `ProfilePatch` accepts
both as optional. Migration backfills existing rows with `kg` + `cm`
defaults.

---

## Ask 5 — Merge PR #2 (`be-user-units`) to `main` ASAP *(P0 — unblocks FE wire)*

Status: `done` — merged as `c3905a2`, deploy triggered

**Backend reply (2026-05-17, overnight loop, acting on user directive
re-opening Ask 1):** PR #2 marked ready and merged to `main` via the
standard GitHub merge commit (`c3905a2`). Coolify deploy triggered for
the merged main; running container should expose `User.weight_unit` +
`User.height_unit` on `GET /me` within ~5 min of this reply. Branch
`be-user-units` deleted on the remote.

**Frontend ask (2026-05-17):** PR #2 is currently in draft on
`be-user-units` and not on `main`. The FE is about to wire every
repository to the live API (see Ask 6 — happening overnight). The
`Profile` repo will read `User.weight_unit` / `User.height_unit` —
those fields don't exist on the deployed binary today, so the FE
either ships a tolerant decode (default to `kg`/`cm` when absent) or
waits for the merge. Tolerant decode is what the FE already does for
mock fixtures, so this isn't a hard blocker — but the cleaner path is
to merge the PR and have the FE codegen-equivalent assume the fields
are present.

Acceptance: PR #2 merged to `main`, deploy rebuilt against the merged
binary, `curl -H 'Authorization: Bearer dev-token'
https://api.coolify.stolworthy.co/api/v1/me` returns `weight_unit` +
`height_unit` keys.

---

## Ask 6 — FE wires every repository to the live API *(informational — FE owns this)*

Status: `fe-in-progress` (not a backend ask — listed here so the
backend team sees what's coming over the wire tonight)

**Frontend in-progress (2026-05-17):** the client repositories under
`client/lib/repositories/*.dart` are currently mock-only — they hold
an `ApiClient _api` field marked `// ignore: unused_field — kept for
parity with the eventual real client` and return seeded fixtures.
Wiring them to the live API is the FE half of "real data on the
deploy." All 22 routes in `openapi.yaml` get exercised. No backend
change expected; this entry exists so the backend team:

- Watches `https://api.coolify.stolworthy.co/api/v1/*` for unexpected
  4xx/5xx spikes once the wire goes live (the e2e Playwright suite
  exercises a subset; the deployed Flutter web bundle will exercise
  the full surface as users navigate).
- Flags any wire-shape drift between the FE's decoder and the actual
  server response in this file (new ask if so).

Touchpoints (each tracked as a separate commit on FE side):
- `ProfileRepository` ↔ `GET /me` + `PATCH /me`.
- `WeightRepository` ↔ `GET/POST/PATCH/DELETE /weights[/{id}]`.
- `GoalRepository` ↔ `GET/POST/PATCH/DELETE /goals[/active|/{id}]`.
- `LogRepository` ↔ `GET/POST/PATCH/DELETE /log[/quick_add|/copy|/{id}]`
  + `GET /days/{date}/summary`.
- `FoodRepository` ↔ `GET /foods/search`, `/foods/mine`,
  `/foods/recent`, `/foods/frequent`, `/foods/barcode/{barcode}`,
  `/foods/{id}`, `POST /foods`, plus `/foods/{id}/servings` +
  `/servings/{id}[/default]`.

**Watch-outs (backend architect, 2026-05-17 — flagged here so the FE
agents wiring the repos see them):**

1. **Pagination envelope is `{results, total, limit, offset}`** —
   `total` is the full-population count, not the page size. "Load
   more" logic must advance `offset += results.length`, not
   `offset += limit`, because the server clamps `limit` above 500.
2. **`POST /log/copy` wraps its array as `{copied: [...]}`** — a
   different envelope shape from `GET /log`'s `{results, total, ...}`.
   Easy to miss in the decoder.
3. **No idempotency keys on writes (yet).** POSTs to `/log`,
   `/log/quick_add`, `/weights`, `/goals` will double-write on
   retry. FE should debounce client-side; an `Idempotency-Key`
   header is on the v1.1 backlog.
4. **`POST /log/quick_add` auto-provisions** a sentinel "quick-add"
   food on first use per user. First call may be measurably slower
   than subsequent calls — not a bug.

---

## Ask 7 — Live-deploy bugs found while wiring repos *(P1)*

Status: `done` — PR #4 merged as `157b8e3`; redeploy `rcguognl` live. All three sub-asks verified against `https://api.coolify.stolworthy.co`:

- **7a**: `POST /log/copy {"from_date":"2026-05-17","to_date":"2026-05-18"}` returns **201** with the populated `{"copied": [LogEntry, ...]}` envelope (was 500). Root cause: an inline SQL `--` comment in `loseit-db/src/log_repo.rs:463` joined into a single line by Rust `\` line-continuation, making Postgres treat the rest of `create_many`'s SQL as a comment (`syntax error at end of input`). One-line fix + substring regression test + a sweep of every `--` in `loseit-db/src/` (T01+T02) confirms no other instances; policy note added at `loseit-db/src/lib.rs`.
- **7b**: closed as docs — added prose to the OpenAPI `POST /foods/{food_id}/servings` op and `FoodDetail.servings` explaining the canonical read path is `GET /foods/{id}` (T08).
- **7c**: chose option (i) — `Food.kind: 'normal' | 'quick_add'` enum, required on `FoodDetail`. Migration `0008_food_kind.sql` adds the column with default `'normal'` and backfills existing per-user sentinel rows to `'quick_add'`. Verified live: `POST /log/quick_add` → captured `food_id` → `GET /foods/{food_id}` returns `"kind": "quick_add"`. The FE flips its `entry.foodId == quickAddFoodId` check to `food.kind == 'quick_add'` at its own pace — fully additive.

Design + task breakdown: `server/specs/be_live_deploy_fixes_design.md`, `server/specs/be_live_deploy_fixes_tasks.md`. 8 commits (T01–T08), all green at each step. `FoodSearchHitResponse` intentionally omits `kind` (sentinel is stripped at search time — see design §4.4).

The FE wired all 5 repos to the live API and curl'd every endpoint
during the wire. Three reproducible bugs against
`https://api.coolify.stolworthy.co`:

### Ask 7a — `POST /api/v1/log/copy` returns 500

Reproduces with and without `meal`, with real entries on the source
day:
```bash
curl -X POST -H "Authorization: Bearer dev-token" \
  -H "Content-Type: application/json" \
  -d '{"from_date":"2026-05-17","to_date":"2026-05-18"}' \
  https://api.coolify.stolworthy.co/api/v1/log/copy
# → 500 {"code":"internal_error"}
```
Spec is clean. The FE wire is correct against the documented
contract (FE sends `{from_date, to_date, meal?}` and decodes the
`{copied: [LogEntry]}` envelope). Server bug.

### Ask 7b — `GET /api/v1/foods/{food_id}/servings` returns 405

Not mounted on the deploy:
```bash
curl -H "Authorization: Bearer dev-token" \
  "https://api.coolify.stolworthy.co/api/v1/foods/<some-food-id>/servings"
# → 405 Method Not Allowed (only POST mounted at that path)
```
The OpenAPI spec also doesn't define this read endpoint, so the FE
dropped it — servings come for free on `GET /foods/{id}`. Either
mount the GET, or add a note to the spec explaining its absence.
**Low priority** — FE works without it.

### Ask 7c — `POST /log/quick_add` returns a real food UUID, not the FE's `quickAddFoodId` sentinel

```bash
curl -X POST -H "Authorization: Bearer dev-token" \
  -H "Content-Type: application/json" \
  -d '{"calories_kcal":"100","meal":"snack","consumed_on":"2026-05-17"}' \
  https://api.coolify.stolworthy.co/api/v1/log/quick_add
# → 200 {"food_id":"62e720fd-...","serving_id":"...",...}
```
The FE has a hard-coded `quickAddFoodId` constant (e.g.
`'food_quick_add'`) it uses to identify quick-add entries client-side
— specifically to route the "Edit" action on a quick-add row to the
quick-add editor sheet instead of the canonical food-entry sheet.
With the server returning a real UUID per quick-add row, the FE's
`entry.foodId == quickAddFoodId` check (used in
`client/lib/features/today/today_internals.dart` and
`client/lib/features/today/widgets/meal_section.dart`) never fires
for live entries.

Backend, please pick one of:
- **(i)** Mark the auto-provisioned sentinel food with a flag (e.g.
  `Food.source == 'quick_add'` or a new `Food.kind = 'quick_add'`
  field) so the FE can detect quick-add entries by introspecting the
  food row instead of by ID equality. This is the cleaner long-term
  shape — FE picks up the flag and the existing ID-equality check
  becomes a flag-check.
- **(ii)** Return a stable, well-known UUID (e.g. all-zeros
  `00000000-0000-0000-0000-000000000000`) for the per-user quick-add
  sentinel food. FE updates the `quickAddFoodId` constant to match.

(i) is preferred — it's the shape that survives multi-tenant
deployments without UUID coordination. (ii) is the patch if (i) is
non-trivial.

---

## Ask 8 — Authentik / OIDC integration + provider-discovery endpoint *(P0 — user directive 2026-05-17)*

Status: `open`

**Frontend ask (user directive):** the deployed app should support OIDC
sign-in via Authentik. Per the user: "Ask the backend to create an
integration with Authentik and to expose a method for the frontend to
learn about the configured OIDC providers. Then, once the backend has
successfully integrated with Authentik, update the login page to show
a button for each OIDC provider enabled for the server."

The login pack already shipped `/auth/login` for local-creds (BE-008,
Ask 2). OIDC was deferred to v1.1 in Ask 1 — this ask reopens it for
v1. The architecture must support **multiple auth methods coexisting
on the same deploy**: dev-bypass (local dev), local-creds (existing
v1 ship), and one-or-more OIDC providers.

### Sub-asks

**8a — Authentik blueprint** *(P0)*

Create an Authentik **blueprint** (declarative YAML at
`/blueprints/instances/fulfilled.yaml` in the Authentik instance, or
mounted via the Authentik container's blueprints volume) that
provisions:
- An OAuth2/OpenID provider for "Fulfilled" with:
  - `client_id` and `client_secret` (the latter exposed to the
    backend only — never to the FE)
  - Redirect URIs that match both the dev (`http://localhost:8080/...`)
    and prod (`https://api.coolify.stolworthy.co/api/v1/auth/oidc/callback`,
    or the equivalent for FE-side OIDC if you pick that shape — see
    architectural choice below)
  - Scopes: `openid`, `profile`, `email`
  - Signing alg: `RS256` (Authentik's default; matches the existing
    `JwksAuthenticator` path)
- An Authentik application bound to the provider, named "Fulfilled."
- A test user (e.g. `dev@stolworthy.co` / strong password set out-of-
  band) for end-to-end verification.

Check the result of `curl https://<authentik>/application/o/fulfilled/.well-known/openid-configuration`
returns the OIDC discovery doc with `authorization_endpoint`,
`token_endpoint`, `jwks_uri`, etc.

**8b — Register OIDC provider with the Coolify api service** *(P0)*

Wire the api service (Coolify env vars) to use the Authentik issuer
as an *additional* auth backend (do NOT remove the local-creds path —
both should coexist):
- `OIDC_ISSUER=https://<authentik-host>/application/o/fulfilled/`
- `OIDC_AUDIENCE=<the client_id from blueprint 8a>`
- `OIDC_JWKS_URL=https://<authentik-host>/application/o/fulfilled/jwks/`
- For server-as-RP shape (see 8c), also: `OIDC_CLIENT_SECRET=<from 8a>`
  and `OIDC_REDIRECT_URI=<the callback URL>`.

Today the existing `LOSEIT_AUTH_BACKEND=jwks` mode is a *replacement*
for local-creds. That has to change — both must coexist. The
`AuthConfig` enum needs a `Multi { local: Option<LocalConfig>,
oidc: Vec<OidcProviderConfig> }` shape, or equivalent. The compose
default keeps local-creds on; the Coolify deploy adds Authentik on
top via the env vars.

**8c — Architectural choice: who is the OIDC relying party?** *(P0 — gates 8d/8e)*

Two shapes, pick one in your reply:

- **(i) Backend-as-RP (server-side flow).** Most secure. FE has only
  a button per provider; the button hits
  `GET /api/v1/auth/oidc/<provider>/start`; backend 302 → Authentik
  authorize URL; Authentik 302 → backend callback
  `/api/v1/auth/oidc/<provider>/callback?code=...`; backend exchanges
  the code for tokens, verifies the ID token, ensures a local `users`
  row exists (issuer=`authentik`, external_id=`<sub>`), mints an
  opaque token (same shape as BE-008), and 302s the browser to a FE
  URL (e.g. `https://app.coolify.stolworthy.co/login/callback?token=<opaque>`).
  FE picks the token off the query string and stores it.
  **Pros:** client_secret stays server-side; opaque-token model
  matches BE-008. **Cons:** more BE work (one route start + one
  callback per provider + PKCE state management).

- **(ii) Frontend-as-RP with PKCE (browser-side flow).** FE redirects
  directly to Authentik with PKCE; FE handles callback in-browser;
  FE sends the Authentik ID token to backend's
  `POST /api/v1/auth/oidc/<provider>/exchange`; backend verifies via
  JWKS, mints an opaque token, returns it. **Pros:** simpler backend
  (extend existing JWKS verifier; no callback hosting). **Cons:**
  FE rebuild needed for redirect URI changes; client_secret can't be
  used; only PKCE.

**Backend, pick one in your reply.** FE prefers (i) for the
opaque-token consistency and less Flutter web complexity — but will
implement either.

**8d — Provider-discovery endpoint** *(P0)*

Expose `GET /api/v1/auth/providers` (or `GET /api/v1/auth/config` —
your call on the URL) returning the list of configured auth
providers + their UI metadata. Suggested shape:

```json
{
  "local": {"enabled": true},
  "oidc": [
    {
      "id": "authentik",
      "display_name": "Authentik",
      "icon": null,
      "start_url": "/api/v1/auth/oidc/authentik/start"  // (i) only
      // OR for (ii):
      // "authorization_endpoint": "https://<authentik>/application/o/authorize/",
      // "client_id": "<client_id>",
      // "scopes": ["openid","profile","email"]
    }
  ]
}
```

`security: []` on this endpoint — the FE calls it before the user is
signed in.

Acceptance:
```bash
curl https://api.coolify.stolworthy.co/api/v1/auth/providers
# → 200 with the JSON above, listing `authentik` as one OIDC provider
```

**8e — OpenAPI delta** *(P1)*

Add the new routes (`/auth/providers`, `/auth/oidc/<provider>/start`
+ `/callback` if shape (i)) to `openapi.yaml`.

### Acceptance (end-to-end against the deploy)

1. `curl https://api.coolify.stolworthy.co/api/v1/auth/providers`
   returns a JSON with `local.enabled = true` and `oidc[0].id = "authentik"`.
2. Hitting the FE login page shows a primary "Sign in with Authentik"
   button alongside the existing username/password form.
3. Tapping the button completes the OIDC flow end-to-end: user lands
   on Authentik's login page, signs in with the test user, gets
   redirected back to the FE, and ends up at `/today` with real data
   from `/me` populated from the Authentik identity.
4. The local-creds flow (`dev`/`dev` against `/auth/login`) continues
   to work — both auth paths coexist on the same deploy.

### Notify

**Please notify FE (by flipping this ask's Status to `done` + posting
a `Backend reply:` paragraph here) when:**
- The Authentik blueprint is applied and the provider's
  `.well-known/openid-configuration` is reachable.
- The Coolify api service has been redeployed with the OIDC env vars.
- `/auth/providers` returns the expected JSON.
- The architectural choice (i) vs (ii) is settled (so FE knows
  whether to expect `start_url` redirect-based buttons or
  in-browser PKCE flow).

FE will then immediately wire the login page's per-provider button
rendering against the discovery endpoint.

---

## Done / Acknowledged

*(Backend team: move tasks here once shipped or rejected. Include a
one-line note on the resolution.)*

- *(empty)*
