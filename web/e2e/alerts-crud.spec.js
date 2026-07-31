import { test, expect } from '@playwright/test';
import { login, gotoTab, expandSidebarPanel, unique } from './fixtures/purl.js';

/**
 * Alert lifecycle: create -> visible in the list -> survives a reload -> delete.
 *
 * Before this file the suite protected no mutating flow at all. The closest
 * thing was modal-real-user.spec.js, which filled the alert form in and then
 * clicked *Cancel* — so a backend that 500s on POST /api/alerts stayed green.
 *
 * The assertions here are on the persisted list, not on the modal closing: a
 * modal that closes on a failed save is exactly the bug this must catch.
 */
test.describe('Alerts CRUD', () => {
  const openAlerts = async (page) => {
    await gotoTab(page, 'Logs');
    return expandSidebarPanel(page, '.alerts-panel');
  };

  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('creates an alert, keeps it across a reload, then deletes it', async ({ page }) => {
    const name = unique('e2e-alert');
    let panel = await openAlerts(page);

    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(0);

    // --- create -------------------------------------------------------
    await panel.locator('[title="Create alert"]').click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal.locator('#modal-title')).toHaveText('Create Alert');

    await modal.getByLabel('Name', { exact: true }).fill(name);
    await modal.getByLabel('Query (optional)').fill('level:ERROR');
    await modal.getByLabel('Threshold', { exact: true }).fill('7');
    await modal.getByLabel('Window (minutes)').fill('11');
    // "browser" needs no delivery target and is not license-gated, so this
    // spec stays valid on every plan.
    await modal.locator('select.select-field').selectOption('browser');

    const createResponse = page.waitForResponse(
      (res) => new URL(res.url()).pathname === '/api/alerts' && res.request().method() === 'POST'
    );
    await modal.locator('.modal-footer button.btn-success').click();

    const created = await createResponse;
    expect(created.status(), `POST /api/alerts failed: ${await created.text()}`).toBeLessThan(300);
    await expect(modal).toHaveCount(0);

    // --- appears in the list -----------------------------------------
    const row = panel.locator('.content li', { hasText: name });
    await expect(row).toHaveCount(1);
    await expect(row.locator('.name')).toHaveText(name);
    // The details line proves the form values reached the server, not just the name.
    await expect(row.locator('.details')).toContainText('level:ERROR');
    await expect(row.locator('.details')).toContainText('>= 7');
    await expect(row.locator('.details')).toContainText('in 11m');

    // --- survives a reload (i.e. it is really persisted) --------------
    await page.reload();
    await expect(page.locator('.nav-tabs')).toBeVisible();
    panel = await openAlerts(page);
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(1);

    // --- delete -------------------------------------------------------
    const deleteResponse = page.waitForResponse(
      (res) => /\/api\/alerts\/[^/]+$/.test(new URL(res.url()).pathname) && res.request().method() === 'DELETE'
    );
    await panel.locator('.content li', { hasText: name }).locator('.delete-btn').click();

    const confirm = page.locator('.confirm-dialog');
    await expect(confirm.locator('.confirm-title')).toHaveText('Delete Alert');
    await confirm.locator('.btn-confirm').click();

    const deleted = await deleteResponse;
    expect(deleted.status(), `DELETE /api/alerts failed: ${await deleted.text()}`).toBeLessThan(300);

    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(0);

    // And it is gone from the server, not just from the rendered list.
    await page.reload();
    await expect(page.locator('.nav-tabs')).toBeVisible();
    panel = await openAlerts(page);
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(0);
  });

  test('cancelling the delete confirmation keeps the alert', async ({ page }) => {
    const name = unique('e2e-alert-keep');
    const panel = await openAlerts(page);

    await panel.locator('[title="Create alert"]').click();
    const modal = page.locator('[role="dialog"]');
    await modal.getByLabel('Name', { exact: true }).fill(name);
    await modal.locator('select.select-field').selectOption('browser');
    await modal.locator('.modal-footer button.btn-success').click();
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(1);

    await panel.locator('.content li', { hasText: name }).locator('.delete-btn').click();
    await page.locator('.confirm-dialog .btn-cancel').click();
    await expect(page.locator('.confirm-dialog')).toHaveCount(0);
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(1);

    // Clean up so the alert limit is not consumed for later specs.
    await panel.locator('.content li', { hasText: name }).locator('.delete-btn').click();
    await page.locator('.confirm-dialog .btn-confirm').click();
    await expect(panel.locator('.content li', { hasText: name })).toHaveCount(0);
  });

  test('an alert with no name is not created', async ({ page }) => {
    const panel = await openAlerts(page);
    const before = await panel.locator('.content li').count();

    await panel.locator('[title="Create alert"]').click();
    const modal = page.locator('[role="dialog"]');
    await modal.getByLabel('Query (optional)').fill('level:ERROR');
    await modal.locator('.modal-footer button.btn-success').click();

    // saveAlert() returns early on a blank name: the modal must stay open and
    // nothing may be added. Previously nothing asserted this at all.
    await expect(modal).toBeVisible();
    await modal.locator('.modal-footer button.btn-default').click();
    await expect(modal).toHaveCount(0);
    await expect(panel.locator('.content li')).toHaveCount(before);
  });
});
