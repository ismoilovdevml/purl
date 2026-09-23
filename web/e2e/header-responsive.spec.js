import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * #103: the header was one non-wrapping flex row (tabs, user, Live, search,
 * cluster picker, time range, Actions, Refresh). At ~1500px the Actions button
 * was clipped at the right edge and its menu opened off-screen; `body` has
 * `overflow: hidden`, so the clipped part was simply unreachable.
 *
 * At every common width: nothing in the header may extend past the viewport,
 * the page may not scroll sideways, and every header dropdown must open fully
 * inside the viewport. A cluster list is mocked so the cluster picker — the
 * widest optional control — is on screen too.
 */

const VIEWPORTS = [
  { width: 1920, height: 1080 },
  { width: 1512, height: 900 },
  { width: 1280, height: 800 },
  { width: 1024, height: 768 },
  { width: 768, height: 1024 },
  { width: 390, height: 844 },
];

/** Every rendered element in the header whose box leaves the viewport. */
async function headerOverflow(page) {
  return page.evaluate(() => {
    const vw = document.documentElement.clientWidth;
    const offenders = [];
    for (const el of document.querySelectorAll('header, header *')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if (r.right > vw + 0.5 || r.left < -0.5) {
        offenders.push(`${el.tagName.toLowerCase()}.${[...el.classList].join('.')} [${Math.round(r.left)}..${Math.round(r.right)}]`);
      }
    }
    return {
      vw,
      scrollWidth: document.documentElement.scrollWidth,
      offenders: offenders.slice(0, 10),
    };
  });
}

async function expectInsideViewport(page, locator, what) {
  await expect(locator, `${what} must open`).toBeVisible();
  const box = await locator.boundingBox();
  const vw = await page.evaluate(() => document.documentElement.clientWidth);
  expect(box, `${what} must have a box`).not.toBeNull();
  expect(box.x, `${what} left edge`).toBeGreaterThanOrEqual(0);
  expect(box.x + box.width, `${what} right edge (viewport ${vw})`).toBeLessThanOrEqual(vw + 0.5);
}

test.describe('Responsive header (#103)', () => {
  test.beforeEach(async ({ page }) => {
    await page.route(
      (url) => url.pathname === '/api/clusters',
      (route) =>
        route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ clusters: ['production-eu-west-1', 'staging'] }),
        })
    );
  });

  for (const viewport of VIEWPORTS) {
    test(`fits at ${viewport.width}px and its menus stay on screen`, async ({ page }) => {
      await page.setViewportSize(viewport);
      await login(page);
      await gotoTab(page, 'Logs');
      await expect(page.locator('.cluster-selector')).toBeVisible();

      const layout = await headerOverflow(page);
      expect(layout.offenders, `header elements past the ${layout.vw}px viewport`).toEqual([]);
      expect(layout.scrollWidth, 'no horizontal page overflow').toBeLessThanOrEqual(layout.vw);

      // The controls e2e and users rely on are reachable, not clipped away.
      const actions = page.locator('.actions-dropdown button.dropdown-trigger', { hasText: 'Actions' }).last();
      await expect(actions).toBeVisible();
      await expect(page.locator('.header-actions button.btn', { hasText: 'Refresh' })).toBeVisible();

      await actions.click();
      await expectInsideViewport(page, page.locator('.dropdown-menu.open'), 'Actions menu');
      await expect(page.locator('.dropdown-menu.open button:has-text("Export CSV")')).toBeVisible();
      await page.keyboard.press('Escape');
      await expect(page.locator('.dropdown-menu.open')).toHaveCount(0);

      await page.locator('.time-picker .picker-btn').click();
      await expectInsideViewport(page, page.locator('.time-picker .dropdown'), 'time range menu');
      // The wider custom-range form must be pulled back inside as well.
      await page.locator('.time-picker .custom-btn').click();
      await expectInsideViewport(page, page.locator('.time-picker .dropdown'), 'custom range form');
    });
  }

  test('icon-only tabs keep their accessible names', async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 768 });
    await login(page);
    await expect(page.getByRole('button', { name: 'Settings', exact: true })).toBeVisible();
    await gotoTab(page, 'Traces');
  });
});
