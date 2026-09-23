import { test, expect } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * #94 — every CSV export of the logs page produces the same RFC 4180 file.
 *
 * There used to be two builders: the Actions / "Export Selected (N)" menus
 * (LogsToolbar) quoted only message and meta cells and added meta.* columns,
 * while the selection bar's "Export selected" (LogTable) quoted on demand and
 * had no meta columns. The same rows gave two different files, and a comma in
 * a service name broke the toolbar's columns. Both now go through
 * utils/csv.js; this spec pins the exact bytes of all three download paths.
 *
 * /api/logs is mocked so the rows — and therefore the expected file — are
 * fixed. `meta` arrives as a JSON string, as the real API sends it.
 */
const TS = '2026-09-23T10:00:00.000Z';

const HITS = [
  {
    id: 'csv-1',
    timestamp: TS,
    level: 'ERROR',
    service: 'api,gateway',
    host: 'h1',
    message: 'He said "hi"',
    meta: JSON.stringify({ user: 'a"b', region: 'eu' }),
  },
  {
    id: 'csv-2',
    timestamp: TS,
    level: 'INFO',
    service: 'web',
    host: 'h2',
    message: 'line one\nline two',
    meta: JSON.stringify({ region: 'us' }),
  },
  {
    id: 'csv-3',
    timestamp: TS,
    level: 'DEBUG',
    service: 'worker',
    host: '',
    message: 'plain',
  },
];

// Header, then one record per row; CRLF between records (RFC 4180 §2.1).
// A field with a comma, quote or line break is quoted, inner quotes doubled.
const EXPECTED = [
  'timestamp,level,service,host,message,meta.region,meta.user',
  `${TS},ERROR,"api,gateway",h1,"He said ""hi""",eu,"a""b"`,
  `${TS},INFO,web,h2,"line one\nline two",us,`,
  `${TS},DEBUG,worker,,plain,,`,
].join('\r\n');

async function downloadedText(page, trigger) {
  const [download] = await Promise.all([page.waitForEvent('download'), trigger()]);
  const path = await download.path();
  return { name: download.suggestedFilename(), text: await readFile(path, 'utf8') };
}

test.describe('Log CSV export (#94)', () => {
  test.beforeEach(async ({ page }) => {
    await page.route(
      (url) => url.pathname === '/api/logs',
      (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        return route.fulfill({ json: { hits: HITS, total: HITS.length } });
      }
    );
    await login(page);
    await gotoTab(page, 'Logs');
    await expect(page.locator('tr.log-row')).toHaveCount(HITS.length);
  });

  test('Actions > Export CSV writes RFC 4180 CSV with meta columns', async ({ page }) => {
    await page.locator('.actions-dropdown button.dropdown-trigger', { hasText: 'Actions' }).last().click();
    const menu = page.locator('.dropdown-menu.open');

    const { name, text } = await downloadedText(page, () =>
      menu.locator('button:has-text("Export CSV")').click()
    );

    expect(name).toMatch(/^purl-logs-\d+\.csv$/);
    expect(text).toBe(EXPECTED);
  });

  test('the selection bar and the Export Selected menu produce the identical file', async ({ page }) => {
    const boxes = page.locator('tr.log-row input.row-checkbox');
    for (let i = 0; i < HITS.length; i++) {
      await boxes.nth(i).click();
    }
    await expect(page.locator('.selection-bar .selection-count')).toContainText(`${HITS.length} rows selected`);

    // Path 1: LogTable's selection bar.
    const fromBar = await downloadedText(page, () =>
      page.locator('.selection-bar button', { hasText: 'Export selected' }).click()
    );
    expect(fromBar.name).toMatch(/^purl-selected-\d+\.csv$/);
    expect(fromBar.text).toBe(EXPECTED);

    // Path 2: the header's "Export Selected (N)" menu (LogsToolbar).
    await page.locator('button.dropdown-trigger', { hasText: `Export Selected (${HITS.length})` }).click();
    const fromMenu = await downloadedText(page, () =>
      page.locator('.dropdown-menu.open button:has-text("Export CSV")').click()
    );
    expect(fromMenu.text).toBe(EXPECTED);
  });
});
