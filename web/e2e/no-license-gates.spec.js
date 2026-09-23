import { test, expect } from '@playwright/test';
import { login, gotoTab, expandSidebarPanel } from './fixtures/purl.js';

/**
 * Purl is open source (MIT): there is no license, no plan and no gated feature.
 *
 * Every assertion here targets something the commercial layer used to render
 * or enforce — a plan badge, the trial banner, a "Pro" lock on a nav tab, an
 * "Upgrade" call-to-action in a sidebar panel, a redirect away from a gated
 * route, or a boot-time call to the (now removed) GET /api/license. If any of
 * it comes back, this file goes red.
 */
test.describe('No license gating', () => {
  test('boot never calls the removed /api/license endpoint', async ({ page }) => {
    const licenseCalls = [];
    page.on('request', (req) => {
      if (new URL(req.url()).pathname.startsWith('/api/license')) licenseCalls.push(req.url());
    });

    await login(page);
    await gotoTab(page, 'Settings');
    await gotoTab(page, 'Logs');

    expect(licenseCalls, 'nothing may request /api/license').toEqual([]);
  });

  test.describe('signed in', () => {
    test.beforeEach(async ({ page }) => {
      await login(page);
    });

    test('the header carries no plan badge, trial banner or upgrade link', async ({ page }) => {
      await expect(page.locator('.nav-tabs')).toBeVisible();
      await expect(page.locator('.plan-badge')).toHaveCount(0);
      await expect(page.locator('.trial-banner')).toHaveCount(0);
      await expect(page.locator('.pro-badge')).toHaveCount(0);
      await expect(page.locator('a[href*="pricing"]')).toHaveCount(0);
    });

    test('Dashboards is an ordinary tab and its deep link is honoured', async ({ page }) => {
      const tab = page.locator('.nav-tabs button:has-text("Dashboards")');
      await expect(tab).toBeVisible();
      await expect(tab).not.toHaveClass(/locked/);

      // A gated build bounced #dashboards back to #logs with a warning toast.
      await page.goto('/#dashboards');
      await expect(tab).toHaveClass(/active/);
      expect(page.url()).toContain('#dashboards');
    });

    test('Saved Searches and Patterns render their content, not an upgrade CTA', async ({ page }) => {
      await gotoTab(page, 'Logs');

      const saved = await expandSidebarPanel(page, '.saved-searches');
      await expect(saved.locator('.content')).toBeVisible();
      await expect(saved.locator('.upgrade-cta')).toHaveCount(0);

      const patterns = page.locator('.patterns-sidebar');
      await expect(patterns.locator('.patterns-content')).toBeVisible();
      await expect(patterns).not.toContainText(/Upgrade/i);
    });
  });
});
