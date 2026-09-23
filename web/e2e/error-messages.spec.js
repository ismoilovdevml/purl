import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * #107: during a ClickHouse outage the UI rendered raw backend text — the
 * ClickHouse exception with on-disk paths and table UUIDs, Perl's
 * "at /app/lib/... line 45.", double-encoded UTF-8 — and stacked the same
 * error toast several times.
 *
 * Contract (utils/apiErrors.js): the UI branches on `code`, never on message
 * text. Outage/overload/timeout/internal codes get our own wording plus a
 * copyable "Reference: <request_id>" (body or X-Request-Id header), and a
 * `retry_after` schedules one visible automatic retry; `invalid_query` keeps the
 * server's (sanitized) message because it tells the user what to fix; an old
 * server's bare `{error}` is shown only if it is clean. One outage → one
 * inline failure state with Retry, not a toast per panel.
 */

const RAW_CLICKHOUSE =
  'Code: 241. DB::Exception: Memory limit (total) exceeded: would use 3.51 GiB, ' +
  'while reading /var/lib/clickhouse/store/3f2/3f2a9c1e-8b7d-4e21-9c55-0a1b2c3d4e5f/all_1_1_0/ ' +
  'at /app/lib/Purl/Storage/ClickHouse/CircuitBreaker.pm line 45.';

