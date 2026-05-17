import { test, expect } from '@playwright/test';
import { snap, snapOnFailure, waitForFlutter } from './helpers';

/**
 * Drive the Flutter web client through a headless Chromium. The bundle
 * lives at `http://localhost/` (served by nginx); the initial route the
 * Flutter router lands on is `/today` (`Routes.todayPath` in
 * `client/lib/routing/routes.dart`). We screenshot the four shell tabs
 * plus the onboarding route.
 *
 * NOTE: these tests don't make strong DOM assertions — Flutter web
 * paints into a canvas, so DOM-level introspection is shallow on
 * purpose. The screenshots are the real test artifact; CI reviewers
 * inspect them when something looks off.
 */

test.afterEach(async ({ page }, testInfo) => {
  await snapOnFailure(page, testInfo.title, testInfo.status);
});

test.describe('flutter web render', () => {
  test('home (Today) renders and screenshots', async ({ page }) => {
    await page.goto('/');
    await waitForFlutter(page);
    // Assert that at least one Flutter mount marker is in the DOM. We
    // can't use `toHaveCount(>=1)` (Playwright wants an exact match),
    // so we read the count and assert it ourselves — clearer error
    // message on failure than a flaky `toBeVisible` against an
    // off-screen canvas.
    const flutterMarkers = await page.locator('flt-glass-pane, flutter-view').count();
    expect(
      flutterMarkers,
      'Flutter never mounted (no flt-glass-pane or flutter-view in DOM).',
    ).toBeGreaterThanOrEqual(1);
    await snap(page, '01-home.png');
  });

  test('navigates the four shell tabs and screenshots each', async ({ page }) => {
    // Routes from client/lib/routing/routes.dart. The Flutter router
    // accepts these as URL paths because go_router maps them 1:1.
    const tabs: Array<{ route: string; file: string }> = [
      { route: '/today', file: '03-today.png' },
      { route: '/foods', file: '04-foods.png' },
      { route: '/weight', file: '05-weight.png' },
      { route: '/me', file: '06-profile.png' },
      { route: '/goals', file: '07-goals.png' },
    ];

    for (const tab of tabs) {
      await page.goto(tab.route);
      await waitForFlutter(page);
      // Give Flutter one more idle tick — tab switches can defer a
      // first paint because the shell rebuilds.
      await page.waitForLoadState('networkidle').catch(() => {
        // Flutter web sometimes keeps long-poll-shaped requests open
        // (Hive on web uses IndexedDB, not HTTP, but Dart's HTTP
        // shim can keep a hanging request for telemetry). Don't fail
        // the screenshot just because networkidle never fires.
      });
      await snap(page, tab.file);
    }
  });
});
