import { test, expect } from '@playwright/test';
import { login, unique, csrfHeaders } from './fixtures/purl.js';

/**
 * Multi-role authorization: what a viewer cannot see, and cannot do.
 *
 * users-crud.spec.js proves a user with a role can be created and can log in.
 * Nothing asserted what the role actually BUYS — so a build that handed every
 * account admin rights, in the UI or in the API, was green.
 *
 * Both halves are covered on purpose and they fail differently:
 *   - the UI half catches a missing/incorrect client-side guard (a viewer
 *     seeing admin surfaces);
 *   - the API half catches the far worse case where the client hides a button
 *     but the endpoint behind it is unguarded. A client-only check is not
 *     authorization.
 *
 * SESSION HYGIENE: the viewer signs in inside a SEPARATE BrowserContext. Using
 * `page` (or `page.request`) would replace the admin session cookie this
 * describe block relies on for setup and cleanup.
 */

/** Admin-side setup helper: create a user, returning its credentials. */
async function createUser(page, role) {
  const username = unique(`e2e-${role}`).replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 32);
  const password = 'viewer-Pass-9f3a';
  const headers = await csrfHeaders(page);

  const res = await page.request.post('/api/settings/users', {
    headers,
    data: { username, password, role },
  });
  expect(res.status(), `POST /api/settings/users failed: ${await res.text()}`).toBe(200);

  return { username, password, headers };
}

