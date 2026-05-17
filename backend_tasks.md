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

**Deploy context (2026-05-16).** First production-style deploy at
`https://app.coolify.stolworthy.co/`. The Flutter web bundle resolves
`apiBaseUrl` from `Uri.base.origin + '/api/v1'`
(`client/lib/providers/api_base_url_provider.dart`), so a browser
hitting the web FQDN issues every API call to that same FQDN under
`/api/v1/*`. **Currently unreachable** (TLS handshake failure on HTTPS,
Cloudflare 503 on HTTP) — until the deploy proxy is reachable, items
below cannot be validated end-to-end. See `deploy_tasks.md` for the
infra side.

---

## Ask 1 — Decide auth posture for the deploy: dev-bypass vs OIDC vs local-creds *(P0 — gates Ask 2)*

Status: `open`

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

Status: `blocked-on-ask-1`

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

Status: `open` (no code change expected)

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

Status: `open`

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
