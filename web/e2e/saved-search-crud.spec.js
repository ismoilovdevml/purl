import { test, expect } from '@playwright/test';
import { login, gotoTab, expandSidebarPanel, unique } from './fixtures/purl.js';

/**
 * Saved search lifecycle: save from the Actions menu -> visible in the sidebar
 * -> survives a reload -> applying it drives the search bar -> delete.
 */
test.describe('Saved searches CRUD', () => {
  const openPanel = async (page) => {
    await gotoTab(page, 'Logs');
    return expandSidebarPanel(page, '.saved-searches');
  };

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('saves a search, reloads it, applies it, then deletes it', async ({ page }) => {
    const name = unique('e2e-search');
    const query = 'level:ERROR AND service:e2e';

    await gotoTab(page, 'Logs');

    // --- save via the Actions menu (the path that prefills the query) ---
    await page.locator('input[aria-label="Search logs"]').fill(query);
    await page.locator('.actions-dropdown button.dropdown-trigger', { hasText: 'Actions' }).last().click();
    await page.locator('.dropdown-menu.open button:has-text("Save Search")').click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal.locator('#modal-title')).toHaveText('Save Search');
    // The Actions path must prefill the query — that is the whole point of it.
    await expect(modal.getByLabel('Query', { exact: true })).toHaveValue(query);

    await modal.getByLabel('Name', { exact: true }).fill(name);
    await modal.locator('select.select-field').selectOption('1h');

    const createResponse = page.waitForResponse(
      (res) => new URL(res.url()).pathname === '/api/saved-searches' && res.request().method() === 'POST'
    );
    await modal.locator('.modal-footer button.btn-success').click();

    const created = await createResponse;
    expect(created.status(), `POST /api/saved-searches failed: ${await created.text()}`).toBeLessThan(300);
    await expect(modal).toHaveCount(0);

    // --- appears in the sidebar ---------------------------------------
    let panel = await openPanel(page);
    const row = panel.locator('.content li', { hasText: name });
    await expect(row).toHaveCount(1);
    await expect(row.locator('.query')).toContainText(query);

    // --- survives a reload --------------------------------------------
    await page.reload();
    await expect(page.locator('.nav-tabs')).toBeVisible();
    panel = await openPanel(page);
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(1);

    // --- applying it drives the search bar and the stats bar ----------
    await page.locator('input[aria-label="Search logs"]').fill('');
    await panel.locator('.content li', { hasText: name }).locator('.search-item').click();

    await expect(page.locator('input[aria-label="Search logs"]')).toHaveValue(query);
    await expect(page.locator('.stats-bar')).toContainText('Time range: 1h');

    // --- delete --------------------------------------------------------
    const deleteResponse = page.waitForResponse(
      (res) =>
        /\/api\/saved-searches\/[^/]+$/.test(new URL(res.url()).pathname) &&
        res.request().method() === 'DELETE'
    );
    await panel.locator('.content li', { hasText: name }).locator('.delete-btn').click();

    const confirm = page.locator('.confirm-dialog');
    await expect(confirm.locator('.confirm-title')).toHaveText('Delete Saved Search');
    await confirm.locator('.btn-confirm').click();

    const deleted = await deleteResponse;
    expect(deleted.status(), `DELETE /api/saved-searches failed: ${await deleted.text()}`).toBeLessThan(300);
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(0);

    await page.reload();
    await expect(page.locator('.nav-tabs')).toBeVisible();
    panel = await openPanel(page);
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(0);
  });

  test('a search with no name is not saved', async ({ page }) => {
    const panel = await openPanel(page);
    const before = await panel.locator('.content li').count();

    await panel.locator('[title="Save current search"]').click();
    const modal = page.locator('[role="dialog"]');
    await modal.getByLabel('Query', { exact: true }).fill('level:WARN');
    await modal.locator('.modal-footer button.btn-success').click();

    await expect(modal).toBeVisible();
    await modal.locator('.modal-footer button.btn-default').click();
    await expect(panel.locator('.content li')).toHaveCount(before);
  });
});
