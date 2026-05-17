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

Status: `done` — picked **(a) dev-bypass for closed beta**

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

Status: `no-op-for-now` — Ask 1 picked (a) dev-bypass

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

## Done / Acknowledged

*(Backend team: move tasks here once shipped or rejected. Include a
one-line note on the resolution.)*

- *(empty)*
