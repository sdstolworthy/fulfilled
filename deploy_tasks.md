# Deploy / ops tasks (frontend → ops owner)

Asks from the frontend team to whoever owns the Coolify / Cloudflare /
Traefik deployment. These are infra/config items the backend Rust server
has no lever over — the API itself is healthy on `:8080`; the gap is
between Cloudflare → Coolify → the api container.

**Reply by editing this file in place** — flip the `Status` line, add a
`Ops reply:` paragraph under the task, move finished items to **Done**
at the bottom.

**Deploy context (2026-05-17 — Tasks 1+2+3 RESOLVED).** Both
`app.coolify.stolworthy.co` (web) and `api.coolify.stolworthy.co`
(api) are live and TLS-valid. The deploy went with shape (b) —
separate FQDNs. Two new tasks below (4 + 5) need ops attention to
unblock real sign-in:

- **Task 4** — Coolify env var: set `API_BASE_URL` on the **web**
  service to the absolute api URL so the Flutter release build
  bakes the correct base URL (currently using the relative `/api/v1`
  default → resolves to wrong origin under shape (b)).
- **Task 5** — Coolify env var: set `DEV_AUTH_BYPASS=false` on the
  **api** service so the new `/auth/login` route mounts (BE-008
  shipped on `main` 2026-05-17 but gated out by the dev-bypass env
  var currently set in Coolify's UI).

---

## Task 1 — TLS cert for `app.coolify.stolworthy.co` *(P0 — DONE)*

Status: `done` — both `app.` and `api.` FQDNs serving valid TLS.

`curl -v https://app.coolify.stolworthy.co/` → TLS alert 552 (handshake
failure). Either the Cloudflare edge cert for this hostname isn't
provisioned (Cloudflare → SSL/TLS → Edge Certificates → check the
hostname is covered by the universal cert or a uploaded cert), or the
origin server's cert isn't trusted by Cloudflare when SSL mode is
"Full (strict)". Most likely cause: the Cloudflare zone has SSL set to
"Full (strict)" but the Coolify Traefik origin is presenting a
non-Cloudflare cert (or no cert).

Acceptance: `curl -v https://app.coolify.stolworthy.co/` completes a
TLS handshake without errors.

---

## Task 2 — Route `/api/v1/*` from the web FQDN to the `api` container *(P0)*

Status: `open` (backend architect recommends **shape (a)** — single FQDN)

Two acceptable shapes. **Architect strongly prefers (a)** — fewer moving
parts, no client rebuild, no CORS pinning.

### Shape (a) — single-FQDN reverse-proxy (RECOMMENDED)

Add Traefik labels to the `api` service in `compose.coolify.yaml` so
`https://app.coolify.stolworthy.co/api/v1/*` routes to the api
container's `:8080`. Coolify uses Traefik internally. Suggested labels
(verify exact syntax against the Coolify version running):

```yaml
  api:
    # ... existing config ...
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api-prefix.rule=Host(`app.coolify.stolworthy.co`) && PathPrefix(`/api/v1`)"
      - "traefik.http.routers.api-prefix.tls=true"
      - "traefik.http.routers.api-prefix.tls.certresolver=letsencrypt"
      - "traefik.http.routers.api-prefix.entrypoints=websecure"
      - "traefik.http.services.api-svc.loadbalancer.server.port=8080"
      - "traefik.http.routers.api-prefix.service=api-svc"
```

The `web` service keeps its existing FQDN routing — Traefik picks the
api-prefix router first when the path starts with `/api/v1`.

### Shape (b) — separate api FQDN

Expose the api container on `api.coolify.stolworthy.co` (or similar) and
rebuild the web image with `--build-arg
API_BASE_URL=https://api.coolify.stolworthy.co/api/v1`. Drags in DNS
fixes (`api.coolify.stolworthy.co` currently points at an OPNsense
firewall), CORS pinning, and a Flutter rebuild. **Not recommended.**

Acceptance:

- `curl https://app.coolify.stolworthy.co/api/v1/health` returns
  `{"status":"ok"}` with status `200`.
- `curl https://app.coolify.stolworthy.co/` returns the Flutter web
  HTML.

---

## Task 3 — DNS for `api.coolify.stolworthy.co` *(P1 — only if shape (b) is picked)*

Status: `open`

`api.coolify.stolworthy.co` currently presents a `CN=OPNsense.internal`
self-signed cert. The DNS record points at the wrong host. Only
load-bearing if Task 2 lands as shape (b); otherwise delete this
record or repoint it.

Acceptance: hostname resolves to the Coolify Traefik edge **or** is
removed from DNS.

---

## Task 4 — Set `API_BASE_URL` build-arg on Coolify web service *(P0 — blocks real-data on the deploy)*

Status: `done` — verified by curling the rebuilt `main.dart.js` from `https://app.coolify.stolworthy.co/main.dart.js`; the bundle has `https://api.coolify.stolworthy.co/api/v1` baked in. Coolify env var `API_BASE_URL` is set with `is_buildtime=true`, so the rebuild triggered alongside the BE-008 redeploy (uuid `senj72y8`) picked it up.

The Flutter web release build is gated on an **absolute** `API_BASE_URL`
dart-define value (per the LOG-001 amendment in commit
`c3ec9ae` — relative paths are skipped because Dio can't use them as a
base URL). The compose default is the relative `/api/v1`, which means
`apiBaseUrlProvider` falls through to rule 2 (`Uri.base.origin +
'/api/v1'`) which resolves to
`https://app.coolify.stolworthy.co/api/v1` — and that path is **not
served** under the shape-(b) deploy (the API lives at `api.`, not
`app.`).

**Action required** in Coolify's UI for the **web** service:

1. Open the web service in Coolify → Environment Variables (or "Build
   Args" depending on Coolify version — `API_BASE_URL` is consumed at
   *build time* by the web Dockerfile via `ARG API_BASE_URL`).
2. Set `API_BASE_URL=https://api.coolify.stolworthy.co/api/v1` (the
   absolute api URL).
3. Trigger a redeploy of the web service. Coolify needs to rebuild
   the docker image so the new dart-define value gets baked into the
   bundle.

Acceptance: after redeploy, opening `https://app.coolify.stolworthy.co/`
in a browser issues network requests to
`https://api.coolify.stolworthy.co/api/v1/*` (visible in DevTools
Network tab). Today it incorrectly requests
`https://app.coolify.stolworthy.co/api/v1/*`.

---

## Task 5 — Set `DEV_AUTH_BYPASS=false` on Coolify api service *(P0 — blocks real sign-in)*

Status: `done` — Coolify env patched via API at 09:28 UTC; redeploy `senj72y8` picked it up. Live acceptance gate (per Ask 2 in `backend_tasks.md`) passes — POST `/auth/login` with dev/dev returns 200 + 43-char opaque token; wrong-creds returns 401; bearer round-trips against `/me` returning the seeded dev user. **Preview environment** still has `DEV_AUTH_BYPASS=true` — left intact since it isn't reachable from the public deploy.

BE-008 shipped (`POST /api/v1/auth/login` route, local-creds auth,
opaque token table — see `backend_tickets_ledger.md` Ask 2). The
compose file defaults `DEV_AUTH_BYPASS=false` (commit `231b219` /
`a4a5ba2`). But the live deploy still returns `404` on `/api/v1/auth/login`
**because the api server's router conditionally mounts the route only
when `state.auth.is_some()`**, which is `None` under `DevBypass` mode
(`server/crates/loseit-api/src/server.rs:124-129`). The api container
must currently be running with `DEV_AUTH_BYPASS=true` set in Coolify's
UI environment variables (overriding the new compose default).

Verified live:
```bash
# /me with the static dev-token still works → DevBypass is active
curl -H "Authorization: Bearer dev-token" \
  https://api.coolify.stolworthy.co/api/v1/me
# → 200 (returns dev user)

# But /auth/login isn't mounted because state.auth.is_none() under DevBypass
curl -X POST -H "Content-Type: application/json" \
  -d '{"username":"dev","password":"dev"}' \
  https://api.coolify.stolworthy.co/api/v1/auth/login
# → 404
```

**Action required** in Coolify's UI for the **api** service:

1. Open the api service in Coolify → Environment Variables.
2. Either delete the `DEV_AUTH_BYPASS` row, or set it explicitly to
   `false`. (The compose default of `false` will pick up.)
3. Restart the api container (no rebuild needed — `DEV_AUTH_BYPASS` is
   a runtime env var, not a build-arg).
4. After restart: verify `curl -X POST -H "Content-Type: application/json"
   -d '{"username":"dev","password":"dev"}' https://api.coolify.stolworthy.co/api/v1/auth/login`
   returns `200 {"token": "...", "expires_at": "..."}`.

Acceptance: `/auth/login` returns 200 with dev/dev credentials. Bad
credentials return 401. The token round-trips on subsequent
`Authorization: Bearer <token>` requests against `/me`.

---

## Done

*(Move tasks here as they ship. Include a one-line note on the
resolution.)*

- *(empty)*
