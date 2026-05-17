# Fulfilled — End-to-End Tests

Hermetic E2E test suite for the Fulfilled stack (Rust + Axum API,
Flutter web client, Postgres). Tests bring up the full stack via
`compose.e2e.yaml`, drive a headless Chromium with Playwright, capture
screenshots for every UI state, and upload them as CI artifacts.

The suite does **not** touch the production deploy at
`app.coolify.stolworthy.co`. Every run is sandboxed: a throwaway
Postgres container, a dev-bypass auth token (`e2e-test-token`), and
images built fresh from the source tree.

---

## Tech stack — and why

**Playwright (TypeScript), headless Chromium.**

| Considered            | Why not                                                                                                          |
| --------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `flutter drive`       | Runs the Flutter app under a Dart VM, not a real browser. We deploy a web bundle; we should test the web bundle. |
| Cypress               | First-class browser, but its screenshot story and CI integration are heavier than Playwright's.                  |
| Raw curl + headless Chromium scripts | Works for smoke. Falls over the moment we need to interact with the UI. Re-implements 80% of Playwright. |
| Detox                 | Mobile-app E2E. Out of scope for v1 — see the v1.1 plan.                                                         |

Playwright wins because:

- `page.screenshot({ path, fullPage: true })` — one line. CI artifact upload is trivial.
- Headless Chromium handles Flutter's CanvasKit (WASM) renderer out of the box.
- `page.waitForFunction(() => document.querySelector('flt-glass-pane'))` is the canonical "Flutter is ready" poll, which we need because the bundle takes time to bootstrap.
- TypeScript means schema-shaped assertions on the API responses without a separate fixture format.

---

## Running locally

Prereqs: Docker (with the v2 `docker compose` plugin) and Node 20+.

```bash
# From /workplace/fulfilled/e2e/
# First run: `npm install` to generate a lockfile.
# Subsequent runs (after the lockfile is committed): `npm ci`.
npm install
npx playwright install --with-deps chromium

# Build images + start the stack. `--wait` blocks until every
# healthcheck reports healthy, so the next command can assume the
# stack is up.
docker compose -f compose.e2e.yaml up -d --wait --build

# Run the tests.
npm test

# Tear down (and wipe the Postgres volume).
docker compose -f compose.e2e.yaml down -v
```

Convenience scripts in `package.json`:

| Script              | Equivalent                                                       |
| ------------------- | ---------------------------------------------------------------- |
| `npm run stack:up`  | `docker compose -f compose.e2e.yaml up -d --wait --build`        |
| `npm test`          | `playwright test`                                                |
| `npm run test:ui`   | `playwright test --ui` (interactive watch mode)                  |
| `npm run stack:down`| `docker compose -f compose.e2e.yaml down -v`                     |

### Ports the stack publishes on the host

| Service | Host port | What you can do                                   |
| ------- | --------- | ------------------------------------------------- |
| `web`   | `:80`     | `open http://localhost/` — Flutter web bundle.    |
| `api`   | `:8080`   | `curl http://localhost:8080/api/v1/health`.       |
| `db`    | _(none)_  | Internal to the compose network. Use `docker compose exec db psql -U e2e e2e` if you need it. |

> If port 80 is in use on your host (or your OS forbids non-root binds),
> override the publish in `compose.e2e.yaml` to `8081:80` and set
> `E2E_BASE_URL=http://localhost:8081` before `npm test`. The Playwright
> config reads that env var.

### Auth contract

The api boots with `DEV_AUTH_BYPASS=true` and a static
`DEV_AUTH_TOKEN=e2e-test-token`. Any request that attaches
`Authorization: Bearer e2e-test-token` is auth-passed as the seeded
dev user (`e2e@example.com`, display name "E2E User"). Tests that
need to exercise authenticated routes attach that header directly via
Playwright's `request` fixture — no real OIDC dance.

---

## Where screenshots land

**Locally:** `e2e/screenshots/*.png`. The directory is git-tracked
(via `.gitkeep`) but the PNGs themselves are gitignored.

**In CI:** Same path. The `.github/workflows/e2e.yml` workflow uploads
the entire `e2e/screenshots/` directory plus the full
`e2e/playwright-report/` HTML report as a build artifact named
`e2e-screenshots`. Download from the GitHub Actions run page → Artifacts.

Naming convention:

