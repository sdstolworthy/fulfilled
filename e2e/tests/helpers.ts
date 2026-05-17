import { Page, expect } from '@playwright/test';
import * as path from 'path';

/**
 * Static dev-bypass bearer baked into compose.e2e.yaml. Any authenticated
 * request can attach this header and the Rust server's DevAuthenticator
 * will resolve it to the seeded `e2e-user` identity.
 */
export const E2E_BEARER = 'e2e-test-token';

/**
 * Host:port where the api is exposed by compose.e2e.yaml. Override with
 * `E2E_API_BASE_URL` if you remap the port locally.
 */
export const E2E_API_BASE_URL =
  process.env.E2E_API_BASE_URL ?? 'http://localhost:8080/api/v1';

/**
 * Where screenshots land. The `screenshots/` directory ships with the
 * repo (empty + `.gitkeep`) and is uploaded as a GitHub Actions artifact
 * on CI runs (see `.github/workflows/e2e.yml`).
 */
export const SCREENSHOTS_DIR = path.join(__dirname, '..', 'screenshots');

export function shotPath(name: string): string {
  return path.join(SCREENSHOTS_DIR, name);
}

/**
 * Wait for the Flutter web bundle to finish bootstrapping.
 *
 * The Flutter web entry point (`flutter_bootstrap.js`) injects a
 * `<flutter-view>` element wrapping `<flt-glass-pane>` once the engine
 * initialises and the first frame paints. Polling for `flt-glass-pane`
 * is the canonical "Flutter is ready" signal and works for both
 * CanvasKit and HTML renderers.
 *
 * The polling timeout is generous (45 s) because CanvasKit can be slow
 * on a cold CI runner — the WASM module is several MB and decoded on
 * the main thread.
 */
export async function waitForFlutter(page: Page, timeoutMs = 45_000): Promise<void> {
  await page.waitForFunction(
    () => {
      // `flt-glass-pane` is the canvas overlay Flutter mounts once the
      // engine is live. It's the same marker `flutter_tools` integration
      // tests use for `pumpAndSettle`-equivalent waits in browsers.
      const glass = document.querySelector('flt-glass-pane');
      if (glass !== null) return true;
      // Fallback marker — older Flutter web builds emit `<flutter-view>`.
      const view = document.querySelector('flutter-view');
      return view !== null;
    },
    null,
    { timeout: timeoutMs, polling: 250 },
  );
  // Settle one more animation frame so the first paint completes before
  // we snap a screenshot.
  await page.waitForTimeout(500);
}

/**
 * Take a full-page screenshot, named, into `screenshots/`. Wrapper exists
 * so tests don't repeat the path-join boilerplate and so a future change
 * to the screenshot directory layout only happens in one place.
 */
export async function snap(page: Page, name: string): Promise<void> {
  await page.screenshot({
    path: shotPath(name),
    fullPage: true,
    animations: 'disabled',
  });
}

/**
 * Best-effort: if the test errored, still capture the current viewport so
 * the failure artifact directory has something visual to inspect. Wired
 * via an `afterEach` in each spec file.
 */
export async function snapOnFailure(
  page: Page,
  testTitle: string,
  status: string | undefined,
): Promise<void> {
  if (status === 'passed' || status === 'skipped') return;
  const safe = testTitle.replace(/[^a-z0-9-_]+/gi, '_').toLowerCase();
  try {
    await page.screenshot({
      path: shotPath(`failure-${safe}.png`),
      fullPage: true,
    });
  } catch {
    // Page may already be closed if the failure was a teardown error —
    // swallow rather than mask the real assertion failure.
  }
}

/**
 * Sanity helper: assert a Playwright APIResponse has the expected shape
 * with a useful error message. Centralised so the smoke spec stays
 * declarative.
 */
export function expectJsonOk(
  response: { ok(): boolean; status(): number; url(): string },
): void {
  expect(
    response.ok(),
    `Expected 2xx from ${response.url()} but got ${response.status()}`,
  ).toBeTruthy();
}
