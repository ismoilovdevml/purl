import { test, expect } from '@playwright/test';
import { login, gotoTab, ingestLogs, logEntry, unique, waitForIngested } from './fixtures/purl.js';

/**
 * #116: POST /api/query answers `{ hits, total }` (Controller/Logs.pm::query),
 * but the Query page read `results.logs`, so the header said "N results" while
 * the table said "No results found" — for every query, always.
 *
 * The seeded lines are from the current minute on purpose: the default "To"
 * is the minute the page opened, and it used to be sent as hh:mm:00, which
 * silently excluded everything logged in that minute.
 */
test.describe('Query page', () => {
  test('a query on seeded data shows its rows in the table and the JSON view', async ({ page, request }) => {
    const marker = unique('querypage');
    const count = 7;
    await ingestLogs(
      request,
      Array.from({ length: count }, (_, i) =>
        logEntry({ level: 'ERROR', message: `${marker} connection refused ${i}` })
      )
    );
    await waitForIngested(request, marker);

    await login(page);
    await gotoTab(page, 'Query');
    await page.locator('#query-editor').fill(`level:error AND message:"${marker}"`);
    await page.locator('.query-page button:has-text("Execute")').click();

    await expect(page.locator('.results-count')).toHaveText(`${count} results`, { timeout: 30_000 });
    const rows = page.locator('.results-table tbody tr');
    await expect(rows, 'the table must hold every row the header counts').toHaveCount(count);
    await expect(page.locator('.results-section')).not.toContainText('No results found');
    await expect(rows.first()).toContainText(marker);
    await expect(page.locator('.results-table thead')).toContainText('message');
    // Object fields (meta) render as JSON, never as "[object Object]".
    await expect(page.locator('.results-table tbody')).not.toContainText('[object Object]');

    // The JSON view shows the same rows.
    await page.locator('.toggle-btn:has-text("JSON")').click();
    const json = JSON.parse(await page.locator('.json-code').innerText());
    expect(json).toHaveLength(count);
    expect(json.every((r) => r.message.includes(marker))).toBe(true);
  });

  test('the Fields option narrows the table to the requested columns', async ({ page, request }) => {
    const marker = unique('queryfields');
    await ingestLogs(request, [logEntry({ message: `${marker} only line` })]);
    await waitForIngested(request, marker);

    await login(page);
    await gotoTab(page, 'Query');
    await page.locator('#query-editor').fill(`message:"${marker}"`);
    await page.locator('#fields-input').fill('level, message');
    await page.locator('.query-page button:has-text("Execute")').click();

    await expect(page.locator('.results-table tbody tr')).toHaveCount(1, { timeout: 30_000 });
    const headers = await page.locator('.results-table thead th').allInnerTexts();
    expect(headers.map((h) => h.trim().toLowerCase())).toEqual(['#', 'level', 'message']);
  });

  test('a query that matches nothing says so', async ({ page }) => {
    await login(page);
    await gotoTab(page, 'Query');
    await page.locator('#query-editor').fill(`message:"${unique('nomatch')}"`);
    await page.locator('.query-page button:has-text("Execute")').click();
    await expect(page.locator('.results-count')).toHaveText('0 results', { timeout: 30_000 });
    await expect(page.locator('.results-section')).toContainText('No results found');
  });
});
