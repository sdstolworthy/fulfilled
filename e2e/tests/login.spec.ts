import { test, expect } from '@playwright/test';
import { snap, snapOnFailure, waitForFlutter } from './helpers';

/**
 * Login / onboarding screen capture.
 *
 * The Flutter client does not yet wire a `/login` route into go_router —
 * the login feature ships as a controller (`client/lib/features/login/`)
 * but has not been mounted (LOG-005 is partially landed; the route hookup
 * is still in flight). Until then the closest analog is the onboarding
 * flow at `/onboarding/1`, which is what a logged-out user would first
 * encounter once the route wires up.
 *
 * `POST /auth/login` returns 404 today (BE-008 isn't shipped) — the
 * onboarding screen itself still renders, which is all we screenshot
 * here. When the login screen lands behind `/login`, swap the goto path
 * and assert against the form fields directly.
 */

test.afterEach(async ({ page }, testInfo) => {
  await snapOnFailure(page, testInfo.title, testInfo.status);
});

test.describe('login / onboarding entry', () => {
  test('onboarding step 1 renders and screenshots as 02-login.png', async ({ page }) => {
    await page.goto('/onboarding/1');
    await waitForFlutter(page);
    // We can't reliably introspect Flutter canvas content from the DOM,
    // so the only structural assertion we make is "Flutter is up". The
    // screenshot is the real verification artifact.
    const flutterMarkers = await page.locator('flt-glass-pane, flutter-view').count();
    expect(flutterMarkers).toBeGreaterThanOrEqual(1);
    await snap(page, '02-login.png');
  });

  test('POST /auth/login currently returns 404 (BE-008 not shipped)', async ({ request }) => {
    // Documents the v1 state: the JWT-paste workaround in
    // `client/lib/data/auth_token.dart` exists precisely because this
    // endpoint isn't wired yet. When BE-008 lands and this returns
    // 200/401, update the assertion accordingly.
    const response = await request.post('http://localhost:8080/api/v1/auth/login', {
      data: { username: 'e2e', password: 'whatever' },
    });
    expect(response.status()).toBe(404);
  });
});
