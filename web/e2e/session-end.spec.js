import { test, expect } from '@playwright/test';

/**
 * #91 — the server can end a dashboard session on its own, and the UI must
 * land on the sign-in form instead of a dead dashboard.
 *
 *   - live tail (/api/logs/stream) closes with 4401 when the session is
 *     revoked: stop tailing, never reconnect, show login + a notice
 *   - any other close code keeps the reconnect-with-backoff behaviour
 *   - POST /api/auth/logout may 500 after clearing the cookie: the browser is
 *     signed out anyway, the server's message is a non-blocking warning
 *   - POST /api/auth/change-password may 500/404: show the server error, stay
 *     on the change form
 *   - a 401 from any protected API call lands on the sign-in form
 *
 * Every /api call and the WebSocket are mocked in the browser: these tests are
 * about how the page reacts to the server's answers, and must not revoke the
 * stack's real admin session or change its password.
 */

const ADMIN = { authenticated: true, auth_required: true, username: 'admin', role: 'admin' };

/**
 * Stub the whole API so the dashboard boots without a backend session.
 * Registered first, so per-test routes added later take precedence.
 */
async function mockApi(page, me = ADMIN) {
  await page.route('**/api/**', (route) => {
    const { pathname } = new URL(route.request().url());
    if (pathname === '/api/auth/me') return route.fulfill({ json: me });
    if (pathname === '/api/csrf-token') return route.fulfill({ json: { csrf_token: 'e2e-token' } });
    if (pathname === '/api/logs') return route.fulfill({ json: { hits: [], total: 0 } });
    if (pathname.startsWith('/api/stats/')) return route.fulfill({ json: { buckets: [], stats: [] } });
    return route.fulfill({ json: [] });
  });
}

async function openDashboard(page) {
  await page.goto('/');
  await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 30_000 });
}

const liveButton = (page) => page.locator('.search-bar button:has-text("Live")');
const liveActive = (page) => page.locator('.search-bar .live-indicator.active');

test.describe('Session ended by the server (#91)', () => {
  test('live tail closed with 4401 lands on sign-in and does not reconnect', async ({ page }) => {
    await mockApi(page);
    let connections = 0;
    let revoke;
    const revoked = new Promise((resolve) => { revoke = resolve; });
    await page.routeWebSocket('**/api/logs/stream', (ws) => {
      connections += 1;
      ws.send(JSON.stringify({ type: 'connected' }));
      revoked.then(() => ws.close({ code: 4401, reason: 'session revoked' }));
    });

    await openDashboard(page);
    await liveButton(page).click();
    await expect(liveActive(page)).toBeVisible();
    await expect.poll(() => connections).toBe(1);

    revoke();

    await expect(page.locator('.login-card')).toBeVisible();
    await expect(page.locator('.nav-tabs')).toHaveCount(0);
    await expect(page.locator('.login-card .session-notice')).toHaveText('Your session ended. Sign in again.');

    // First reconnect would fire after 0.5–1s of backoff; give it well over that.
    await page.waitForTimeout(2_500);
    expect(connections, '4401 must not trigger a reconnect').toBe(1);
  });

  test('any other close code keeps reconnecting and stays on the dashboard', async ({ page }) => {
    await mockApi(page);
    let connections = 0;
    await page.routeWebSocket('**/api/logs/stream', (ws) => {
      connections += 1;
      ws.send(JSON.stringify({ type: 'connected' }));
      if (connections === 1) setTimeout(() => ws.close({ code: 1011, reason: 'server error' }), 200);
    });

    await openDashboard(page);
    await liveButton(page).click();

    await expect.poll(() => connections, { timeout: 10_000 }).toBe(2);
    await expect(page.locator('.nav-tabs')).toBeVisible();
    await expect(page.locator('.login-card')).toHaveCount(0);
    await expect(liveActive(page)).toBeVisible();
  });

  test('logout 500 still signs this browser out and warns', async ({ page }) => {
    await mockApi(page);
    await page.route('**/api/auth/logout', (route) =>
      route.fulfill({
        status: 500,
        json: { error: 'Signed out in this browser, but the session could not be revoked on the server' },
      })
    );

    await openDashboard(page);
    await page.locator('button:has-text("Logout")').click();

    await expect(page.locator('.login-card')).toBeVisible();
    await expect(page.locator('.nav-tabs')).toHaveCount(0);
    await expect(page.locator('.toast-warning .toast-message')).toHaveText(
      'Signed out in this browser, but the session could not be revoked on the server'
    );
  });

  for (const status of [500, 404]) {
    test(`change-password ${status} shows the server error, not success`, async ({ page }) => {
      await mockApi(page, { ...ADMIN, must_change_password: true });
      const message = status === 500 ? 'Failed to save password' : 'User not found';
      await page.route('**/api/auth/change-password', (route) =>
        route.fulfill({ status, json: { error: message } })
      );

      await page.goto('/');
      await expect(page.locator('.login-subtitle')).toHaveText('Change your default password');

      await page.locator('input[autocomplete="current-password"]').fill('old-password-1');
      await page.locator('input[autocomplete="new-password"]').nth(0).fill('new-password-1');
      await page.locator('input[autocomplete="new-password"]').nth(1).fill('new-password-1');
      await page.getByRole('button', { name: 'Change Password' }).click();

      await expect(page.locator('.login-error')).toContainText(message);
      // Still on the change form: no success, no dashboard.
      await expect(page.locator('.login-subtitle')).toHaveText('Change your default password');
      await expect(page.locator('.nav-tabs')).toHaveCount(0);
    });
  }

  test('a 401 from a protected API call lands on sign-in', async ({ page }) => {
    await mockApi(page);
    await openDashboard(page);

    await page.route('**/api/logs**', (route) =>
      route.fulfill({ status: 401, json: { error: 'Authentication required' } })
    );
    await page.locator('.search-bar input').first().fill('level:ERROR');
    await page.locator('.search-bar input').first().press('Enter');

    await expect(page.locator('.login-card')).toBeVisible();
    await expect(page.locator('.nav-tabs')).toHaveCount(0);
  });
});
