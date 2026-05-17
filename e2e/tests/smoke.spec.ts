import { test, expect } from '@playwright/test';
import { E2E_BEARER, E2E_API_BASE_URL, expectJsonOk } from './helpers';

/**
 * Smoke tests for the Rust API. These hit the api container directly
 * (port 8080 on the host) — they do not go through the web nginx proxy.
 * Keeps the smoke surface minimal and independent of any Flutter
 * bootstrap weirdness.
 */
test.describe('api smoke', () => {
  test('GET /health returns {status: "ok"}', async ({ request }) => {
    const response = await request.get(`${E2E_API_BASE_URL}/health`);
    expectJsonOk(response);
    const body = await response.json();
    expect(body).toMatchObject({ status: 'ok' });
  });

  test('GET /me with dev-bypass bearer returns a User', async ({ request }) => {
    const response = await request.get(`${E2E_API_BASE_URL}/me`, {
      headers: { Authorization: `Bearer ${E2E_BEARER}` },
    });
    expectJsonOk(response);
    const body = await response.json();
    // The User schema has id + email + display_name plus some optional
    // profile fields. We assert only the always-present keys so the
    // smoke test doesn't drift every time the schema grows a field.
    expect(typeof body.id).toBe('string');
    // DEV_AUTH_EMAIL / DEV_AUTH_DISPLAY_NAME in compose.e2e.yaml.
    expect(body.email).toBe('e2e@example.com');
    expect(body.display_name).toBe('E2E User');
  });

  test('GET /me without bearer returns 401', async ({ request }) => {
    const response = await request.get(`${E2E_API_BASE_URL}/me`);
    expect(response.status()).toBe(401);
  });

  test('GET /me with wrong bearer returns 401', async ({ request }) => {
    const response = await request.get(`${E2E_API_BASE_URL}/me`, {
      headers: { Authorization: 'Bearer not-the-e2e-token' },
    });
    expect(response.status()).toBe(401);
  });

  test('web nginx proxies /api/v1/health to the api service', async ({ request }) => {
    // Same /health endpoint, this time via the web origin. Proves the
    // nginx proxy in nginx.e2e.conf is wired correctly, which is what
    // the Flutter web bundle relies on at runtime.
    const response = await request.get('http://localhost/api/v1/health');
    expectJsonOk(response);
    const body = await response.json();
    expect(body).toMatchObject({ status: 'ok' });
  });
});
