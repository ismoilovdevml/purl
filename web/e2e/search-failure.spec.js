import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * A search that FAILS must not be rendered as a search that found nothing.
 *
 * The bug: when GET /api/logs 400s (a rejected KQL query is the everyday case),
 * the store left the previous result set in place. The error banner auto-hid
 * after ~10s and the user was left looking at the rows from the PREVIOUS query
 * with the rejected query still in the search box — reading them as the answer.
 * For a log tool, silently answering the wrong question is worse than an error.
 *
 * The fix clears `logs`/`total` on failure and adds a third empty state driven
 * by the `error` store. This spec asserts all three halves of that contract:
 * the stale rows are gone, the failure is stated, and Retry actually re-issues
 * the request.
 *
 * Everything is route-driven, so the assertions do not depend on what the
 * backend happens to hold or on which KQL string is invalid this month.
 */

const row = (i) => ({
  id: `stale-${i}`,
  timestamp: new Date().toISOString(),
  level: 'INFO',
  service: 'e2e',
  host: 'e2e-host',
  message: `stale row ${i}`,
});

test.describe('Search failure state', () => {
  /** Flipped between tests; the single route handler reads it on every call. */
  let mode = 'ok';
  let requestCount = 0;

  test.beforeEach(async ({ page }) => {
    mode = 'ok';
    requestCount = 0;

    await page.route(
      (url) => url.pathname === '/api/logs',
      async (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        requestCount += 1;
        if (mode === 'reject') {
          return route.fulfill({
            status: 400,
            contentType: 'application/json',
            body: JSON.stringify({ error: 'Invalid query syntax near "AND AND"' }),
          });
        }
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ hits: [row(1), row(2), row(3)], total: 3 }),
        });
      }
    );

    await login(page);
    await gotoTab(page, 'Logs');
  });

  test('a rejected query clears the stale rows and states the failure', async ({ page }) => {
    // Establish the "previous result set" the bug used to leave on screen.
    await expect(page.locator('tr.log-row')).toHaveCount(3);
    await expect(page.locator('.toolbar-info')).toHaveText('3 logs');

    mode = 'reject';
    const search = page.locator('input[aria-label="Search logs"]');
    await search.fill('level:ERROR AND AND');
    await search.press('Enter');

    // 1. The rows that answered the PREVIOUS query must be gone.
    await expect(
      page.locator('tr.log-row'),
      'rows from the previous query must not survive a rejected one'
    ).toHaveCount(0);
    await expect(page.locator('.toolbar-info')).toHaveText('0 logs');

    // 2. The failure is stated, with the server's own reason.
    const empty = page.locator('.log-table-container .empty-state');
    await expect(empty).toBeVisible();
    await expect(empty.locator('.empty-title')).toHaveText('Search failed');
    await expect(empty).toContainText('Invalid query syntax');
    // Not the "nothing matched" wording — that is the whole point.
    await expect(empty).not.toContainText('No logs found');
    await expect(empty).not.toContainText('No logs yet');
  });

  test('Retry re-issues the search and recovers', async ({ page }) => {
    await expect(page.locator('tr.log-row')).toHaveCount(3);

    mode = 'reject';
    const search = page.locator('input[aria-label="Search logs"]');
    await search.fill('level:ERROR AND AND');
    await search.press('Enter');

    const empty = page.locator('.log-table-container .empty-state');
    await expect(empty.locator('.empty-title')).toHaveText('Search failed');

    const before = requestCount;
    mode = 'ok';
    await empty.locator('button:has-text("Retry search")').click();

    // A Retry button that does not issue a request is a placebo.
    await expect(page.locator('tr.log-row')).toHaveCount(3);
    expect(requestCount, 'Retry must actually re-issue GET /api/logs').toBeGreaterThan(before);
    await expect(page.locator('.log-table-container .empty-state')).toHaveCount(0);
  });

  test('the failure state wins over the never-ingested onboarding state', async ({ page }) => {
    // Both conditions true at once: nothing ever ingested AND the search
    // failed. Onboarding here would blame the user's setup for a server error.
    await page.route(
      (url) => url.pathname === '/api/stats',
      (route) =>
        route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ total_logs: 0 }),
        })
    );

    mode = 'reject';
    const search = page.locator('input[aria-label="Search logs"]');
    await search.fill('level:ERROR AND AND');
    await search.press('Enter');

    const empty = page.locator('.log-table-container .empty-state');
    await expect(empty.locator('.empty-title')).toHaveText('Search failed');
    await expect(empty.locator('.ingest-snippet')).toHaveCount(0);
  });
});
