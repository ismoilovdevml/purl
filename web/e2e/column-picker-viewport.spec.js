import { test, expect } from '@playwright/test';
import { login, gotoTab, ingestLogs, logEntry, unique, waitForIngested } from './fixtures/purl.js';

/**
 * #118: the Columns picker opened downward with a fixed 500px max-height and a
 * clipped (overflow: hidden) list, so on an 800px-tall screen it ended ~300px
 * below the fold and the Kubernetes columns (Namespace, Pod, Node) could not be
 * reached. Now it is clamped to the viewport and its column list scrolls.
 */
const VIEWPORTS = [
  { width: 1280, height: 800 },
  { width: 1024, height: 768 },
  { width: 390, height: 844 },
];

test.describe('Columns picker fits the viewport (#118)', () => {
  test.beforeEach(async ({ page, request }) => {
    // Rows, so the table (not the empty state) is rendered. Wait until the
    // row is searchable: on a fresh stack the first insert can lag the page.
    const marker = unique('colpick');
    await ingestLogs(request, [logEntry({ message: `${marker} seed line` })]);
    await waitForIngested(request, marker);
    await login(page);
  });

  for (const viewport of VIEWPORTS) {
    test(`every column is reachable at ${viewport.width}x${viewport.height}`, async ({ page }) => {
      await page.setViewportSize(viewport);
      await gotoTab(page, 'Logs');
      await expect(page.locator('.log-table tr.log-row').first()).toBeVisible({ timeout: 30_000 });

      await page.locator('.picker-trigger').click();
      const panel = page.locator('.picker-dropdown');
      await expect(panel).toBeVisible();

      const box = await panel.boundingBox();
      expect(box.y, 'panel top edge').toBeGreaterThanOrEqual(0);
      expect(box.y + box.height, `panel bottom edge (viewport ${viewport.height})`).toBeLessThanOrEqual(viewport.height);
      expect(box.x + box.width, `panel right edge (viewport ${viewport.width})`).toBeLessThanOrEqual(viewport.width);

      // The last column in the list: scrolled into view inside the panel and
      // toggled with a real click (no force), so it must be on screen and on top.
      const last = page.locator('.picker-dropdown .column-item').last();
      const label = (await last.locator('.column-label').innerText()).trim();
      const input = last.locator('input[type="checkbox"]');
      const before = await input.isChecked();
      await last.locator('.column-checkbox').click();
      await expect(input, `"${label}" must toggle`).toBeChecked({ checked: !before });
      const itemBox = await last.boundingBox();
      expect(itemBox.y + itemBox.height, `"${label}" row must be inside the viewport`).toBeLessThanOrEqual(viewport.height);

      // The Kubernetes Pod column specifically — the workaround users need.
      const pod = page.locator('.picker-dropdown .column-item', { hasText: /^\s*Pod\s*$/ });
      await pod.locator('.column-checkbox').click();
      await expect(pod.locator('input[type="checkbox"]')).toBeChecked();
      // Close it by clicking a known element outside the panel (the picker
      // has no Escape handler; it closes on click-outside).
      await page.locator('.table-toolbar .toolbar-info').click();
      await expect(page.locator('.picker-dropdown')).toHaveCount(0);
      await expect(page.locator('.log-table thead')).toContainText(/pod/i);
    });
  }
});
