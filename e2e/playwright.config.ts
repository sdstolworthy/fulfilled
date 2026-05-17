import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for Fulfilled E2E.
 *
 * The web bundle is served by the `web` service in `compose.e2e.yaml` on
 * host port 80, and the API is served by `api` on host port 8080. The
 * e2e nginx config (mounted from `nginx.e2e.conf` over the stock client
 * conf) proxies `/api/v1` from the web origin to the api container, so
 * the Flutter web app's `window.location.origin + '/api/v1'` resolution
 * works without any client code changes.
 *
 * Tests do not start the stack themselves — `npm run stack:up` (or the
 * CI workflow) brings compose up first. Playwright then drives a real
 * Chromium against the running stack.
 */
export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: [
    ['list'],
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
  ],
  // Generous global timeout because Flutter CanvasKit can be slow to
  // bootstrap on first paint (CanvasKit WASM is ~3 MB and decoded on
  // the main thread). Per-action timeouts stay tight.
  timeout: 90_000,
  expect: { timeout: 15_000 },
  use: {
    baseURL: process.env.E2E_BASE_URL ?? 'http://localhost',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  outputDir: 'test-results',
});
