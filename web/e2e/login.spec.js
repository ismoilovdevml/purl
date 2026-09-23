import { test, expect } from '@playwright/test';
import { stackEnv } from './fixtures/purl.js';

/**
 * Login / session lifecycle.
 *
 * These specs deliberately do NOT use the shared `login()` helper — the helper
 * is what they are validating, and everything else in the suite depends on it.
 */
test.describe('Login Flow', () => {
  test.beforeEach(async ({ page }) => {
    await page.context().clearCookies();
    await page.goto('/');
    await expect(page.locator('.login-card')).toBeVisible({ timeout: 30_000 });
  });

  test('shows the login form', async ({ page }) => {
    await expect(page.locator('.login-logo h1')).toHaveText('Purl');
    await expect(page.locator('.login-subtitle')).toHaveText('Sign in to your dashboard');
    await expect(page.locator('input[autocomplete="username"]')).toBeVisible();
    await expect(page.locator('input[type="password"]')).toBeVisible();
    await expect(page.locator('button:has-text("Sign In")')).toBeVisible();
  });

  test('Sign In is disabled until both fields are filled', async ({ page }) => {
    const signIn = page.locator('button:has-text("Sign In")');
    await expect(signIn).toBeDisabled();

    // Username alone is not enough.
    await page.locator('input[autocomplete="username"]').fill('testuser');
    await expect(signIn).toBeDisabled();

    await page.locator('input[type="password"]').fill('testpass');
    await expect(signIn).toBeEnabled();
  });

  test('rejects a wrong password and stays on the login page', async ({ page }) => {
    await page.locator('input[autocomplete="username"]').fill(stackEnv.ADMIN_USERNAME);
    await page.locator('input[type="password"]').fill('definitelywrongpassword');
    await page.locator('button:has-text("Sign In")').click();

    await expect(page.locator('.login-error')).toBeVisible();
    // The important half: a rejected login must not let the app render.
    await expect(page.locator('.nav-tabs')).toHaveCount(0);
  });

  test('logs in with valid credentials', async ({ page }) => {
    await page.locator('input[autocomplete="username"]').fill(stackEnv.ADMIN_USERNAME);
    await page.locator('input[type="password"]').fill(stackEnv.ADMIN_PASSWORD);
    await page.locator('button:has-text("Sign In")').click();

    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 30_000 });
    await expect(page.locator('.user-menu .user-name')).toContainText(stackEnv.ADMIN_USERNAME);
  });

  test('session survives a page reload', async ({ page }) => {
    await page.locator('input[autocomplete="username"]').fill(stackEnv.ADMIN_USERNAME);
    await page.locator('input[type="password"]').fill(stackEnv.ADMIN_PASSWORD);
    await page.locator('button:has-text("Sign In")').click();
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 30_000 });

    await page.reload();
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 30_000 });
    await expect(page.locator('.login-card')).toHaveCount(0);
  });

  test('logout ends the session so a reload cannot resume it', async ({ page }) => {
    await page.locator('input[autocomplete="username"]').fill(stackEnv.ADMIN_USERNAME);
    await page.locator('input[type="password"]').fill(stackEnv.ADMIN_PASSWORD);
    await page.locator('button:has-text("Sign In")').click();
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 30_000 });

    await page.locator('button:has-text("Logout")').click();
    await expect(page.locator('.login-card')).toBeVisible();

    // Hiding the dashboard client-side is not logging out. If the cookie were
    // still valid, this reload would put us straight back into the app.
    await page.reload();
    await expect(page.locator('.login-card')).toBeVisible();
    await expect(page.locator('.nav-tabs')).toHaveCount(0);
  });
});

/**
 * The SSO button follows the public GET /api/auth/sso/status. It used to be
 * derived from the license feature list (GET /api/license), which no longer
 * exists. The endpoint is stubbed so each case is deterministic regardless of
 * whether the target instance has SAML configured.
 */
test.describe('Login SSO button', () => {
  const ssoButton = (page) => page.locator('a.sso-button');

  const openLoginWith = async (page, fulfill) => {
    await page.context().clearCookies();
    await page.route('**/api/auth/sso/status', fulfill);
    await page.goto('/');
    await expect(page.locator('.login-card')).toBeVisible({ timeout: 30_000 });
  };

  test('is shown when SSO is enabled', async ({ page }) => {
    await openLoginWith(page, (route) => route.fulfill({ json: { enabled: true } }));
    await expect(ssoButton(page)).toBeVisible();
    await expect(ssoButton(page)).toHaveAttribute('href', '/api/auth/sso/login');
  });

  test('is hidden when SSO is disabled', async ({ page }) => {
    const answered = page.waitForResponse('**/api/auth/sso/status');
    await openLoginWith(page, (route) => route.fulfill({ json: { enabled: false } }));
    await answered;
    await expect(ssoButton(page)).toHaveCount(0);
  });

  test('stays hidden, silently, when the status check fails', async ({ page }) => {
    const answered = page.waitForResponse('**/api/auth/sso/status');
    await openLoginWith(page, (route) => route.fulfill({ status: 500, json: { error: 'boom' } }));
    await answered;
    await expect(ssoButton(page)).toHaveCount(0);
    // A pre-auth probe failing is not the user's problem: no error on the form.
    await expect(page.locator('.login-error')).toHaveCount(0);
  });
});
