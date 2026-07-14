import { test, expect } from '@playwright/test';

/**
 * CSRF regression guard.
 *
 * The backend enforces CSRF on every mutating request (POST/PUT/PATCH/DELETE):
 * a session-cookie request without a valid `X-CSRF-Token` header is rejected
 * with 403. All dashboard mutations must therefore go through the central
 * apiClient (web/src/utils/api.js), which attaches that header automatically.
 *
 * This spec drives a real dashboard mutation end-to-end and asserts the
 * outgoing request carried `x-csrf-token` and did NOT come back 403. Against
 * the pre-fix code (raw `fetch()` with no header) the same action returns 403,
 * so this test fails without the fix.
 *
 * The chosen mutation — Analytics "Clear Cache" (DELETE /api/cache) — is
 * intentionally low-impact: it only flushes the server-side query cache.
 *
 * NOTE: playwright.config.js targets the live demo server, so this requires a
 * running Purl instance (with CSRF enabled) and PURL_TEST_PASSWORD to execute.
 */

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('CSRF-protected mutations', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    // Login if needed
    const loginForm = page.locator('input[type="password"]');
    if (await loginForm.isVisible({ timeout: 3000 }).catch(() => false)) {
      const usernameInput = page.locator('input[autocomplete="username"]').first();
      await usernameInput.fill(USERNAME);
      await loginForm.fill(PASSWORD);
      await page.locator('button:has-text("Sign In")').first().click();
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(1000);
    }

    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 15000 });
  });

  test('clear-cache mutation sends X-CSRF-Token and is not rejected with 403', async ({ page }) => {
    // Navigate to Analytics
    await page.locator('.nav-tabs button:has-text("Analytics")').click();
    await expect(page.locator('.clear-cache-btn')).toBeVisible({ timeout: 10000 });

    // Capture the mutating request/response for DELETE /api/cache
    const cacheResponsePromise = page.waitForResponse(
      (res) => res.url().includes('/api/cache') && res.request().method() === 'DELETE',
      { timeout: 10000 }
    );

    await page.locator('.clear-cache-btn').click();

    const response = await cacheResponsePromise;
    const request = response.request();

    // The request must carry the CSRF header (proves it went through apiClient)
    const headers = request.headers();
    expect(headers['x-csrf-token'], 'mutating request must include X-CSRF-Token').toBeTruthy();

    // And it must not be rejected as a CSRF failure
    expect(response.status(), 'mutation must not be rejected with 403').not.toBe(403);
  });
});
