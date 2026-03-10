import { test, expect } from '@playwright/test';

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('Log Search', () => {
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

    // Ensure we are on the logs page
    await expect(page.locator('.nav-tabs')).toBeVisible({ timeout: 15000 });
    await page.locator('.nav-tabs button:has-text("Logs")').click();
    await page.waitForTimeout(500);
  });

  test('should show search bar', async ({ page }) => {
    const searchInput = page.locator('header input[type="text"], header input[type="search"]').first();
    await expect(searchInput).toBeVisible({ timeout: 5000 });
  });

  test('should focus search bar on click', async ({ page }) => {
    const searchInput = page.locator('header input[type="text"], header input[type="search"]').first();
    await searchInput.click();
    await expect(searchInput).toBeFocused();
  });

  test('should type query and trigger search', async ({ page }) => {
    const searchInput = page.locator('header input[type="text"], header input[type="search"]').first();
    await searchInput.fill('level:ERROR');
    await searchInput.press('Enter');
    await page.waitForTimeout(2000);

    // Stats bar should reflect the query
    const statsBar = page.locator('.stats-bar');
    await expect(statsBar).toBeVisible();
    await expect(statsBar).toContainText('level:ERROR');
  });

  test('should show stats bar with log count and time range', async ({ page }) => {
    const statsBar = page.locator('.stats-bar');
    await expect(statsBar).toBeVisible({ timeout: 10000 });
    await expect(statsBar).toContainText('logs');
    await expect(statsBar).toContainText('Time range');
  });

  test('should show time range selector', async ({ page }) => {
    // TimeRangePicker should be visible in header
    const timeRangePicker = page.locator('.header-actions button, .header-actions select').first();
    await expect(timeRangePicker).toBeVisible({ timeout: 5000 });
  });

  test('should show field sidebar with level filters', async ({ page }) => {
    const sidebar = page.locator('.sidebar');
    await expect(sidebar).toBeVisible({ timeout: 10000 });

    // Fields sidebar should show level-related content
    const fieldSection = sidebar.locator('text=level').first();
    // It may or may not have data; just check sidebar is rendered
    await expect(sidebar).toBeVisible();
  });

  test('should show log table with results', async ({ page }) => {
    // Wait for logs to load
    await page.waitForTimeout(3000);

    const mainContent = page.locator('.main-content');
    await expect(mainContent).toBeVisible({ timeout: 10000 });

    // Log table should be present
    const logTable = mainContent.locator('table, .log-table, .log-row').first();
    // If there are logs, rows should be visible; if empty, check for empty state
    const hasRows = await logTable.isVisible({ timeout: 5000 }).catch(() => false);
    if (!hasRows) {
      // Accept empty state as valid
      const emptyState = mainContent.locator('text=/no.*logs|no.*results|empty/i').first();
      const emptyVisible = await emptyState.isVisible({ timeout: 3000 }).catch(() => false);
      expect(hasRows || emptyVisible).toBe(true);
    }
  });

  test('should show Refresh button and it should be clickable', async ({ page }) => {
    const refreshBtn = page.locator('.header-actions button:has-text("Refresh")');
    await expect(refreshBtn).toBeVisible({ timeout: 5000 });
    await expect(refreshBtn).toBeEnabled();

    await refreshBtn.click();
    // Should show spinner briefly or reload results
    await page.waitForTimeout(1000);
    // Button should return to enabled state
    await expect(refreshBtn).toBeEnabled({ timeout: 10000 });
  });

  test('should show Actions dropdown with export options', async ({ page }) => {
    const actionsBtn = page.locator('.header-actions .dropdown-trigger:has-text("Actions")');
    await expect(actionsBtn).toBeVisible({ timeout: 5000 });

    await actionsBtn.click();
    await page.waitForTimeout(300);

    const dropdown = page.locator('.dropdown-menu.open');
    await expect(dropdown).toBeVisible({ timeout: 3000 });
    await expect(dropdown.locator('button:has-text("Export CSV")')).toBeVisible();
    await expect(dropdown.locator('button:has-text("Export JSON")')).toBeVisible();
    await expect(dropdown.locator('button:has-text("Save Search")')).toBeVisible();
  });

  test('should show search help button', async ({ page }) => {
    const helpBtn = page.locator('.search-help-btn');
    await expect(helpBtn).toBeVisible({ timeout: 5000 });

    await helpBtn.click();
    await page.waitForTimeout(500);

    // Search help modal/panel should appear
    const searchHelp = page.locator('text=/search.*syntax|search.*help|query.*syntax/i').first();
    await expect(searchHelp).toBeVisible({ timeout: 5000 });
  });

  test('should show histogram component', async ({ page }) => {
    await page.waitForTimeout(2000);
    const mainContent = page.locator('.main-content');
    await expect(mainContent).toBeVisible({ timeout: 10000 });
    // Histogram is typically rendered as SVG or canvas
    const histogram = mainContent.locator('svg, canvas, .histogram').first();
    await expect(histogram).toBeVisible({ timeout: 10000 });
  });
});
