import { test, expect } from '@playwright/test';
import { login, gotoTab, unique, csrfHeaders } from './fixtures/purl.js';

/**
 * Custom dashboards: create -> widgets render -> delete.
 *
 * Deletion is an `ALTER TABLE ... DELETE` mutation, which ClickHouse applies
 * asynchronously, so the "it is gone" assertion polls instead of reading once.
 */
test.describe('Dashboards', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  /** Remove a dashboard by name through the API, ignoring "already gone". */
  async function cleanup(page, name) {
    const headers = await csrfHeaders(page);
    const res = await page.request.get('/api/dashboards');
    if (!res.ok()) return;
    for (const d of (await res.json()).dashboards || []) {
      if (d.name === name) {
        await page.request.delete(`/api/dashboards/${d.id}`, { headers });
      }
    }
  }

  test('a dashboard is created, opened, and deleted from the UI', async ({ page }) => {
    const name = unique('e2e-dash');
    await gotoTab(page, 'Dashboards');

    try {
      // --- create ------------------------------------------------------
      await page.locator('button:has-text("New Dashboard")').click();

      const modal = page.locator('[role="dialog"]');
      await expect(modal).toBeVisible();
      const createButton = modal.locator('button:has-text("Create")');
      await expect(createButton, 'Create must stay disabled until a name is typed').toBeDisabled();

      await modal.locator('#dash-name').fill(name);
      await expect(createButton).toBeEnabled();
      await createButton.click();

      // Creating does NOT navigate: the modal closes and the store refetches,
      // so the new dashboard has to show up in the list on its own.
      await expect(modal).toHaveCount(0);
      await expect(
        page.locator('.dashboard-grid button.dashboard-card', { hasText: name }),
        'a created dashboard must appear in the list without a manual reload'
      ).toBeVisible();

      // --- it is really persisted, not just on screen -------------------
      const listed = await page.request.get('/api/dashboards');
      expect(listed.ok()).toBe(true);
      expect(
        ((await listed.json()).dashboards || []).map((d) => d.name),
        'the dashboard must exist server-side, not only in the client'
      ).toContain(name);

      // --- survives a reload -------------------------------------------
      await page.reload();
      await gotoTab(page, 'Dashboards');
      const card = page.locator('.dashboard-grid button.dashboard-card', { hasText: name });
      await expect(card).toBeVisible();

      // --- open it ------------------------------------------------------
      await card.click();
      await expect(page.locator('.page-header h2')).toHaveText(name);
      await expect(
        page.locator('.empty-widgets'),
        'a dashboard created with no widgets must say so'
      ).toBeVisible();

      // --- delete -------------------------------------------------------

      // Deletion goes through a native confirm(), which blocks until answered.
      page.once('dialog', (dialog) => dialog.accept());
      await page.locator('.header-actions button:has-text("Delete")').click();

      await expect
        .poll(
          async () => {
            const res = await page.request.get('/api/dashboards');
            if (!res.ok()) return ['<request failed>'];
            return ((await res.json()).dashboards || []).map((d) => d.name);
          },
          {
            message: 'the deleted dashboard must disappear (ALTER..DELETE is async)',
            timeout: 30_000,
          }
        )
        .not.toContain(name);
    } finally {
      await cleanup(page, name);
    }
  });

  test('a dashboard created from a template arrives with its widgets', async ({ page }) => {
    await gotoTab(page, 'Dashboards');

    // Template cards create immediately, with the template's own name.
    const template = page.locator('.template-grid button.template-card', {
      has: page.locator('.template-name', { hasText: 'Application Logs' }),
    });
    await expect(template, 'the Application Logs template must be offered').toBeVisible();
    await template.click();

    try {
      // Like plain creation, this lands back on the list rather than opening.
      const card = page.locator('.dashboard-grid button.dashboard-card', {
        hasText: 'Application Logs',
      });
      await expect(card).toBeVisible();
      // A template dashboard is only worth anything if it arrived populated.
      await expect(card.locator('.card-meta'), 'the template must bring widgets').not.toContainText(
        '0 widgets'
      );

      await card.click();
      await expect(page.locator('.page-header h2')).toHaveText('Application Logs');

      // The point of a template is that it is NOT empty.
      await expect(page.locator('.empty-widgets')).toHaveCount(0);
      const widgets = page.locator('.widgets-grid .widget-card');
      await expect(widgets.first()).toBeVisible();
      expect(await widgets.count(), 'the template must bring more than one widget').toBeGreaterThan(1);

      // Every widget must resolve — one stuck on "Loading..." or showing an
      // error is the failure mode this catches.
      await expect(page.locator('.widget-body .widget-loading')).toHaveCount(0, { timeout: 30_000 });
      await expect(page.locator('.widget-body .widget-error')).toHaveCount(0);
    } finally {
      await cleanup(page, 'Application Logs');
    }
  });
});
