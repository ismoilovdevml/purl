import { test, expect } from '@playwright/test';

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('Login Flow', () => {
  test.beforeEach(async ({ page }) => {
    // Clear cookies to ensure logged-out state
    await page.context().clearCookies();
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
  });

  test('should show login page with form elements', async ({ page }) => {
    const loginCard = page.locator('.login-card');
    await expect(loginCard).toBeVisible({ timeout: 10000 });

    // Logo and title
    await expect(page.locator('.login-logo h1')).toHaveText('Purl');
    await expect(page.locator('.login-subtitle')).toHaveText('Sign in to your dashboard');

    // Form inputs
    const usernameInput = page.locator('input[autocomplete="username"]');
    const passwordInput = page.locator('input[type="password"]');
    await expect(usernameInput).toBeVisible();
    await expect(passwordInput).toBeVisible();

    // Submit button
    const signInBtn = page.locator('button:has-text("Sign In")');
    await expect(signInBtn).toBeVisible();
  });

  test('should disable Sign In button when fields are empty', async ({ page }) => {
    const signInBtn = page.locator('button:has-text("Sign In")');
    await expect(signInBtn).toBeVisible({ timeout: 10000 });
    await expect(signInBtn).toBeDisabled();
  });

  test('should enable Sign In button when both fields are filled', async ({ page }) => {
    const usernameInput = page.locator('input[autocomplete="username"]');
    const passwordInput = page.locator('input[type="password"]');
    const signInBtn = page.locator('button:has-text("Sign In")');

    await expect(signInBtn).toBeVisible({ timeout: 10000 });
    await usernameInput.fill('testuser');
    await passwordInput.fill('testpass');
    await expect(signInBtn).toBeEnabled();
  });

  test('should show error on failed login with wrong password', async ({ page }) => {
    const usernameInput = page.locator('input[autocomplete="username"]');
    const passwordInput = page.locator('input[type="password"]');
    const signInBtn = page.locator('button:has-text("Sign In")');

    await expect(signInBtn).toBeVisible({ timeout: 10000 });
    await usernameInput.fill('admin');
    await passwordInput.fill('definitelywrongpassword');
    await signInBtn.click();

    const errorMsg = page.locator('.login-error');
    await expect(errorMsg).toBeVisible({ timeout: 10000 });
  });

  test('should not submit when fields are empty (button disabled)', async ({ page }) => {
    const signInBtn = page.locator('button:has-text("Sign In")');
    await expect(signInBtn).toBeVisible({ timeout: 10000 });

    // Button should be disabled, so clicking should not navigate away
    await expect(signInBtn).toBeDisabled();

    // Still on login page
    await expect(page.locator('.login-card')).toBeVisible();
  });

  test('should login successfully with valid credentials', async ({ page }) => {
    const usernameInput = page.locator('input[autocomplete="username"]');
    const passwordInput = page.locator('input[type="password"]');
    const signInBtn = page.locator('button:has-text("Sign In")');

    await expect(signInBtn).toBeVisible({ timeout: 10000 });
    await usernameInput.fill(USERNAME);
    await passwordInput.fill(PASSWORD);
    await signInBtn.click();

    // After login, should see the main app (nav-tabs or user-menu)
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 15000 });
  });

  test('should persist session after page reload', async ({ page }) => {
    // Login first
    const usernameInput = page.locator('input[autocomplete="username"]');
    const passwordInput = page.locator('input[type="password"]');
    const signInBtn = page.locator('button:has-text("Sign In")');

    await expect(signInBtn).toBeVisible({ timeout: 10000 });
    await usernameInput.fill(USERNAME);
    await passwordInput.fill(PASSWORD);
    await signInBtn.click();
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 15000 });

    // Reload and verify still logged in
    await page.reload();
    await page.waitForLoadState('networkidle');
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 15000 });
    // Should NOT see login form
    await expect(page.locator('.login-card')).not.toBeVisible({ timeout: 3000 });
  });

  test('should logout and redirect to login page', async ({ page }) => {
    // Login first
    const usernameInput = page.locator('input[autocomplete="username"]');
    const passwordInput = page.locator('input[type="password"]');
    const signInBtn = page.locator('button:has-text("Sign In")');

    await expect(signInBtn).toBeVisible({ timeout: 10000 });
    await usernameInput.fill(USERNAME);
    await passwordInput.fill(PASSWORD);
    await signInBtn.click();
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 15000 });

    // Click logout
    const logoutBtn = page.locator('button:has-text("Logout")');
    await expect(logoutBtn).toBeVisible({ timeout: 5000 });
    await logoutBtn.click();

    // Should return to login page
    await expect(page.locator('.login-card')).toBeVisible({ timeout: 10000 });
  });
});
