import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * The two empty states of the logs table (LogTable.svelte).
 *
 * "Nothing matched your filter" and "this instance has never received a log
 * line" look the same to the DOM but mean opposite things, and the whole
 * distinction rides on one store: `hasEverIngested` in stores/ingest.js, fed by
 * GET /api/stats -> total_logs.
 *
 *   total_logs = 0   -> false -> onboarding ("No logs yet" + ingest snippet)
 *   total_logs > 0   -> true  -> neutral ("No logs found")
 *   probe failed     -> null  -> neutral, NEVER onboarding
 *
 * That last row is the one worth guarding hardest. It is not a nicety: telling
 * a user with 10M stored lines that they have never sent one, because a stats
 * call blipped, is the worst possible failure mode of this feature — and it is
 * exactly what a well-meaning `?? 0` in the store would produce.
 *
 * Every test here drives BOTH /api/stats and /api/logs, so the outcome is a
 * function of the intercepts alone. That is deliberate: log-search.spec.js used
 * to assert "No logs found" against whatever the stack happened to contain,
 * which only held because Playwright runs files in path order and
 * log-ingest-search.spec.js sorts earlier and leaves rows behind. Run it alone
 * and the text changed. Empty states must not be tested through a side effect
 * of the alphabet.
 */

const EMPTY_LOGS = { hits: [], total: 0 };

/**
 * Pin both endpoints before the app boots.
 *
 * `/api/stats/histogram` must NOT be caught by the stats route — it is a
 * different endpoint with a different shape, and swallowing it would blank the
 * histogram and change what the page renders. Hence the exact pathname match.
 */
async function pinLogsPage(page, { stats }) {
  await page.route(
    (url) => url.pathname === '/api/stats',
    async (route) => {
      if (stats === 'fail') {
        return route.fulfill({
          status: 500,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'e2e injected stats failure' }),
        });
      }
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ total_logs: stats }),
      });
    }
  );

  await page.route(
    (url) => url.pathname === '/api/logs',
    async (route) => {
      if (route.request().method() !== 'GET') return route.fallback();
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify(EMPTY_LOGS),
      });
    }
  );
}

test.describe('Logs empty states', () => {
  test('an instance that has never ingested gets onboarding, not search advice', async ({ page }) => {
    await pinLogsPage(page, { stats: 0 });
    await login(page);
    await gotoTab(page, 'Logs');

    const empty = page.locator('.log-table-container .empty-state');
    await expect(empty).toBeVisible();
    await expect(empty.locator('.empty-title')).toHaveText('No logs yet');
    await expect(empty).not.toContainText('Try adjusting your search');

    // The onboarding affordances are the point of the state; a title swap
    // without them would be a cosmetic change that helps nobody.
    await expect(empty.locator('a:has-text("Set up a log source")')).toHaveAttribute(
      'href',
      '#settings/agents'
    );
    const docs = empty.locator('a:has-text("Read the docs")');
    await expect(docs).toHaveAttribute('href', 'https://purlogs.com/docs');
    await expect(docs, 'an external docs link must not leak window.opener').toHaveAttribute(
      'rel',
      /noopener/
    );

    // The copy-pasteable first request.
    const snippet = empty.locator('.ingest-snippet');
    await expect(snippet).toBeVisible();
    await expect(snippet.locator('code')).toContainText('curl -X POST');
    await expect(snippet.locator('code')).toContainText('X-API-Key');
    await expect(snippet.locator('button.copy-btn')).toHaveAttribute('aria-label', 'Copy command');
  });

  test('an instance that HAS ingested gets the neutral empty state', async ({ page }) => {
    await pinLogsPage(page, { stats: 12_345 });
    await login(page);
    await gotoTab(page, 'Logs');

    const empty = page.locator('.log-table-container .empty-state');
    await expect(empty).toBeVisible();
    await expect(empty.locator('.empty-title')).toHaveText('No logs found');
    await expect(empty).toContainText('Try adjusting your search');
    await expect(
      empty.locator('.ingest-snippet'),
      'a user with 12k stored logs must never be told to send their first one'
    ).toHaveCount(0);
  });

  test('a failed /api/stats probe falls back to the neutral state, never to onboarding', async ({ page }) => {
    await pinLogsPage(page, { stats: 'fail' });
    await login(page);
    await gotoTab(page, 'Logs');

    const empty = page.locator('.log-table-container .empty-state');
    await expect(empty).toBeVisible();

    // `hasEverIngested` must stay null on failure. If it ever coerces to false
    // (a `Number(undefined) || 0`, a `catch { return 0 }`), this flips to the
    // onboarding copy and the product starts lying to its biggest customers.
    await expect(
      empty.locator('.empty-title'),
      'an unknown ingest history must render the neutral state, not "No logs yet"'
    ).toHaveText('No logs found');
    await expect(empty.locator('.ingest-snippet')).toHaveCount(0);
  });
});
