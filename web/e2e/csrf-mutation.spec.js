import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * CSRF regression guard.
 *
 * The backend rejects any session-cookie mutation (POST/PUT/PATCH/DELETE) that
 * arrives without a valid `X-CSRF-Token`. Every dashboard mutation must
 * therefore go through the central apiClient (web/src/utils/api.js), which
 * attaches the header. A call site that regresses to a raw `fetch()` gets a
 * silent 403 that the UI shows as "nothing happened".
 *
 * The chosen mutation — Analytics "Clear Cache" (DELETE /api/cache) — only
 * flushes the server-side query cache, so it is safe to fire on every run.
 */
test.describe('CSRF-protected mutations', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('clear-cache sends X-CSRF-Token and is not rejected', async ({ page }) => {
    await gotoTab(page, 'Analytics');
    await expect(page.locator('.clear-cache-btn')).toBeVisible();

    const responsePromise = page.waitForResponse(
      (res) => res.url().includes('/api/cache') && res.request().method() === 'DELETE'
    );

    await page.locator('.clear-cache-btn').click();

    const response = await responsePromise;
    const headers = response.request().headers();

    expect(headers['x-csrf-token'], 'mutating request must include X-CSRF-Token').toBeTruthy();
    expect(response.status(), 'mutation must not be rejected with 403').not.toBe(403);
    expect(response.status(), 'mutation must succeed').toBeLessThan(400);
  });

  test('the same mutation without the CSRF header is rejected with 403', async ({ page, request }) => {
    // Proves the guard above is guarding something: replay the identical
    // request, authenticated by the session cookie, minus the header.
    const cookies = await page.context().cookies();
    const cookieHeader = cookies.map((c) => `${c.name}=${c.value}`).join('; ');

    const res = await request.delete('/api/cache', {
      headers: { Cookie: cookieHeader },
    });

    expect(
      res.status(),
      'a session-authenticated mutation without X-CSRF-Token must be rejected'
    ).toBe(403);
  });
});
