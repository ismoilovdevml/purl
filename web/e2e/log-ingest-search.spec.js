import { test, expect } from '@playwright/test';
import { login, gotoTab, unique, ingestLogs, logEntry, waitForIngested } from './fixtures/purl.js';

/**
 * The flow the product exists for: a log is ingested over the API, and a human
 * finds it in the dashboard.
 *
 * Nothing in the old suite covered this. log-search.spec.js only asserted that
 * *some* table or *some* empty state was on screen, with a tautology that
 * accepted either — so a search returning the wrong rows, no rows, or every
 * row was equally green.
 *
 * Each test ingests its own uniquely-named data, so it does not care what else
 * is in the database and cannot be broken by another spec.
 */
test.describe('Ingest then search', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('an ingested log is findable by a free-text search', async ({ page, request }) => {
    const marker = unique('MARKER');

    await ingestLogs(request, [
      logEntry({ level: 'ERROR', service: 'e2e-search', message: `boom ${marker} happened` }),
    ]);
    await waitForIngested(request, marker);

    await gotoTab(page, 'Logs');
    const search = page.locator('input[aria-label="Search logs"]');
    await search.fill(marker);
    await search.press('Enter');

    const rows = page.locator('table.log-table tbody tr.log-row');
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toContainText(marker);
    await expect(rows.first().locator('.level-badge')).toHaveText('ERROR');
    await expect(rows.first().locator('.service')).toHaveText('e2e-search');

    await expect(page.locator('.stats-bar')).toContainText('1 logs');
  });

  test('a level filter excludes non-matching logs', async ({ page, request }) => {
    const marker = unique('LEVELS');

    await ingestLogs(request, [
      logEntry({ level: 'ERROR', service: 'e2e-levels', message: `${marker} an error` }),
      logEntry({ level: 'INFO', service: 'e2e-levels', message: `${marker} an info` }),
      logEntry({ level: 'INFO', service: 'e2e-levels', message: `${marker} another info` }),
    ]);
    await waitForIngested(request, marker);

    await gotoTab(page, 'Logs');
    const search = page.locator('input[aria-label="Search logs"]');

    await search.fill(marker);
    await search.press('Enter');
    await expect(page.locator('table.log-table tbody tr.log-row')).toHaveCount(3);

    // The filter must actually filter. A search that ignores `level:` would
    // still return 3 here and the old suite would not have noticed.
    await search.fill(`${marker} AND level:ERROR`);
    await search.press('Enter');
    const rows = page.locator('table.log-table tbody tr.log-row');
    await expect(rows).toHaveCount(1);
    await expect(rows.first()).toContainText('an error');
  });

  test('a search that matches nothing shows the empty state, not stale rows', async ({ page, request }) => {
    const present = unique('PRESENT');
    await ingestLogs(request, [logEntry({ service: 'e2e-empty', message: `${present} here` })]);
    await waitForIngested(request, present);

    await gotoTab(page, 'Logs');
    const search = page.locator('input[aria-label="Search logs"]');

    await search.fill(present);
    await search.press('Enter');
    await expect(page.locator('table.log-table tbody tr.log-row')).toHaveCount(1);

    await search.fill(unique('ABSENT-NEVER-INGESTED'));
    await search.press('Enter');

    await expect(page.locator('.empty-state')).toContainText('No logs found');
    await expect(page.locator('table.log-table tbody tr.log-row')).toHaveCount(0);
    await expect(page.locator('.stats-bar')).toContainText('0 logs');
  });

  test('clicking a row expands its detail', async ({ page, request }) => {
    const marker = unique('DETAIL');
    await ingestLogs(request, [
      logEntry({ level: 'WARN', service: 'e2e-detail', message: `${marker} inspect me` }),
    ]);
    await waitForIngested(request, marker);

    await gotoTab(page, 'Logs');
    const search = page.locator('input[aria-label="Search logs"]');
    await search.fill(marker);
    await search.press('Enter');

    // Wait for the filtered result, not just "a row": the Logs tab first
    // renders the default recent-logs view (which holds other specs' rows),
    // and clicking .first() before the search lands expands the wrong log.
    const rows = page.locator('table.log-table tbody tr.log-row');
    await expect(rows).toHaveCount(1);
    const row = rows.first();
    await expect(row).toContainText(marker);
    await row.click();

    const detail = page.locator('table.log-table tbody tr.detail-row');
    await expect(detail).toHaveCount(1);
    await expect(detail).toContainText(marker);
  });

  test('unicode and injection-shaped payloads round-trip unchanged', async ({ page, request }) => {
    const marker = unique('ODDCHARS');
    // A log line is attacker-controlled input. It must survive storage and
    // render as text — not as SQL, not as HTML.
    const nasty = `${marker} 🐈 ünïcødé "'; DROP TABLE logs; -- <script>alert(1)</script> \\n\\t`;

    await ingestLogs(request, [logEntry({ service: 'e2e-odd', message: nasty })]);
    await waitForIngested(request, marker);

    await gotoTab(page, 'Logs');
    const search = page.locator('input[aria-label="Search logs"]');
    await search.fill(marker);
    await search.press('Enter');

    const row = page.locator('table.log-table tbody tr.log-row').first();
    await expect(row).toBeVisible();
    // Rendered verbatim as text...
    await expect(row.locator('.message')).toContainText('🐈 ünïcødé');
    await expect(row.locator('.message')).toContainText('<script>alert(1)</script>');
    // ...and not executed: the script tag must not have become a real element.
    await expect(page.locator('table.log-table script')).toHaveCount(0);

    // The table is still there, which is the point of the DROP TABLE payload.
    await expect(page.locator('table.log-table')).toBeVisible();
  });
});
