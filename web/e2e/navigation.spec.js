import { test, expect } from '@playwright/test';

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('Navigation', () => {
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

  test('should show main navigation items', async ({ page }) => {
    const nav = page.locator('.nav-tabs');
    await expect(nav.locator('button:has-text("Logs")')).toBeVisible();
    await expect(nav.locator('button:has-text("Traces")')).toBeVisible();
    await expect(nav.locator('button:has-text("Query")')).toBeVisible();
    await expect(nav.locator('button:has-text("Dashboards")')).toBeVisible();
    await expect(nav.locator('button:has-text("Settings")')).toBeVisible();
  });

  test('should navigate to Logs page', async ({ page }) => {
    await page.locator('.nav-tabs button:has-text("Logs")').click();
    await expect(page.locator('.stats-bar')).toBeVisible({ timeout: 10000 });
    expect(page.url()).toContain('#logs');
  });

  test('should navigate to Traces page', async ({ page }) => {
    await page.locator('.nav-tabs button:has-text("Traces")').click();
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#traces');
  });

  test('should navigate to Query page', async ({ page }) => {
    await page.locator('.nav-tabs button:has-text("Query")').click();
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#query');
  });

  test('should navigate to Settings page', async ({ page }) => {
    await page.locator('.nav-tabs button:has-text("Settings")').click();
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#settings');
    await expect(page.locator('.settings-page')).toBeVisible({ timeout: 10000 });
  });

  test('should navigate to Analytics page', async ({ page }) => {
    const analyticsBtn = page.locator('.nav-tabs button:has-text("Analytics")');
    if (await analyticsBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
      await analyticsBtn.click();
      await page.waitForTimeout(500);
      expect(page.url()).toContain('#analytics');
    }
  });

  test('should handle hash-based routing directly', async ({ page }) => {
    // Navigate via hash
    await page.goto(`${BASE}/#traces`);
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(1000);

    const tracesBtn = page.locator('.nav-tabs button:has-text("Traces")');
    await expect(tracesBtn).toHaveClass(/active/, { timeout: 5000 });
  });

  test('should handle back/forward browser navigation', async ({ page }) => {
    // Go to Logs
    await page.locator('.nav-tabs button:has-text("Logs")').click();
    await page.waitForTimeout(500);

    // Go to Traces
    await page.locator('.nav-tabs button:has-text("Traces")').click();
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#traces');

    // Go to Query
    await page.locator('.nav-tabs button:has-text("Query")').click();
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#query');

    // Go back to Traces
    await page.goBack();
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#traces');

    // Go forward to Query
    await page.goForward();
    await page.waitForTimeout(500);
    expect(page.url()).toContain('#query');
  });

  test('should show Settings page sidebar navigation', async ({ page }) => {
    await page.locator('.nav-tabs button:has-text("Settings")').click();
    await expect(page.locator('.settings-page')).toBeVisible({ timeout: 10000 });

    // Settings nav should have sections
    const settingsNav = page.locator('.settings-nav');
    await expect(settingsNav).toBeVisible();
    await expect(settingsNav.locator('h2')).toHaveText('Settings');

    // Check some known sections exist
    await expect(settingsNav.locator('button:has-text("Database")')).toBeVisible();
    await expect(settingsNav.locator('button:has-text("About")')).toBeVisible();
    await expect(settingsNav.locator('button:has-text("Display")')).toBeVisible();
  });

  test('should show hamburger menu on mobile viewport', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.waitForTimeout(500);

    const hamburger = page.locator('button.hamburger');
    await expect(hamburger).toBeVisible({ timeout: 5000 });

    // Click hamburger to open mobile sidebar
    await hamburger.click();
    await page.waitForTimeout(500);

    // Sidebar should be visible
    const sidebar = page.locator('.sidebar.mobile-open');
    await expect(sidebar).toBeVisible({ timeout: 5000 });
  });

  test('should highlight active nav button', async ({ page }) => {
    const logsBtn = page.locator('.nav-tabs button:has-text("Logs")');
    await logsBtn.click();
    await page.waitForTimeout(300);
    await expect(logsBtn).toHaveClass(/active/);

    const tracesBtn = page.locator('.nav-tabs button:has-text("Traces")');
    await tracesBtn.click();
    await page.waitForTimeout(300);
    await expect(tracesBtn).toHaveClass(/active/);
    // Logs should no longer be active
    await expect(logsBtn).not.toHaveClass(/active/);
  });
});
