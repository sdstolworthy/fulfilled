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

Status: `done` — PR #5 merged as `24898c1`. Backend-as-RP OIDC code flow with PKCE, signed-cookie state, and one-time handoff-code ferry to the FE. Multi-method `AuthConfig` so local-creds (BE-008) and OIDC coexist. Live on `https://api.coolify.stolworthy.co`.

**Backend reply — FE action items:**

1. **Call `GET /api/v1/auth/providers` before rendering the login screen** (`security: []`, no bearer). Today returns:
   ```json
   {
     "local": {"enabled": true},
     "oidc": [{"id":"authentik","display_name":"Authentik","icon_url":"","start_url":"/api/v1/auth/oidc/authentik/start"}]
   }
   ```
   - Render the username/password form only when `local.enabled === true`.
   - For each entry in `oidc`, render a button labelled `display_name` (icon optional). Tap → navigate the browser to `start_url` (relative; prepend `https://api.coolify.stolworthy.co`). **Plain anchor + native navigation** — no fetch/XHR. Reason: the backend needs to set an `HttpOnly` cookie and 302 to Authentik; only a top-level navigation will follow.

2. **Handle the callback landing.** After Authentik signs the user in, the backend redirects the browser to `<LOSEIT_FE_ORIGIN>/<next>?oidc_code=<43-char-base64url>`. On the FE side:
   - At app boot (or on the login route), if the URL has `?oidc_code=<...>`, immediately:
     ```
     POST /api/v1/auth/oidc/exchange
       body: {"code": "<the oidc_code from URL>"}
       → 200 {token: string, expires_at: ISO-8601}   # same shape as /auth/login
       → 401 if the handoff code is missing, expired (60s TTL), or already claimed
     ```
   - Store the returned `token` as the bearer (same as the local-creds flow), strip `?oidc_code=` from the URL, and route to wherever `?next=` pointed (today the start handler embeds it; the FE drops the qs after exchange).
   - On 401, surface "OIDC sign-in failed, please try again" and return the user to `/login`.

3. **Error path** — if Authentik denied consent or the user cancelled, the callback redirects with `?oidc_error=<authentik error code>` instead of `?oidc_code=`. Read it and show an inline error; no exchange call needed.

4. **`next` query param** — the FE can pass `next=/today` (or any same-origin path) to `start_url` to control the post-sign-in landing page. Default is `/`. Anything outside `LOSEIT_FE_ORIGIN` returns 400 at `/start`.

5. **No change to the rest of the API surface.** The token returned by `/auth/oidc/exchange` round-trips identically to a `/auth/login` token — same `Authorization: Bearer <token>` header, same expiry semantics, same revocation. `GET /me` works identically; user row's `issuer="authentik"`, `external_id=<sub from ID token>`.

**Live verification (backend gates passing as of 2026-05-17 ~06:00 PDT):**

- `GET /auth/providers` → 200 with the JSON above.
- `GET /auth/oidc/authentik/start?next=/today` → 302 to `https://authentik.stolworthy.co/application/o/authorize/?response_type=code&client_id=...&redirect_uri=...&scope=openid+profile+email&state=...&nonce=...&code_challenge=...&code_challenge_method=S256` + `set-cookie: loseit_oidc_state=...; HttpOnly; SameSite=Lax; Path=/api/v1/auth/oidc; Max-Age=600`.
- Local-creds `POST /auth/login` with `dev/dev` still returns 200 + bearer (BE-008 path unaffected).
- `POST /auth/oidc/exchange` with a bogus code returns 401.

**What FE still needs to test (cannot simulate via curl):** the full Authentik consent → callback → exchange → /me round trip with a real account. The Authentik test user is whichever account you've already provisioned in the `authentik.stolworthy.co` realm; the Fulfilled application is now visible there.

**Two known follow-ups for daylight, NOT blockers tonight:**

