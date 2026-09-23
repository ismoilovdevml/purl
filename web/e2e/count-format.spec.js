import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * #95 — one compact-count format across the UI.
 *
 * The histogram, patterns sidebar and dashboard widgets showed '1.0K' while the
 * fields sidebar and sources used utils/format.js and showed '1K'. They now
 * share formatCount, which always keeps one decimal. The fields sidebar is the
 * surface that changed, so it is the one pinned here; level stats are mocked
 * so the counts are known.
 */
test.describe('Compact count format (#95)', () => {
  test('the fields sidebar shows counts with one decimal', async ({ page }) => {
    await page.route(
      (url) => url.pathname === '/api/stats/fields/level',
      (route) => route.fulfill({
        json: {
          values: [
            { value: 'INFO', count: 2500000 },
            { value: 'ERROR', count: 1000 },
            { value: 'DEBUG', count: 999 },
          ],
        },
      })
    );

    await login(page);
    await gotoTab(page, 'Logs');

    const count = (level) =>
      page.locator(`button.field-value[aria-label="Filter by level:${level}"] .value-count`);
    await expect(count('INFO')).toHaveText('2.5M');
    await expect(count('ERROR')).toHaveText('1.0K');
    await expect(count('DEBUG')).toHaveText('999');
  });
});