| File             | What it captures                                            |
| ---------------- | ----------------------------------------------------------- |
| `01-home.png`    | First render at `/`. Verifies Flutter bootstraps.           |
| `02-login.png`   | `/onboarding/1` — the closest analog to a login screen today (no `/login` route is wired in v1). |
| `03-today.png`   | `/today` shell tab.                                         |
| `04-foods.png`   | `/foods` shell tab.                                         |
| `05-weight.png`  | `/weight` shell tab.                                        |
| `06-profile.png` | `/me` shell tab.                                            |
| `07-goals.png`   | `/goals` (sidebar-only on expanded; sub-tab of `/me` on compact). |
| `failure-*.png`  | Best-effort snapshot of whatever state the page was in when a test failed. Useful when an assertion fires mid-navigation. |

---

## When tests fail — debugging checklist

1. **Open the HTML report.** `npx playwright show-report` (local) or
   the `e2e-screenshots` CI artifact (look in `playwright-report/`).
   Playwright captures the network log, console, trace, and a screenshot
   for every failed test.

2. **Stack health.** Did the api come up? `docker compose -f
   compose.e2e.yaml ps` should show three services, all `healthy`.
   The most common local failure is a stale Postgres volume:
   `docker compose -f compose.e2e.yaml down -v` and retry.

3. **Migrations.** The api applies migrations on boot
   (`LOSEIT_RUN_MIGRATIONS=true`). If migrations fail, the api
   healthcheck never goes green and `docker compose up --wait` times
   out. `docker compose -f compose.e2e.yaml logs api` shows the cause.

4. **Flutter bootstrap timeout.** CanvasKit is ~3 MB of WASM and decodes
   on the main thread. On a cold CI runner first paint can be 5–10 s.
   If `waitForFlutter` times out (default 45 s), bump the per-call
   timeout in `tests/helpers.ts` rather than papering over with sleeps.

5. **Port 80 conflicts.** If `docker compose up` complains about port
   binding, something else on your host is on `:80`. Re-map per the
   "Ports" section above.

6. **Screenshots look blank / black.** The Flutter engine renders
   asynchronously after `flt-glass-pane` mounts. The helper waits one
   extra animation frame (500 ms) before snapping; if you're seeing
   pre-paint snaps, bump that pause in `tests/helpers.ts::waitForFlutter`.

---

## CI integration

Workflow file: [`.github/workflows/e2e.yml`](../.github/workflows/e2e.yml).

Triggers on `push`, `pull_request`, and `workflow_dispatch`. The job:

1. Checks out the repo.
2. Sets up Node 20.
3. `docker compose -f e2e/compose.e2e.yaml up -d --wait --build`.
4. `cd e2e && npm ci && npx playwright install --with-deps chromium && npm test`.
5. **Always**: uploads `e2e/screenshots/` and `e2e/playwright-report/`
   as the `e2e-screenshots` artifact.
6. **Always**: `docker compose -f e2e/compose.e2e.yaml down -v` to free
   the runner.

The `always()` guard on the artifact step means a failed test still
uploads screenshots — that's the primary feedback channel for review.

---

## Layout

```
e2e/
├── README.md                — this file
├── package.json             — Playwright + TypeScript deps and scripts
├── tsconfig.json            — TS compiler config for the test sources
├── playwright.config.ts     — projects, timeouts, reporter, baseURL
├── compose.e2e.yaml         — hermetic stack: db + api + web
├── nginx.e2e.conf           — web nginx override with /api/v1 reverse proxy
├── tests/
│   ├── helpers.ts           — Flutter readiness poll, screenshot helpers
│   ├── smoke.spec.ts        — direct API smoke (/health, /me, proxy)
│   ├── web_render.spec.ts   — Flutter web bootstrap + shell tab captures
│   └── login.spec.ts        — onboarding/login screen capture + /auth/login 404 contract
├── screenshots/             — PNG artifacts (gitignored, .gitkeep tracked)
└── .gitignore
```

---

## What v1.1 adds

When BE-008 lands and the Flutter `/login` route gets wired:

- Replace `tests/login.spec.ts`'s onboarding fallback with a real
  fill-and-submit flow.
- Add `tests/log_entry.spec.ts` once the food log repo is wired
  (currently mocked).
- Add `tests/weight.spec.ts` once `POST /weights` is wired
  (currently mocked).
- Add a mobile-app suite via `flutter drive` or Detox — separate
  toplevel directory, separate CI job.