/** Text that must never be on screen, whatever the server sent. */
const LEAKS = [/\/app\//, /\bline \d+/, /DB::Exception/, /\/var\/lib\//, /3f2a9c1e-8b7d/, /â€/];

async function expectNoLeaks(page) {
  const text = await page.locator('body').innerText();
  for (const re of LEAKS) {
    expect(text, `rendered page must not contain ${re}`).not.toMatch(re);
  }
}

/** Serve the logs page's data endpoints from the given `() => [status, body]` handlers. */
async function failDataEndpoints(page, { logs, patterns, stats }) {
  const json = ([status, body]) => ({ status, contentType: 'application/json', body: JSON.stringify(body) });
  await page.route(
    (url) => url.pathname === '/api/logs',
    (route) => (route.request().method() === 'GET' ? route.fulfill(json(logs())) : route.fallback())
  );
  if (patterns) {
    await page.route((url) => url.pathname === '/api/patterns', (route) => route.fulfill(json(patterns())));
  }
  if (stats) {
    await page.route((url) => url.pathname.startsWith('/api/stats/'), (route) => route.fulfill(json(stats())));
  }
}

const failure = (page) => page.locator('.log-table-container .empty-state');

test.describe('User-facing API errors (#107)', () => {
  const CASES = [
    {
      name: 'storage_unavailable',
      status: 503,
      body: { error: 'Search is temporarily unavailable', code: 'storage_unavailable', request_id: 'req-503-abc' },
      expected: 'Search is temporarily unavailable. Try again in a moment.',
      requestId: 'req-503-abc',
    },
    {
      name: 'storage_overloaded',
      status: 503,
      body: { error: RAW_CLICKHOUSE, code: 'storage_overloaded', request_id: 'req-ovl-1' },
      expected: 'The log store is overloaded right now.',
      requestId: 'req-ovl-1',
    },
    {
      name: 'query_timeout',
      status: 504,
      body: { error: 'timeout', code: 'query_timeout', request_id: 'req-504' },
      expected: 'The query took too long.',
      requestId: 'req-504',
    },
    {
      name: 'internal',
      status: 500,
      body: { error: RAW_CLICKHOUSE, code: 'internal', request_id: 'req-500' },
      expected: 'Something went wrong on the server.',
      requestId: 'req-500',
    },
    {
      name: 'invalid_query keeps the server hint',
      status: 400,
      body: { error: 'Unexpected token "AND" at position 12', code: 'invalid_query', request_id: 'req-400' },
      expected: 'Unexpected token "AND" at position 12',
      requestId: 'req-400',
    },
    {
      name: 'invalid_query with leaked internals falls back to our wording',
      status: 400,
      body: { error: RAW_CLICKHOUSE, code: 'invalid_query' },
      expected: 'The query could not be understood.',
      requestId: null,
    },
    {
      name: 'old server: raw 500 {error} only',
      status: 500,
      body: { error: RAW_CLICKHOUSE },
      expected: 'Something went wrong on the server.',
      requestId: null,
    },
    {
      name: 'old server: mojibake 503 {error} only',
      status: 503,
      body: { error: 'circuit open â€ service unavailable' },
      expected: 'Search is temporarily unavailable.',
      requestId: null,
    },
  ];

  for (const c of CASES) {
    test(`search failure: ${c.name}`, async ({ page }) => {
      let fail = false;
      await failDataEndpoints(page, { logs: () => (fail ? [c.status, c.body] : [200, { hits: [], total: 0 }]) });
      await login(page);
      await gotoTab(page, 'Logs');
      fail = true;

      await page.locator('.header-actions button.btn', { hasText: 'Refresh' }).click();

      await expect(failure(page).locator('.empty-title')).toHaveText('Search failed');
      await expect(failure(page)).toContainText(c.expected);
      if (c.requestId) {
        await expect(failure(page).locator('.request-id')).toContainText(c.requestId);
      } else {
        await expect(failure(page).locator('.request-id')).toHaveCount(0);
      }
      await expectNoLeaks(page);
    });
  }

  test('retry_after schedules one automatic retry; X-Request-Id is the fallback reference', async ({ page }) => {
    let fail = false;
    let calls = 0;
    await page.route(
      (url) => url.pathname === '/api/logs',
      (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        calls += 1;
        if (!fail) {
          return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ hits: [], total: 0 }) });
        }
        return route.fulfill({
          status: 503,
          contentType: 'application/json',
          headers: { 'X-Request-Id': 'hdr-req-42', 'Retry-After': '30' },
          body: JSON.stringify({ error: 'Search is temporarily unavailable', code: 'storage_unavailable', retry_after: 2 }),
        });
      }
    );
    await login(page);
    await gotoTab(page, 'Logs');
    fail = true;

    await page.locator('.header-actions button.btn', { hasText: 'Refresh' }).click();
    await expect(failure(page).locator('.request-id')).toHaveText('Reference: hdr-req-42');
    // The body's retry_after (2s) wins over the header's 30s.
    await expect(failure(page).locator('.auto-retry')).toContainText('Retrying automatically in');

    const before = calls;
    fail = false;
    await expect.poll(() => calls, { timeout: 5_000 }).toBeGreaterThan(before);
    await expect(page.locator('.log-table-container .empty-title')).not.toHaveText('Search failed');
  });

  test('one outage across search, patterns and stats: one inline state, no toasts', async ({ page }) => {
    let down = true;
    const outage = () => [503, { error: RAW_CLICKHOUSE, code: 'storage_unavailable', request_id: 'req-outage' }];
    const okLogs = () => [200, { hits: [], total: 0 }];
    await failDataEndpoints(page, {
      logs: () => (down ? outage() : okLogs()),
      patterns: () => (down ? outage() : [200, { patterns: [] }]),
      stats: () => (down ? outage() : [200, { values: [], buckets: [] }]),
    });
    // Routes first, so not even the initial load reaches the real backend.
    await login(page);
    await gotoTab(page, 'Logs');

    // Three refreshes plus the patterns panel's own refresh, all failing.
    const refresh = page.locator('.header-actions button.btn', { hasText: 'Refresh' });
    for (let i = 0; i < 3; i += 1) {
      await refresh.click();
      await expect(failure(page).locator('.empty-title')).toHaveText('Search failed');
    }
    await page.getByRole('button', { name: 'Refresh patterns' }).click();

    await expect(failure(page)).toHaveCount(1);
    await expect(failure(page)).toContainText('Search is temporarily unavailable');
    // The patterns panel defers to the search failure instead of repeating it.
    await expect(page.locator('.patterns-content .error-state')).toHaveCount(0);
    await expect(page.locator('.patterns-content .muted-state')).toBeVisible();
    await expect(page.locator('.toast.toast-error')).toHaveCount(0);
    await expectNoLeaks(page);

    // Recovery: one Retry brings search (and patterns) back.
    down = false;
    await failure(page).locator('button:has-text("Retry search")').click();
    await expect(page.locator('.log-table-container .empty-title')).not.toHaveText('Search failed');
    await expect(page.locator('.patterns-content .muted-state')).toHaveCount(0);
    await expect(page.locator('.patterns-content .error-state')).toHaveCount(0);
  });

  test('stats failing while search works: one deduplicated toast, not one per facet', async ({ page }) => {
    await failDataEndpoints(page, {
      logs: () => [200, { hits: [], total: 0 }],
      stats: () => [503, { error: RAW_CLICKHOUSE }],
    });
    await login(page);
    await gotoTab(page, 'Logs');

    const refresh = page.locator('.header-actions button.btn', { hasText: 'Refresh' });
    for (let i = 0; i < 3; i += 1) {
      await refresh.click();
      await expect(refresh).toBeEnabled();
    }

    const toasts = page.locator('.toast.toast-error');
    await expect(toasts).toHaveCount(1);
    await expect(toasts).toContainText('Search is temporarily unavailable');
    await expect(toasts.locator('.toast-count')).toHaveText(/×[2-9]/);
    await expectNoLeaks(page);
  });
});
