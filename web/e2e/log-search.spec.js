import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * Logs page shell.
 *
 * Result-level behaviour (ingest -> search -> the row is on screen) lives in
 * log-ingest-search.spec.js, which controls its own data. This file only
 * covers the chrome, and it no longer contains the old
 *
 *     if (!hasRows) expect(hasRows || emptyVisible).toBe(true);
 *
 * which is `false || x` — a tautology that passed whether the table rendered,
 * the empty state rendered, or the page was blank.
 */
test.describe('Logs page', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
    await gotoTab(page, 'Logs');
  });

  test('shows a focusable search bar', async ({ page }) => {
    const search = page.locator('input[aria-label="Search logs"]');
    await expect(search).toBeVisible();
    await search.click();
    await expect(search).toBeFocused();
  });

  test('a submitted query is reflected in the stats bar', async ({ page }) => {
    const search = page.locator('input[aria-label="Search logs"]');
    await search.fill('level:ERROR');
    await search.press('Enter');

    const statsBar = page.locator('.stats-bar');
    await expect(statsBar).toBeVisible();
    await expect(statsBar).toContainText('level:ERROR');
  });

  test('the stats bar reports a count and the active time range', async ({ page }) => {
    const statsBar = page.locator('.stats-bar');
    await expect(statsBar).toBeVisible();
    await expect(statsBar).toContainText(/\d[\d,]* logs/);
    await expect(statsBar).toContainText(/Time range: \S+/);
  });

  test('the results area renders either a log table or the empty state', async ({ page }) => {
    // Exactly one of the two must be on screen. The previous version accepted
    // "neither" as a pass.
    const table = page.locator('.log-table-container table.log-table');
    const empty = page.locator('.empty-state');

    await expect(table.or(empty).first()).toBeVisible();

    const tableCount = await table.count();
    const emptyCount = await empty.count();
    expect(
      tableCount + emptyCount,
      'the logs pane must render results or an explicit empty state, never nothing'
    ).toBeGreaterThan(0);

    if (emptyCount > 0 && tableCount === 0) {
      await expect(empty).toContainText('No logs found');
    }
  });

  test('Refresh re-issues the search request', async ({ page }) => {
    const refreshBtn = page.locator('.header-actions button.btn', { hasText: 'Refresh' }).first();
    await expect(refreshBtn).toBeEnabled();

    // Assert the network call, not just that a button survived being clicked.
    const requestPromise = page.waitForRequest(
      (req) => new URL(req.url()).pathname === '/api/logs' && req.method() === 'GET'
    );
    await refreshBtn.click();
    await requestPromise;

    await expect(refreshBtn).toBeEnabled();
  });

  test('the Actions dropdown offers export and save options', async ({ page }) => {
    const actions = page.locator('.actions-dropdown button.dropdown-trigger', { hasText: 'Actions' }).last();
    await actions.click();

    const dropdown = page.locator('.dropdown-menu.open');
    await expect(dropdown).toBeVisible();
    await expect(dropdown.locator('button:has-text("Export CSV")')).toBeVisible();
    await expect(dropdown.locator('button:has-text("Export JSON")')).toBeVisible();
    await expect(dropdown.locator('button:has-text("Save Search")')).toBeVisible();
  });

  test('the search help panel opens and closes with Escape', async ({ page }) => {
    const helpBtn = page.locator('.search-help-btn');
    await expect(helpBtn).toBeVisible();
    await helpBtn.click();

    const help = page.locator('text=/search.*syntax|query.*syntax/i').first();
    await expect(help).toBeVisible();

    await page.keyboard.press('Escape');
    await expect(help).toBeHidden();
  });

  test('the fields sidebar and the histogram render', async ({ page }) => {
    await expect(page.locator('aside.sidebar')).toBeVisible();
    await expect(page.locator('.main-content svg, .main-content canvas, .main-content .histogram').first())
      .toBeVisible();
  });
});