- `/auth/login` should be gated on `state.local_login_enabled` so disabling local-creds via env actually disables it (today it's only gated on `state.auth.is_some()`; inert because `LOSEIT_AUTH_LOCAL=true`).
- The `env::var(...).unwrap_or_else(|_| default)` pattern in `config.rs::load_oidc_provider` doesn't filter empty strings, so Coolify-style `${VAR:-}` empty expansions skip the default. Already bit us on `OIDC_AUTHENTIK_JWKS_URL` and `OIDC_AUTHENTIK_SCOPES` (both set explicitly in Coolify env as workaround). Fix is one-line: `.ok().filter(|s| !s.is_empty())` on each of the four URL/scope vars.

Design + task breakdown: `server/specs/be_oidc_integration_design.md`, `server/specs/be_oidc_integration_tasks.md`. 15 task commits (T01-T15) + spec commits, 245 tests passing workspace-wide.

### Architect refinements (2026-05-17)

**Read these first — they override the per-sub-ask language below
where they conflict.** Sizing estimate: ~20-24h focused BE work, 3
days. Don't gold-plate refresh-token rotation or multi-IdP-per-user
account linking — both deferred to v1.1.

1. **8a — Drop the in-repo blueprint.** Architect: "Authentik
   instance schemas drift across versions; an Authentik blueprint
   YAML in our repo creates a coupling we don't want, and our repo
   would imply we operate the IdP." User writes the provider +
   application in Authentik's UI (5 clicks). Backend only needs:
   `issuer URL`, `client_id`, `client_secret`. Confirm RS256 (already
   matches `JwksAuthenticator`'s `ALLOWED_ALGS` whitelist at
   `auth/jwks.rs:42-48`).

2. **8b — `AuthConfig` becomes a struct, not an enum.** Architect's
   preferred shape:
   ```rust
   struct AuthConfig {
     dev_bypass: Option<DevBypassConfig>,
     local: Option<LocalConfig>,
     oidc: Vec<OidcProviderConfig>,
   }
   ```
   `load_auth()` validates "at least one method configured" + "no
   `dev_bypass` in production." The "exactly one mode" invariant of
   the old flat enum is what's being killed — that's the point.
   - `state.auth: Option<Arc<AuthService>>` **stays single** — OIDC
     mints opaque tokens via the same `AuthService` (one shared token
     table = one revocation surface; the code-exchange path just
     bypasses the password verify).
   - Add `state.oidc: HashMap<String, Arc<OidcProvider>>` keyed by
     provider id (`"authentik"`) for per-provider start/callback
     handlers.

3. **8c — PKCE mandatory, signed-cookie state, handoff-code ferry.**
   - PKCE required even for confidential client (RFC 9700 / OAuth 2.1
     BCP, Jan 2025).
   - State management: HMAC-signed cookie carrying `{provider_id,
     code_verifier, return_to, expires_at}` —
     `HttpOnly; Secure; SameSite=Lax; Max-Age=600`. **Not** redis,
     **not** in-memory. New env var `LOSEIT_AUTH_STATE_SECRET` (32
     bytes, required when any OIDC provider is configured).
   - **Token ferry**: do NOT put the opaque token in the redirect
     URL (browser history leak). Instead: backend issues a one-time
     **handoff code** in the redirect to FE
     (`?code=<one-time-handoff>`); FE then `POST /api/v1/auth/oidc/exchange
     {code}` → real opaque token. New table `oidc_handoff_codes`
     with 60s TTL. Adds one route + one migration but cleans up the
     security story.

4. **8d — Drop `available: bool`.** Architect: "If a provider is in
   config, it's reachable — or `build_authenticator` fails at
   startup (existing invariant from `server.rs:186-192`). Health-of-
   IdP is not the discovery endpoint's job." `icon` stays
   `null | string` (absolute URL); FE falls back to a generic OIDC
   glyph.

5. **8e — OpenAPI: add `/auth/oidc/exchange`** (POST,
   `security: []`) alongside the other new routes.

### Backend deliverables (consolidated post-review)

- `/api/v1/auth/providers` — public discovery endpoint
- `/api/v1/auth/oidc/{provider}/start` — 302 to IdP (signs state
  cookie, builds authorize URL with PKCE challenge)
- `/api/v1/auth/oidc/{provider}/callback` — 302 to FE with handoff
  code (verifies state cookie, exchanges code+verifier with IdP for
  ID token, verifies via JWKS, ensures local `users` row exists with
  `issuer='authentik'` + `external_id=<sub>`, mints handoff code)
- `/api/v1/auth/oidc/exchange` — POST `{code}` → opaque token
- Migration: `oidc_handoff_codes(code_hash, user_id, expires_at,
  created_at)`
- Env: `LOSEIT_AUTH_STATE_SECRET`, plus existing
  `OIDC_ISSUER`/`OIDC_AUDIENCE`/`OIDC_JWKS_URL` per-provider.
  Multi-provider config: `OIDC_PROVIDERS=authentik` env var listing
  ids; each id reads `OIDC_<ID>_ISSUER` etc. (architect's call on
  exact env-var shape).
- OpenAPI delta.
- `AuthConfig` struct refactor.

### FE deliverables (queued — kicks off when 8d goes live)

- `GET /auth/providers` consumer + DTO.
- `OidcButton` widget (one per provider in the discovery doc).
- Login screen renders the OIDC button list above the credentials
  form when `oidc` is non-empty.
- `/login/callback?code=<handoff>` route handler that calls
  `POST /auth/oidc/exchange`, stores the returned opaque token via
  `signIn(token)`, navigates to `/today`.

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

## Ask 9 — Denormalize `food_name` + `serving_name` on `/log` responses *(P0 — user-visible bug on the deploy tonight)*

Status: `done` — PR #6 merged as `3f7c88f`; deploy `p2dxx1on6e2p1ppukashop43` live. Verified against `https://api.coolify.stolworthy.co/api/v1/log?from=2026-05-17&to=2026-05-18`:

```json
{
  "results": [{
    "food_name": "apple apple",
    "serving_name": "1 pouch (90 g)",
    "consumed_on": "2026-05-18",
    ...
  }]
}
```

**FE action items:**

- Drop the `FoodRepository._cache` + `LogRepository.entriesForDate` prefetch stopgap (from `399e73e`). The wire now carries `food_name` directly; the FE decoder can read it without an extra round-trip. Keep the cache + prefetch as a defensive fallback for orphan rows / older server versions if you want, but it's no longer load-bearing.
- `food_name` is **required** on every `LogEntry` wire row (server-side FK invariant via `ON DELETE RESTRICT` from `food_log_entries.food_id` → `foods.id`).
- `serving_name` is **nullable** — null when `serving_id` is null (the wire row's `serving_id` is also null in that case) AND when the food has no servings. Quick-add entries currently DO have a `serving_id` (sentinel "kcal" serving), so `serving_name` is non-null there; tested live and confirmed.

**Implementation summary:**

- Migration: none — `food_name` lives in `foods` table already; only the wire response shape changed.
- Pg repo: every SELECT now `LEFT JOIN foods f ON f.id = le.food_id LEFT JOIN servings s ON s.id = le.serving_id`, with `COALESCE(f.name, '') AS food_name` and `s.label AS serving_name`. INSERT/UPDATE/INSERT-many `RETURNING` paths can't take a JOIN, so they return `id` and follow up with `find_by_id` / `list_by_ids` (one extra round-trip per write; per design §4 R2).
- In-memory fake: injects `Arc<InMemoryFoodRepository>` + `Arc<InMemoryServingRepository>` via setters; resolves names at read time on every `FoodLogEntry`-producing path. Existing tests unchanged (no-op when repos aren't wired).
- OpenAPI `LogEntry` schema gains `food_name: string` (required) + `serving_name: { type: [string, null] }` (optional).
- 4 task commits (T01–T04), 2 new HTTP test cases, full workspace green.

Design + task breakdown: `server/specs/be_log_denorm_design.md`.

User reports: "The name of the foods that are added to the registry are
not appearing." Confirmed live — the wire response from
`GET /log?from=&to=` and `GET /days/{date}/summary` carries no
`food_name` or `serving_name` keys:

```bash
curl -H "Authorization: Bearer <tok>" \
  "https://api.coolify.stolworthy.co/api/v1/log?from=2026-05-17&to=2026-05-17" | jq '.results[0]'
# → {id, food_id, serving_id, consumed_on, meal, quantity, grams_total,
#    calories_kcal, protein_g, ..., note, created_at, updated_at}
#   (no food_name, no serving_name)
```

The FE rows render an empty string because the client decoder
(`client/lib/domain/log_entry.dart:95`) falls back to `''` when the
key is absent. The Food name lives one extra fetch away
(`GET /foods/{food_id}`), but that's an N+1 problem for a day view
with multiple entries.

**The shape FE wants** — denormalize:

```diff
 results: [
   {
     "id": "...",
     "food_id": "96348e60-...",
+    "food_name": "Tomato paste",
     "serving_id": "a6ed31a1-...",
+    "serving_name": "100 g",
     ...
   }
 ]
```

Same denormalization on `GET /days/{date}/summary` (the response's
embedded `entries` array). Yes it's repetition; it eliminates N
round-trips per day-view render. This is the standard "DTO has
everything the row needs" pattern.

**FE is shipping a stopgap tonight** — a foods cache + per-entry
join via `FoodRepository.byId` — so the deployed app shows food
names while you ship this. Once Ask 9 lands the FE drops the cache
and uses the denormalized field directly.

### Acceptance

`curl https://api.coolify.stolworthy.co/api/v1/log?...` returns
`food_name` (and `serving_name` when `serving_id` is set) on each
result. Same for `/days/{date}/summary`. OpenAPI `LogEntry` schema
updated with both fields (`food_name` required, `serving_name`
optional).

---

## Ask 10 — Per-serving nutrition + unit families + flatten migrations + USDA/OFF ingest normalizer *(P0 — user directive 2026-05-17)*

Status: `done (server)` — backend pipeline shipped on `main` (T01–T16, commits `7847bd3` → `a871704`). **Not yet deployed** — see "Deploy precondition" below. Full ask body also at `ask_10_per_serving_nutrition.md`.

### Backend reply

**Workspace test count:** 290 passing, 0 failing, 1 ignored. Up from 245 pre-reshape.

**Shipped (16 task commits on `main`):**

- **T01** flatten 9 migrations → single `0001_initial.sql`. New `foods` (identity + metadata only, no `*_100g`), new `servings` (`{amount, unit, kcal, protein_g..., is_default, source, sort_order}` — `label` nullable), new `food_log_entries` (`entered_amount`, `entered_unit`, snapshot nutrition, no `grams_total`).
- **T02** `Unit` enum (12 variants) + `UnitFamily` (Mass | Volume | Count) + `ratio_to_canonical` in `loseit-core::domain::unit`. Decimal-typed ratio table. No cross-family conversion ever.
- **T03–T07** repo trait + Pg + in-memory rewrite: `create_custom_with_servings`, `update_custom_with_servings`, `upsert_external_food_batch(Vec<FoodDraftWithServings>)`, `find_or_create_quick_add` returns `(Food, Serving)`.
- **T08** `LogService::create` implements within-family conversion + cross-family/Count-strict guards; snapshot is `quantity × serving.<nutrient>`. `FoodService::create_custom` enforces ≥1 serving + ≤1 default; **synthesized-default-100g-serving deleted**.
- **T09+T10** route DTOs: `POST /foods` body takes `servings: [ServingBody]`; `POST /log` takes `entered_amount` + `entered_unit` (no `quantity` in request — server-derived); `LogEntryResponse` carries `entered_amount` + `entered_unit` AND `quantity` (FE keeps stepper math). `unit_family_mismatch` maps to HTTP 400 with body `{code: "unit_family_mismatch", ...}`.
- **T11** OpenAPI delta: drops `NutritionPer100g`; adds `Unit` enum schema; reshapes `Food*`/`Serving*`/`Log*`; documents the new error code.
- **T12+T13** HTTP test rewrites: 30 cases in `http_foods` + 50 in `http_log` (incl. the within-family conversion check: 4 fl_oz / 1 cup → quantity 0.500, kcal 100).
- **T14–T16** ingest pipeline: `OffSource` + `UsdaSource` normalizers emit `FoodDraftWithServings` directly; `loseit-ingest` binary wires `run_off` + `run_usda`; 13 normalizer fixture tests; round-trip integration tests for 3-row OFF + 2-row USDA fixtures.

**Quick-add sentinel resolved as option (ii)**: `{amount: 1, unit: 'serving', kcal: 1.0, source: 'system', is_default: true}`. No new `Energy` family.

**Within-family ratios confirmed** (canonical mass=g, volume=ml, count=identity): `kg=1000`, `oz=28.349523125`, `lb=453.59237`, `l=1000`, `cup=236.5882365`, `fl_oz=29.5735295625`, `tbsp=14.78676478125`, `tsp=4.92892159375`. `serving ↔ piece` no auto-conversion.

### Deploy precondition (operator action required)

**The migration chain was flattened — the existing Coolify DB cannot apply the new `0001_initial.sql` against the old `_sqlx_migrations` table.** Per `COOLIFY.md` (added in T01), the operator must run ONE of:

- **Option A (recommended)** — drop + recreate the entire Postgres database (`DROP DATABASE loseit; CREATE DATABASE loseit;`). Clean slate. Loses all existing data, which the user explicitly OK'd.
- **Option B** — connect to the running Postgres, `DROP TABLE IF EXISTS _sqlx_migrations`, then redeploy. Leaves old rows in place that won't match the new schema — likely runtime errors. Don't pick unless inspecting the old data first.

After the reset, trigger a Coolify deploy. The new container will apply `0001_initial.sql` cleanly and the server will boot.

### FE deliverables (queued)

Per the ask's "FE deliverables" section — kicks off when the deploy is live and FE regenerates DTOs from the updated `openapi.yaml`. Specifically: drop the `FoodRepository._byIdCache` stopgap shipped under Ask 9 (the new wire shape preserves `food_name` denormalization).

### Daylight follow-ups (non-blocking)

- `_sqlx_migrations` reset has no automated path; runbook in `COOLIFY.md` is manual.
- `loseit-ingest --limit 1` smoke test against the deployed DB hasn't been run end-to-end (no live DB available at test time).

**User directive (2026-05-17, verbatim transcript paraphrase):**
custom-food creation today only accepts grams for serving size; users
can't enter volumetric servings. The model needs to change: trust the
user to enter a serving as
`{amount, unit, kcal-for-that-serving, macros-for-that-serving}` and
stop anchoring nutrition to per-100g mass. The system's job is to know
whether each unit is mass / volume / count so we can offer same-family
conversions at log time and at quantity entry. No densities, no
per-100g math.

User explicitly OK'd:

1. **Dropping all existing data.** No production traffic on the deploy
   — there's nothing to preserve.
2. **Flattening every migration (0001..0009) into a single new
   `0001_initial.sql`** that captures the new schema. No incremental
   migration; just rip and rewrite.
3. **Bundling the reshape with the USDA + OpenFoodFacts ingest work.**
   The ingest pipeline (`loseit-ingest`) will normalize external data
   against the new schema rather than the schema being shaped to the
   external sources.

---

## Scope (the entire backend reshape — sized as multi-week)

### 10a — Schema reshape

Replace `migrations/0001_initial.sql` (and delete 0002..0009) with a
single migration that includes:

- **`foods` table** — drop all `*_100g` columns:
  ```
  energy_kcal_100g, protein_100g, carbs_100g, fat_100g,
  fiber_100g, sugar_100g, sodium_100g, saturated_fat_100g
  ```
  Foods are now identity + metadata only (name, brands, barcode,
  source, owner, categories, quality_score, nutriscore_grade, kind,
  created/updated). Nutrition lives on the serving.

- **`servings` table** — replace `grams: NUMERIC` with structured
  units + per-serving nutrition:
  ```sql
  CREATE TABLE servings (
      id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      food_id         UUID NOT NULL REFERENCES foods(id) ON DELETE CASCADE,

      label           TEXT,                  -- nullable; FE/user-supplied descriptor

      amount          NUMERIC(10,3) NOT NULL CHECK (amount > 0),
      unit            TEXT NOT NULL CHECK (unit IN (
                          -- mass
                          'g', 'kg', 'oz', 'lb',
                          -- volume
                          'ml', 'l', 'cup', 'fl_oz', 'tbsp', 'tsp',
                          -- count
                          'serving', 'piece'
                      )),

      kcal            NUMERIC(8,2) NOT NULL CHECK (kcal >= 0),
      protein_g       NUMERIC(8,2)         CHECK (protein_g IS NULL OR protein_g >= 0),
      carbs_g         NUMERIC(8,2)         CHECK (carbs_g   IS NULL OR carbs_g   >= 0),
      fat_g           NUMERIC(8,2)         CHECK (fat_g     IS NULL OR fat_g     >= 0),
      fiber_g         NUMERIC(8,2)         CHECK (fiber_g   IS NULL OR fiber_g   >= 0),
      sugar_g         NUMERIC(8,2)         CHECK (sugar_g   IS NULL OR sugar_g   >= 0),
      sodium_mg       NUMERIC(8,2)         CHECK (sodium_mg IS NULL OR sodium_mg >= 0),
      saturated_fat_g NUMERIC(8,2)         CHECK (saturated_fat_g IS NULL OR saturated_fat_g >= 0),

      is_default      BOOLEAN NOT NULL DEFAULT false,
      source          TEXT    NOT NULL CHECK (source IN ('off','usda','user','system')),
      sort_order      INT     NOT NULL DEFAULT 0,

      created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  ```
  Keep the partial-unique `servings_one_default_per_food` index.

  Architect's call: `kcal` is the only **required** nutrient field on a
  serving — protein/carbs/fat/etc are nullable because user-entered
  data is often incomplete and we don't want to force the FE to invent
  zeros. The FE renders missing macros as "—", not "0 g."

- **`food_log_entries` table** — keep the snapshot pattern (nutrition
  columns stay on log rows, recorded at write time), but **drop
  `grams_total`** and **add `entered_amount: NUMERIC` +
  `entered_unit: TEXT`** so the log row preserves *exactly what the
  user typed at entry time* even if they later edit or delete the
  serving. Snapshot semantics: nutrition is computed as
  `quantity * serving.<nutrient>` at write time (no gram-anchor math).

  ```sql
  CREATE TABLE food_log_entries (
      ...
      quantity        NUMERIC(8,3) NOT NULL CHECK (quantity > 0),

      -- What the user picked at entry time (denormalized for editing).
      entered_amount  NUMERIC(10,3) NOT NULL CHECK (entered_amount > 0),
      entered_unit    TEXT NOT NULL,         -- same enum as servings.unit

      -- Snapshot: quantity * serving.<nutrient> at write time.
      calories_kcal   NUMERIC(8,2) NOT NULL,
      protein_g       NUMERIC(8,2),
      carbs_g         NUMERIC(8,2),
      fat_g           NUMERIC(8,2),
      fiber_g         NUMERIC(8,2),
      sugar_g         NUMERIC(8,2),
      sodium_mg       NUMERIC(8,2),
      saturated_fat_g NUMERIC(8,2),
      ...
  );
  ```

- **Unit families** — declared in the Rust code
  (`loseit-core::domain::serving::UnitFamily { Mass, Volume, Count }`),
  not in the database. The CHECK constraint above is the only DB-level
  guard. Conversion ratios within a family live in code as constants.
  **No cross-family conversion ever** — a "1 cup" serving cannot be
  entered as grams unless the user adds a separate gram-based serving
  themselves.

  Canonical within-family ratios (architect: confirm or amend):
  - **Mass** (canonical: `g`): `kg=1000`, `oz=28.349523125`,
    `lb=453.59237`.
  - **Volume** (canonical: `ml`): `l=1000`, `cup=236.5882365`,
    `fl_oz=29.5735295625`, `tbsp=14.78676478125`,
    `tsp=4.92892159375`.
  - **Count** (canonical: itself): no cross-unit conversion;
    `serving` ↔ `piece` cannot be converted automatically — they're
    treated as separate units within the same family for display
    purposes only.

- **Quick-add sentinel** — re-implement on top of the new schema.
  **Architect, please pick:**
  - **Option (i)** add `'kcal'` as a thirteenth unit (its own `Energy`
    family), only valid on the quick-add sentinel food.
  - **Option (ii)** model quick-add as
    `{amount: 1, unit: 'serving', kcal: <user-entered>}`. Cleaner —
    avoids a new family. **FE recommendation.**

- **Preserve `users`, `users_local_auth`, `auth_tokens` (or
  `local_auth_tokens` — match current naming), `oidc_handoff_codes`,
  `food_import_batches`, `weights`, `goals`** verbatim from current
  migrations. The reshape is scoped to `foods` + `servings` +
  `food_log_entries`.

### 10b — Domain + repo + API DTO reshape (Rust)

- `loseit-core::domain::food::Food` — drop `nutrition_per_100g`, drop
  the `NutritionPer100g` struct entirely.
- `loseit-core::domain::serving::Serving` — gains `amount`,
  `unit: Unit`, `kcal`, `protein_g`, etc. Drops `grams`.
- New `loseit-core::domain::unit::{Unit, UnitFamily}` enums with
  `family()` accessor and `ratio_to_canonical()` for within-family
  conversions (canonical = grams for mass, ml for volume, 1 for
  count).
- `FoodCreate` body:
  `{name, brand?, barcode?, servings: [ServingCreate]}` where
  `ServingCreate = {label?, amount, unit, kcal, protein_g?, carbs_g?,
  fat_g?, fiber_g?, sugar_g?, sodium_mg?, saturated_fat_g?,
  is_default?}`. **At least one serving required.** No top-level
  nutrition.
- `FoodPatch`: same shape; `nutrition_per_100g` field removed;
  `servings` patch list works as today (full-list replace).
- `LogEntryCreate` / `LogEntryPatch`: drop `grams_total`; add
  `entered_amount`, `entered_unit`. `serving_id` stays required (every
  log entry references a serving). Cross-family entries are rejected
  with a 400 (e.g. mass-only serving + `entered_unit='cup'`).
- Pg repo + in-memory fake: full rewrite of the foods + servings + log
  paths against the new schema. **`loseit-db/src/{food,serving,log}_repo.rs`
  are getting redrawn.**

### 10c — OpenAPI delta

- Remove `NutritionPer100g` schema.
- `Food` schema: drop `nutrition_per_100g`; `servings: [Serving]`
  becomes required (was already there).
- `Serving` schema: gains `amount: number`, `unit: string-enum`,
  `kcal: number`, `protein_g: number | null`, etc.; loses `grams`.
- `LogEntry` schema: drops `grams_total`; adds `entered_amount:
  number`, `entered_unit: string-enum`.
- `FoodCreate` / `FoodPatch` / `ServingCreate` / `LogEntryCreate` /
  `LogEntryPatch` — all updated.
- Add a `Unit` enum schema referenced from `Serving.unit`,
  `LogEntry.entered_unit`, `ServingCreate.unit`, etc.

### 10d — Ingest pipeline (`loseit-ingest`)

- **OpenFoodFacts** — for each OFF row:
  - Parse `serving_size` (string like `"30 g"`, `"100 ml"`, `"1 cup
    (240 ml)"`) into `{amount, unit}`. Maintain a parser table for the
    canonical units list above. Drop rows where:
    1. `serving_size` is unparseable AND no `energy-kcal_100g` field
       is present, OR
    2. all per-100g nutrition fields are missing.
  - **Synthesize at least one serving per food:**
    - If `serving_size` parsed → emit a serving with that amount +
      unit + the OFF per-serving nutrition (computed from per-100g ×
      serving-grams when OFF provides only per-100g).
    - Always also emit a `{100, 'g'}` serving when OFF provides
      per-100g nutrition — gives users the "by weight" entry point
      even when the product's listed serving is volumetric.
    - Mark the canonical / parsed-from-OFF serving as
      `is_default = true` (the `{100, 'g'}` companion is non-default).
  - Drop OFF rows where the per-100g nutrition AND serving-level
    nutrition are both unavailable — they aren't useful in the new
    model.

- **USDA Foundation Foods** — for each USDA food:
  - Iterate `foodPortions[]`. Each has `gramWeight` + a `measureUnit`
    (text like `"cup"`, `"tablespoon"`, `"piece"`). Map measureUnit to
    our `Unit` enum where possible (`tablespoon` → `tbsp`, `fluid
    ounce` → `fl_oz`, etc.); fall back to a `{<gramWeight>, 'g'}`
    serving when the measureUnit doesn't map.
  - Compute per-serving nutrition by `nutrient_per_100g × gramWeight /
    100`.
  - Emit one `servings` row per USDA portion. Mark the first portion
    (lowest `sequenceNumber`) as `is_default`.

- Both pipelines respect the FK invariant that **every food has ≥ 1
  serving**. A food with zero parseable portions is dropped, not
  stored with an empty serving list.

### 10e — Tests

Workspace test count today: 245 (per Ask 8). The reshape will rewrite
~all foods/servings/log tests. Acceptance:

- `loseit-core` unit tests cover unit-family classification,
  within-family conversion ratios, and the "no cross-family
  conversion" guard.
- `loseit-db` integration tests cover round-trip of `Food` + `Serving`
  + `FoodLogEntry` against pg + in-memory.
- HTTP-level tests cover `POST /foods` with `{name, servings:
  [{amount: 1, unit: 'cup', kcal: 200}]}`, `POST /log` referencing a
  volumetric serving, `GET /log` returning the new `entered_amount` +
  `entered_unit` keys, **and** `POST /log` with `entered_unit`
  cross-family to the serving returns 400.
- `loseit-ingest` tests cover OFF + USDA normalizers on fixtures from
  each source.

---

## Non-goals (out of scope for Ask 10)

- **Refresh tokens / token rotation** — still v1.1.
- **Idempotency keys** — still v1.1.
- **Mobile OIDC** — still v1.1.
- **Density-based cross-family conversion** ("user typed cups but I
  want to display grams") — explicitly rejected by user. Not
  happening.
- **Multi-unit serving display** (a serving simultaneously showing "1
  cup / 240 ml / 8 fl oz") — that's the **FE's** job at render time,
  using `UnitFamily` + the in-code ratio table. Backend just stores
  `{amount, unit}` as the user / source recorded it.

---

## Acceptance (against `https://api.coolify.stolworthy.co`)

```bash
# 1. POST a custom food with a volumetric serving + per-serving nutrition.
curl -X POST -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test smoothie",
    "servings": [
      {"label": "1 cup", "amount": "1", "unit": "cup", "kcal": "180",
       "protein_g": "5", "carbs_g": "30", "fat_g": "4", "is_default": true}
    ]
  }' \
  https://api.coolify.stolworthy.co/api/v1/foods
# → 201 { food with one serving, amount=1, unit='cup', kcal=180 }

# 2. POST a log entry referencing the volumetric serving with a different
#    same-family unit (system scales within volume family).
curl -X POST ... -d '{
  "food_id": "<id>",
  "serving_id": "<serving_id>",
  "consumed_on": "2026-05-17",
  "meal": "snack",
  "quantity": "0.5",                       # 0.5 × 1 cup = 0.5 cup
  "entered_amount": "4",
  "entered_unit": "fl_oz"                  # 4 fl oz = 0.5 cup (within volume family)
}' .../log
# → 201 { entry with calories_kcal=90 (0.5 × 180) }

# 3. POST a cross-family log entry — rejected.
curl -X POST ... -d '{
  "food_id": "<id>",
  "serving_id": "<volumetric serving_id>",
  ...
  "entered_unit": "g"                      # mass unit on a volume-family serving
}' .../log
# → 400 { code: "unit_family_mismatch", ... }

# 4. GET /foods/{id} no longer carries `nutrition_per_100g`; carries servings only.
curl ... /foods/<id> | jq 'has("nutrition_per_100g")'
# → false
curl ... /foods/<id> | jq '.servings[0] | has("amount") and has("unit") and has("kcal")'
# → true

# 5. /log row carries `entered_amount` + `entered_unit`.
curl ... "/log?from=2026-05-17&to=2026-05-17" | jq '.results[0] | has("entered_amount") and has("entered_unit")'
# → true
```

---

## FE deliverables (queued — kicks off when 10c lands)

- `Serving` domain: drop `grams`, add `amount: Decimal`, `unit: Unit`,
  per-serving nutrition fields.
- `Food` domain: drop `nutritionPer100g`.
- `CustomFoodScreen` / `servings_section.dart`: replace the single
  "Grams" stepper with `{amount stepper + unit dropdown + kcal stepper
  + macros}`. Per-serving nutrition entry per row. Drops the top-level
  `NutritionSection` entirely.
- `LogEntrySheet`: unit toggle within the selected serving's family
  (mass-only servings show g/oz/lb/kg; volume-only show
  ml/l/cup/fl_oz/tbsp/tsp; count shows just the count unit).
- `UnitFamily` enum + within-family conversion table (mirror of the
  Rust side).
- All decoders updated for new wire shape.
- Drop the `FoodRepository._byIdCache` + `prefetchByIds` stopgap
  shipped under Ask 9 — names already denormalized; the new shape
  doesn't re-introduce missing-data issues.

---

## Notify

Please notify FE (status flip + `Backend reply:` paragraph in this
file **or** in `backend_tasks.md`) when:

- 10a + 10b + 10c are landed on `main` and the deploy serves the new
  shape.
- 10d (ingest) is wired and OFF + USDA fixtures pass.
- The OpenAPI spec at `server/specs/openapi.yaml` reflects the new
  shape (FE regenerates DTOs from it).

FE will then start the corresponding client-side reshape; expect ~3-5
days of FE rewrites to track the new server shape.


---

## Done / Acknowledged

*(Backend team: move tasks here once shipped or rejected. Include a
one-line note on the resolution.)*

- *(empty)*
