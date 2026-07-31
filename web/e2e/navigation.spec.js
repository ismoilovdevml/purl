import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

test.describe('Navigation', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('shows every main navigation item', async ({ page }) => {
    const nav = page.locator('.nav-tabs');
    for (const label of ['Logs', 'Analytics', 'Traces', 'Query', 'Dashboards', 'Settings']) {
      await expect(nav.locator(`button:has-text("${label}")`), `nav must contain "${label}"`).toBeVisible();
    }
  });

  test.describe('hash routing', () => {
    // Previously each of these was its own copy-pasted test, and the Analytics
    // one was wrapped in `if (visible)` so it passed when the tab vanished.
    for (const [label, hash] of [
      ['Logs', '#logs'],
      ['Analytics', '#analytics'],
      ['Traces', '#traces'],
      ['Query', '#query'],
      ['Settings', '#settings'],
    ]) {
      test(`${label} tab routes to ${hash}`, async ({ page }) => {
        await gotoTab(page, label);
        expect(page.url()).toContain(hash);
      });
    }
  });

  test('Logs page renders its stats bar', async ({ page }) => {
    await gotoTab(page, 'Logs');
    await expect(page.locator('.stats-bar')).toBeVisible();
  });

  test('Settings page renders its sidebar', async ({ page }) => {
    await gotoTab(page, 'Settings');
    await expect(page.locator('.settings-page')).toBeVisible();

    const settingsNav = page.locator('.settings-nav');
    await expect(settingsNav.locator('h2')).toHaveText('Settings');
    for (const label of ['Database', 'Display', 'About']) {
      await expect(settingsNav.locator(`button:has-text("${label}")`)).toBeVisible();
    }
  });

  test('a direct hash URL selects the matching tab', async ({ page }) => {
    await page.goto('/#traces');
    await expect(page.locator('.nav-tabs button:has-text("Traces")')).toHaveClass(/active/);
  });

  test('browser back/forward walk the route history', async ({ page }) => {
    await gotoTab(page, 'Logs');
    await gotoTab(page, 'Traces');
    await gotoTab(page, 'Query');
    expect(page.url()).toContain('#query');

    await page.goBack();
    await expect(page.locator('.nav-tabs button:has-text("Traces")')).toHaveClass(/active/);
    expect(page.url()).toContain('#traces');

    await page.goForward();
    await expect(page.locator('.nav-tabs button:has-text("Query")')).toHaveClass(/active/);
    expect(page.url()).toContain('#query');
  });

  test('only one nav tab is active at a time', async ({ page }) => {
    const logsBtn = page.locator('.nav-tabs button:has-text("Logs")');
    const tracesBtn = page.locator('.nav-tabs button:has-text("Traces")');

    await gotoTab(page, 'Logs');
    await expect(logsBtn).toHaveClass(/active/);

    await gotoTab(page, 'Traces');
    await expect(tracesBtn).toHaveClass(/active/);
    await expect(logsBtn).not.toHaveClass(/active/);
  });

  test('mobile viewport exposes the hamburger and opens the sidebar', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });

    const hamburger = page.locator('button.hamburger');
    await expect(hamburger).toBeVisible();
    await hamburger.click();
    await expect(page.locator('.sidebar.mobile-open')).toBeVisible();
  });
});
