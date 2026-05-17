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

### Auth — local credentials

| Variable | Default | Notes |
|---|---|---|
| `LOSEIT_AUTH_LOCAL` | `true` | Set to `false` to disable `POST /auth/login` (username + password). |
| `LOSEIT_SEED_DEV_AUTH` | `true` | Seeds the dev user row on boot when dev-bypass is active. |

### Auth — OIDC (Authentik or other provider)

| Variable | Default | Notes |
|---|---|---|
| `OIDC_PROVIDERS` | _(empty)_ | Comma-separated provider IDs. Set to `authentik` (or another slug) to enable OIDC. Empty = no OIDC. |
| `LOSEIT_AUTH_STATE_SECRET` | _(empty)_ | **Secret.** 32+ random bytes (base64 or hex). Required when `OIDC_PROVIDERS` is non-empty. Generate with `openssl rand -hex 32`. |
| `LOSEIT_FE_ORIGIN` | _(empty)_ | The frontend origin, e.g. `https://app.coolify.stolworthy.co`. Used to validate the `next` redirect parameter. |
| `OIDC_AUTHENTIK_DISPLAY_NAME` | `Authentik` | Button label on the sign-in page. |
| `OIDC_AUTHENTIK_ISSUER` | _(empty)_ | The `iss` claim, e.g. `https://auth.example.com/application/o/loseit/`. |
| `OIDC_AUTHENTIK_CLIENT_ID` | _(empty)_ | OAuth2 client ID from the Authentik application. |
| `OIDC_AUTHENTIK_CLIENT_SECRET` | _(empty)_ | **Secret.** OAuth2 client secret. |
| `OIDC_AUTHENTIK_REDIRECT_URI` | _(empty)_ | Must match the redirect URI configured in Authentik, e.g. `https://api.coolify.stolworthy.co/api/v1/auth/oidc/authentik/callback`. |
| `OIDC_AUTHENTIK_JWKS_URL` | _(empty)_ | JWKS endpoint, e.g. `https://auth.example.com/application/o/loseit/jwks/`. |
| `OIDC_AUTHENTIK_ICON_URL` | _(empty)_ | Optional URL to the provider logo shown on the sign-in button. |
| `OIDC_AUTHENTIK_SCOPES` | _(empty)_ | Space-separated scopes. Defaults to `openid profile email` if left empty. |

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

## Switching from dev-bypass to production auth

While dev-bypass is on, anyone with `DEV_AUTH_TOKEN` is fully authenticated as the configured dev user. That's only acceptable while the URL is private.

### Enabling local credentials (username + password)

`LOSEIT_AUTH_LOCAL` defaults to `true`. Local sign-in via `POST /api/v1/auth/login` works out of the box. Set to `false` to disable it.

### Adding Authentik (OIDC)

1. In Authentik, create a new OAuth2/OpenID Provider:
   - **Name**: LoseIt (or any label).
   - **Client type**: Confidential.
   - **Redirect URIs**: `https://<api-fqdn>/api/v1/auth/oidc/authentik/callback` (replace `<api-fqdn>` with your API service FQDN).
   - **Scopes**: `openid`, `profile`, `email`.
   - Note the **Client ID**, **Client Secret**, **Issuer URL**, and **JWKS URL** from the provider detail page.
2. In Coolify, set the following env vars on the `api` service:
   - `OIDC_PROVIDERS=authentik`
   - `LOSEIT_AUTH_STATE_SECRET` — generate with `openssl rand -hex 32`. **Mark as secret.**
   - `LOSEIT_FE_ORIGIN` — the frontend FQDN, e.g. `https://app.coolify.stolworthy.co`.
   - `OIDC_AUTHENTIK_ISSUER`, `OIDC_AUTHENTIK_CLIENT_ID`, `OIDC_AUTHENTIK_CLIENT_SECRET`, `OIDC_AUTHENTIK_REDIRECT_URI`, `OIDC_AUTHENTIK_JWKS_URL`.
3. Unset (or leave empty) the old removed vars: `LOSEIT_AUTH_BACKEND`, `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_JWKS_CACHE_TTL_SECS` — these are no longer read by the server.
4. Set `DEV_AUTH_BYPASS=false`.
5. Optionally set `RUST_ENV=production` to make dev-bypass refusal absolute (the server refuses to boot if dev-bypass is re-enabled in production mode).
6. Redeploy. `GET /api/v1/auth/providers` will now return both `local` and the Authentik OIDC entry.

Local credentials and OIDC can coexist — the FE renders the password form alongside the per-provider buttons based on the `/auth/providers` response.

## Ask 10 deploy — resetting the migration chain

Ask 10 (branch `be-per-serving-nutrition`) flattens migrations `0001..0009` into a
single new `0001_initial.sql`. Any existing database that has already applied some or
all of the old chain will have rows in `_sqlx_migrations` whose checksums differ from
the new file. The server will refuse to start until the tracking table is cleared.

**Option A — brand-new DB (recommended; there is no data worth keeping):**

```bash
psql $DATABASE_URL -c "DROP DATABASE loseit; CREATE DATABASE loseit;"
```

Then deploy normally. `sqlx migrate run` on boot will apply `0001_initial.sql` from
scratch.

**Option B — preserve the DB, clear sqlx's tracking table only:**

```bash
psql $DATABASE_URL -c "DROP TABLE IF EXISTS _sqlx_migrations;"
```

On the next boot, the server's `sqlx migrate run` reapplies `0001_initial.sql` from
scratch against the existing (now schema-mismatched) database. Only use this if you
have already dropped and recreated all application tables manually, otherwise the
migration will fail on `CREATE TABLE` conflicts.

Option A is simpler and correct for the Coolify staging environment where all data is
regeneratable.

---

## Rolling back

Coolify's UI keeps recent deployments. The migration story is forward-only — the application calls `sqlx::migrate!` on boot, which fails closed if a migration can't apply. If you need to roll back code that depended on a new column, you'll want to either:

- Tag and pin the previous image in `compose.coolify.yaml` and redeploy, or
- Use Coolify's "Rollback to previous deployment" button and accept that the schema stays at the newer revision.

There is no automated `down` migration; new columns are left in place across a rollback.

## Logs and debugging

- `docker logs loseit-api` (via the Coolify container view) → tracing output filtered by `RUST_LOG`.
- Database queries log at `sqlx=warn` by default; bump to `sqlx=debug` temporarily for query-level visibility.
- The Flutter client's `API_BASE_URL` is baked in — if the web service is calling the wrong host, check the build args in Coolify, not the runtime env.
