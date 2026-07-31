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