test.describe('Role-based access control', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('a viewer gets no Settings or Analytics surface, and deep links bounce', async ({
    page,
    browser,
    baseURL,
  }) => {
    const { username, password, headers } = await createUser(page, 'viewer');
    // baseURL must be passed explicitly: a context built with
    // browser.newContext() does NOT inherit the config's `use` options.
    const viewerContext = await browser.newContext({ baseURL });

    try {
      const viewerPage = await viewerContext.newPage();
      await viewerPage.goto('/');
      await viewerPage.locator('input[autocomplete="username"]').fill(username);
      await viewerPage.locator('input[type="password"]').fill(password);
      await viewerPage.locator('button:has-text("Sign In")').click();
      await expect(viewerPage.locator('.nav-tabs')).toBeVisible({ timeout: 30_000 });

      // Confirm we really are the viewer and not riding an admin session.
      const me = await viewerPage.request.get('/api/auth/me');
      expect((await me.json()).role, 'the new session must be a viewer').toBe('viewer');

      // Admin-only tabs are removed from the DOM, not merely disabled.
      await expect(
        viewerPage.locator('.nav-tabs button:has-text("Settings")'),
        'a viewer must not be offered Settings'
      ).toHaveCount(0);
      await expect(
        viewerPage.locator('.nav-tabs button:has-text("Analytics")'),
        'a viewer must not be offered Analytics'
      ).toHaveCount(0);

      // The tabs a viewer IS entitled to must still be there — otherwise this
      // test would also pass against a build that renders no nav at all.
      await expect(viewerPage.locator('.nav-tabs button:has-text("Logs")')).toBeVisible();
      await expect(viewerPage.locator('.nav-tabs button:has-text("Traces")')).toBeVisible();

      // Hiding the button is not enough: the hash route must be guarded too.
      await viewerPage.evaluate(() => {
        window.location.hash = '#settings';
      });
      await expect
        .poll(() => viewerPage.evaluate(() => window.location.hash), {
          message: 'a viewer deep-linking to #settings must be bounced back to #logs',
        })
        .toBe('#logs');
      await expect(viewerPage.locator('.settings-page')).toHaveCount(0);
    } finally {
      await viewerContext.close();
      await page.request.delete(`/api/settings/users/${username}`, { headers });
    }
  });

  test('a viewer session is refused by admin-gated endpoints', async ({ page, browser, baseURL }) => {
    const { username, password, headers } = await createUser(page, 'viewer');
    const viewerContext = await browser.newContext({ baseURL });

    try {
      // Log in through the API in the isolated context so its cookie jar — and
      // only its cookie jar — carries the viewer session.
      const loginRes = await viewerContext.request.post('/api/auth/login', {
        data: { username, password },
      });
      expect(loginRes.ok(), `viewer login failed: ${await loginRes.text()}`).toBe(true);
      expect((await loginRes.json()).role).toBe('viewer');

      const csrf = await viewerContext.request.get('/api/csrf-token');
      const viewerHeaders = {
        'X-CSRF-Token': (await csrf.json()).csrf_token,
        'Content-Type': 'application/json',
      };

      // Each of these is a genuinely destructive capability. A 403 is the only
      // acceptable answer; 2xx means the UI guard is the ONLY thing standing
      // between a viewer and the operation.
      const forbidden = [
        ['POST', '/api/settings/users', { username: 'sneak', password: 'sneak-Pass-1', role: 'admin' }],
        ['PUT', '/api/settings/retention', { days: 7 }],
        ['POST', '/api/alerts', { name: 'sneak', query: 'x', threshold: 1, window_minutes: 5 }],
        ['PUT', '/api/settings/notifications/webhook', { url: 'https://sneak.invalid/hook' }],
        ['POST', '/api/settings/api-keys', { name: 'sneak' }],
      ];

      for (const [method, path, data] of forbidden) {
        const res = await viewerContext.request.fetch(path, {
          method,
          headers: viewerHeaders,
          data,
        });
        expect(res.status(), `${method} ${path} must be refused for a viewer`).toBe(403);
      }

      // Sanity check in the other direction: the viewer CAN read logs. Without
      // this, a server that 403s every request would pass the loop above.
      const logs = await viewerContext.request.get('/api/logs?limit=1&range=15m');
      expect(logs.status(), 'a viewer must still be able to read logs').toBe(200);
    } finally {
      await viewerContext.close();
      await page.request.delete(`/api/settings/users/${username}`, { headers });
    }
  });

  test('an operator may manage alerts but not delete them or manage users', async ({
    page,
    browser,
    baseURL,
  }) => {
    const { username, password, headers } = await createUser(page, 'operator');
    const opContext = await browser.newContext({ baseURL });

    try {
      const loginRes = await opContext.request.post('/api/auth/login', {
        data: { username, password },
      });
      expect(loginRes.ok(), `operator login failed: ${await loginRes.text()}`).toBe(true);

      const csrf = await opContext.request.get('/api/csrf-token');
      const opHeaders = {
        'X-CSRF-Token': (await csrf.json()).csrf_token,
        'Content-Type': 'application/json',
      };

      // Allowed: alert creation is admin|operator.
      const name = unique('e2e-op-alert');
      const created = await opContext.request.post('/api/alerts', {
        headers: opHeaders,
        data: { name, query: 'x', threshold: 1, window_minutes: 5, notify_type: 'telegram' },
      });
      expect(created.status(), `an operator must be able to create an alert: ${await created.text()}`).toBe(200);

      // Refused: deletion is admin-only, so the operator's own alert is
      // undeletable by them. This is the line between the two roles.
      const list = await opContext.request.get('/api/alerts');
      const alert = (await list.json()).alerts.find((a) => a.name === name);
      expect(alert, 'the operator-created alert must be listed').toBeTruthy();

      const del = await opContext.request.delete(`/api/alerts/${alert.id}`, { headers: opHeaders });
      expect(del.status(), 'deleting an alert is admin-only').toBe(403);

      // Refused: user management is admin-only.
      const addUser = await opContext.request.post('/api/settings/users', {
        headers: opHeaders,
        data: { username: 'opsneak', password: 'opsneak-Pass-1', role: 'admin' },
      });
      expect(addUser.status(), 'an operator must not create users').toBe(403);

      // Admin cleans up what the operator could not.
      await page.request.delete(`/api/alerts/${alert.id}`, { headers });
    } finally {
      await opContext.close();
      await page.request.delete(`/api/settings/users/${username}`, { headers });
    }
  });
});
