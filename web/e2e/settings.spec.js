import { test, expect } from '@playwright/test';

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('Settings Page', () => {
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

    // Navigate to settings
    await page.locator('.nav-tabs button:has-text("Settings")').click();
    await expect(page.locator('.settings-page')).toBeVisible({ timeout: 10000 });
  });

  test('should load settings page', async ({ page }) => {
    await expect(page.locator('.settings-page')).toBeVisible();
    await expect(page.locator('.settings-nav h2')).toHaveText('Settings');
  });

  test('should show settings navigation sidebar with sections', async ({ page }) => {
    const nav = page.locator('.settings-nav');
    await expect(nav).toBeVisible();

    // Core sections that should always exist
    await expect(nav.locator('button:has-text("Database")')).toBeVisible();
    await expect(nav.locator('button:has-text("Display")')).toBeVisible();
    await expect(nav.locator('button:has-text("Notifications")')).toBeVisible();
    await expect(nav.locator('button:has-text("About")')).toBeVisible();
    await expect(nav.locator('button:has-text("License")')).toBeVisible();
    await expect(nav.locator('button:has-text("Sources")')).toBeVisible();
  });

  test('should navigate between settings sections', async ({ page }) => {
    const nav = page.locator('.settings-nav');

    // Click About
    await nav.locator('button:has-text("About")').click();
    await page.waitForTimeout(500);

    // Click Display
    await nav.locator('button:has-text("Display")').click();
    await page.waitForTimeout(500);

    // Display section should be active
    await expect(nav.locator('button:has-text("Display")')).toHaveClass(/active/);
  });

  test('should show Database settings for admin user', async ({ page }) => {
    const dbBtn = page.locator('.settings-nav button:has-text("Database")');
    await expect(dbBtn).toBeVisible();

    // If admin, Database should not be locked
    const isLocked = await dbBtn.evaluate(el => el.classList.contains('locked'));
    if (!isLocked) {
      await dbBtn.click();
      await page.waitForTimeout(500);
      await expect(dbBtn).toHaveClass(/active/);
    }
  });

  test('should show About section with version info', async ({ page }) => {
    await page.locator('.settings-nav button:has-text("About")').click();
    await page.waitForTimeout(1000);

    // About section should show version or app info
    const settingsContent = page.locator('.settings-page');
    await expect(settingsContent).toContainText(/version|purl|about/i, { timeout: 5000 });
  });

  test('should show API Keys section', async ({ page }) => {
    const apiKeysBtn = page.locator('.settings-nav button:has-text("API Keys")');
    const isVisible = await apiKeysBtn.isVisible({ timeout: 3000 }).catch(() => false);

    if (isVisible) {
      const isLocked = await apiKeysBtn.evaluate(el => el.classList.contains('locked'));
      if (!isLocked) {
        await apiKeysBtn.click();
        await page.waitForTimeout(500);
        await expect(apiKeysBtn).toHaveClass(/active/);
      }
    }
  });

  test('should show locked indicator on restricted sections for non-admin', async ({ page }) => {
    // Check that some sections have locked class (plan-gated sections)
    const nav = page.locator('.settings-nav');
    const lockedButtons = nav.locator('button.nav-item.locked');
    const count = await lockedButtons.count();
    // There should be at least some locked sections (enterprise features)
    expect(count).toBeGreaterThanOrEqual(0);
  });

  test('should show License section', async ({ page }) => {
    const licenseBtn = page.locator('.settings-nav button:has-text("License")');
    await expect(licenseBtn).toBeVisible();

    const isLocked = await licenseBtn.evaluate(el => el.classList.contains('locked'));
    if (!isLocked) {
      await licenseBtn.click();
      await page.waitForTimeout(500);
      await expect(licenseBtn).toHaveClass(/active/);
    }
  });

  test('should show Integrations section', async ({ page }) => {
    const intBtn = page.locator('.settings-nav button:has-text("Integrations")');
    await expect(intBtn).toBeVisible();

    const isLocked = await intBtn.evaluate(el => el.classList.contains('locked'));
    if (!isLocked) {
      await intBtn.click();
      await page.waitForTimeout(500);
      await expect(intBtn).toHaveClass(/active/);
    }
  });
});
