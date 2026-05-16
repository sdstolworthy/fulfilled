# Deploying LoseIt on Coolify

This repo is set up to deploy as a two-service Docker Compose application on Coolify v4. The compose file lives at `compose.coolify.yaml` at the repo root.

## What gets deployed

| Service | Built from | Public? | Purpose |
|---|---|---|---|
| `api` | `server/Dockerfile` | Yes (Coolify-assigned FQDN) | Rust HTTP server (`loseit-api`) on `:8080`, migrations applied on boot. |
| `web` | `client/Dockerfile` | Yes (separate Coolify-assigned FQDN) | Flutter web build served by nginx on `:80`. SPA routing wired in. |

Postgres is **external** to this compose — see "Database" below.

## One-time Coolify setup

1. **Create a new Application** in Coolify, source = this Git repo, branch = `main`.
2. **Deployment type**: Docker Compose.
3. **Compose file path**: `compose.coolify.yaml`.
4. Coolify will auto-detect the two services and assign each a default FQDN. Override the FQDNs in the UI (one for the API, one for the web client). Two subdomains of the same root domain works well — for example `api.example.com` and `app.example.com`.

## Environment variables

Set these in Coolify's UI (Application → Environment Variables). Anything marked **secret** should be flagged accordingly so it doesn't appear in build logs.

### Required

| Variable | Where | Notes |
|---|---|---|
| `DATABASE_URL` | api | **Secret.** Postgres connection string. e.g. `postgres://user:pass@host:5432/loseit`. |
| `API_BASE_URL` | web | The api service's public URL plus `/api/v1`. e.g. `https://api.example.com/api/v1`. Baked in at build time. |

### Required only when switching off dev-bypass auth

| Variable | Notes |
|---|---|
| `DEV_AUTH_BYPASS` | Set to `false` once OIDC is configured. |
| `OIDC_ISSUER` | The `iss` claim your idP issues, exactly. e.g. `https://example.us.auth0.com/`. |
| `OIDC_AUDIENCE` | The `aud` your idP signs for this API. |
| `OIDC_JWKS_URL` | The well-known JWKS endpoint, e.g. `https://example.us.auth0.com/.well-known/jwks.json`. |
| `OIDC_JWKS_CACHE_TTL_SECS` | Optional; defaults to `600`. |

### Optional overrides

| Variable | Default | Notes |
|---|---|---|
| `RUST_ENV` | `staging` | Set to `production` once OIDC is on. The server refuses to boot in `production` if dev-bypass is still enabled. |
| `RUST_LOG` | `info,tower_http=info,sqlx=warn` | Tracing filter. |
| `DEV_AUTH_TOKEN` | `dev-token` | The bearer token clients present while dev-bypass is on. **Rotate** before exposing the FQDN publicly. |
| `DEV_AUTH_ISSUER` | `dev` | Synthetic issuer for the dev identity. |
| `DEV_AUTH_USER_ID` | `dev-user` | Synthetic external id; the user row provisioned on first request. |
| `DEV_AUTH_EMAIL` | `dev@example.com` | Optional. |
| `DEV_AUTH_DISPLAY_NAME` | `Dev User` | Optional. |

## Database

External Postgres only. Two reasonable choices:

1. **Coolify-managed Postgres resource.** Spin up a Postgres database as a separate resource in Coolify, copy the connection string into the `DATABASE_URL` secret above.
2. **Bring your own Postgres.** Any Postgres 14+ reachable from Coolify works. Make sure the role has `CREATE` privilege on the target database so `sqlx::migrate!` can run.

The application applies migrations on boot when `LOSEIT_RUN_MIGRATIONS=true` (default in the compose). If you'd rather apply migrations manually, override that to `false` and run them out-of-band.

### Two-database future split

The product direction is to eventually split into two Postgres databases:

- **Foods DB** — the open-food-facts catalogue plus quality-score derivatives. Read-mostly, large, regeneratable from upstream parquet dumps via `loseit-ingest`. Portable across deployments.
- **User DB** — proprietary per-user data (profiles, goals, logs, weights, custom foods). The thing that needs backups, GDPR controls, and migration discipline.

The current schema is single-database. The split will require:

- A second `Pool<Postgres>` in the composition root.
- Repository traits routed to whichever pool owns their tables (`FoodRepository` → foods DB; everything else → user DB).
- Two `DATABASE_URL_FOODS` / `DATABASE_URL_USERS` env vars in the compose.
- A migration directory per database.

Not in this deployment. Open a ticket when the split lands.

## Deploy flow

1. Push to `main`. The GitHub Actions workflow at `.github/workflows/docker.yml` continues to build and push images to the Gitea registry; **Coolify ignores that image** and builds from source per the user's chosen deploy mode (see "Image source" decision in repo notes). If you later flip to pulling the prebuilt image, replace the `build:` block in `compose.coolify.yaml` with `image: git.stolworthy.co/sdstolworthy/fulfilled:latest` for the `api` service.
2. Trigger a Coolify deploy (manual button, webhook, or auto-on-push).
3. Coolify clones the repo, runs `docker compose build` against `compose.coolify.yaml`, brings the stack up behind Traefik with the assigned FQDNs.
4. Health checks:
   - `GET https://<api-fqdn>/api/v1/health` → `{"status":"ok"}`
   - `GET https://<web-fqdn>/health.txt` → `ok`

## Switching from dev-bypass to OIDC

While dev-bypass is on, anyone with `DEV_AUTH_TOKEN` is fully authenticated as the configured dev user. That's only acceptable while the URL is private. To flip:

1. Provision your idP (Auth0, Cognito, Keycloak, Apple/Google — anything that publishes a JWKS endpoint).
2. Set the four `OIDC_*` env vars in Coolify, plus `DEV_AUTH_BYPASS=false`.
3. Optionally set `RUST_ENV=production` to make the dev-bypass refusal absolute (the server will fail to boot if you ever accidentally re-enable dev-bypass alongside production).
4. Redeploy. Health endpoint returns 200 publicly; every other endpoint now requires a valid bearer token from your idP.
5. Update the Flutter client's sign-in flow (FE-11 in `server/specs/v1_finishup_frontend_tasks.md`).

## Rolling back

Coolify's UI keeps recent deployments. The migration story is forward-only — the application calls `sqlx::migrate!` on boot, which fails closed if a migration can't apply. If you need to roll back code that depended on a new column, you'll want to either:

- Tag and pin the previous image in `compose.coolify.yaml` and redeploy, or
- Use Coolify's "Rollback to previous deployment" button and accept that the schema stays at the newer revision.

There is no automated `down` migration; new columns are left in place across a rollback.

## Logs and debugging

- `docker logs loseit-api` (via the Coolify container view) → tracing output filtered by `RUST_LOG`.
- Database queries log at `sqlx=warn` by default; bump to `sqlx=debug` temporarily for query-level visibility.
- The Flutter client's `API_BASE_URL` is baked in — if the web service is calling the wrong host, check the build args in Coolify, not the runtime env.
