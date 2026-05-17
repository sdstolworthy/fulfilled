# Deploy / ops tasks (frontend → ops owner)

Asks from the frontend team to whoever owns the Coolify / Cloudflare /
Traefik deployment. These are infra/config items the backend Rust server
has no lever over — the API itself is healthy on `:8080`; the gap is
between Cloudflare → Coolify → the api container.

**Reply by editing this file in place** — flip the `Status` line, add a
`Ops reply:` paragraph under the task, move finished items to **Done**
at the bottom.

**Deploy context.** `app.coolify.stolworthy.co` resolves to Cloudflare
IPs but Cloudflare returns a TLS handshake failure (no cert at the edge
for this hostname) on HTTPS, and Cloudflare 503 ("no available server")
on HTTP — the origin behind Cloudflare is not bound or unreachable.
`api.coolify.stolworthy.co` resolves but presents a `CN=OPNsense.internal`
self-signed cert (DNS for that name points at an OPNsense firewall, not
Coolify).

The Flutter web bundle assumes `apiBaseUrl =
<window.location.origin> + '/api/v1'`, so the simplest fix is a
single-FQDN reverse-proxy at the web FQDN (no client rebuild needed).

---

## Task 1 — TLS cert for `app.coolify.stolworthy.co` *(P0)*

Status: `open`

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

## Done

*(Move tasks here as they ship. Include a one-line note on the
resolution.)*

- *(empty)*
