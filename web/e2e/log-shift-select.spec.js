import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * #97 — shift-click on a row checkbox selects the whole range.
 *
 * LogTable read `event.shiftKey` from the checkbox's `change` event, which is
 * a plain Event with no shiftKey, so the range branch was dead code and a
 * shift-click only toggled the one row. The row checkbox now reports its
 * `click` (a MouseEvent). Rows are mocked so the indices are known.
 */
const ROWS = Array.from({ length: 6 }, (_, i) => ({
  id: `shift-${i}`,
  timestamp: new Date(Date.now() - i * 1000).toISOString(),
  level: 'INFO',
  service: 'e2e',
  host: 'e2e-host',
  message: `shift-select row ${i}`,
}));

test.describe('Log table shift-click range selection (#97)', () => {
  test.beforeEach(async ({ page }) => {
    await page.route(
      (url) => url.pathname === '/api/logs',
      (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        return route.fulfill({ json: { hits: ROWS, total: ROWS.length } });
      }
    );
    await login(page);
    await gotoTab(page, 'Logs');
    await expect(page.locator('tr.log-row')).toHaveCount(ROWS.length);
  });

  const boxes = (page) => page.locator('tr.log-row input.row-checkbox');

  async function expectChecked(page, checkedIndices) {
    for (let i = 0; i < ROWS.length; i++) {
      const box = boxes(page).nth(i);
      if (checkedIndices.includes(i)) {
        await expect(box, `row ${i} should be selected`).toBeChecked();
      } else {
        await expect(box, `row ${i} should not be selected`).not.toBeChecked();
      }
    }
  }

  test('shift-clicking a second checkbox selects every row in between', async ({ page }) => {
    await boxes(page).nth(1).click();
    await boxes(page).nth(4).click({ modifiers: ['Shift'] });

    await expectChecked(page, [1, 2, 3, 4]);
    await expect(page.locator('.selection-bar .selection-count')).toContainText('4 rows selected');
  });

  test('shift-click works upwards and a shift-click on a selected row clears the range', async ({ page }) => {
    await boxes(page).nth(4).click();
    await boxes(page).nth(2).click({ modifiers: ['Shift'] });
    await expectChecked(page, [2, 3, 4]);

    // The anchor stays on row 4; row 3 is selected, so the range 3..4 is cleared.
    await boxes(page).nth(3).click({ modifiers: ['Shift'] });
    await expectChecked(page, [2]);
    await expect(page.locator('.selection-bar .selection-count')).toContainText('1 row selected');
  });

  test('a plain click and the Space key still toggle a single row', async ({ page }) => {
    await boxes(page).nth(0).click();
    await boxes(page).nth(2).click();
    await expectChecked(page, [0, 2]);

    // Keyboard: Space on a focused checkbox fires `click`, so it must still work.
    await boxes(page).nth(5).focus();
    await page.keyboard.press('Space');
    await expectChecked(page, [0, 2, 5]);

    // Toggling a checkbox must not expand the row.
    await expect(page.locator('tr.log-row.selected')).toHaveCount(0);
  });
});
