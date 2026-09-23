import { test, expect } from '@playwright/test';
import { login, gotoTab, ingestLogs, logEntry, waitForIngested, unique, stackEnv } from './fixtures/purl.js';

/**
 * The Traces page.
 *
 * Traces are not a separate ingest path: `trace_id` / `span_id` are columns on
 * ordinary log rows, so a spec can manufacture a trace with the normal
 * `POST /api/logs` fixture. The page is not role-gated.
 *
 * Lowercase hex only: the lookup lowercases the id and strips anything outside
 * [a-fA-F0-9-] before matching, so an uppercase id ingested verbatim will not
 * be found. The helper below keeps that constraint in one place.
 */

/** A trace id in the shape the backend can actually look up. */
function traceId() {
  return unique('').replace(/[^a-f0-9]/gi, '').toLowerCase().padEnd(16, '0').slice(0, 16);
}

test.describe('Traces', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('a trace built from ingested logs is listed under Recent Traces', async ({ page, request }) => {
    const id = traceId();
    const marker = unique('tracemark');

    await ingestLogs(request, [
      logEntry({ message: `${marker} inbound`, service: 'api-gw', trace_id: id, span_id: 'aaaa0001' }),
      logEntry({ message: `${marker} downstream`, service: 'billing', trace_id: id, span_id: 'aaaa0002' }),
    ]);
    await waitForIngested(request, marker);

    await gotoTab(page, 'Traces');

    // The recent list is the page's landing state — no search required.
    const row = page.locator('tr.trace-row', { hasText: id });
    await expect(row, 'the ingested trace must appear in Recent Traces').toBeVisible({
      timeout: 30_000,
    });

    // Both services that emitted a span must be attributed to the trace,
    // otherwise the grouping query has silently collapsed them.
    await expect(row.locator('.col-services')).toContainText('api-gw');
    await expect(row.locator('.col-services')).toContainText('billing');
    await expect(row.locator('.col-count'), 'both spans must be counted').toContainText('2');
  });

  test('the recent-traces empty state is shown when a range holds no traces', async ({ page }) => {
    // A 1h window on a fresh stack that has only just been written to still
    // shows rows, so assert the empty state through an intercepted response
    // rather than by manipulating time.
    await page.route(
      (url) => url.pathname === '/api/traces/recent',
      (route) =>
        route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ total: 0, traces: [] }),
        })
    );

    await gotoTab(page, 'Traces');
    await expect(page.getByText('No traces found')).toBeVisible();
  });

  test('opening a trace shows its logs', async ({ page, request }) => {
    const id = traceId();
    const marker = unique('tracemark');

    await ingestLogs(request, [
      logEntry({ message: `${marker} inbound`, service: 'api-gw', trace_id: id, span_id: 'bbbb0001' }),
      logEntry({ message: `${marker} downstream`, service: 'billing', trace_id: id, span_id: 'bbbb0002' }),
    ]);
    await waitForIngested(request, marker);

    // The API genuinely has the rows — asserted first so a failure below can
    // only mean the PAGE lost them, never that the fixture failed to ingest.
    const api = await request.get(`/api/traces/${id}?limit=50`, {
      headers: { 'X-API-Key': stackEnv.API_KEY },
    });
    expect(api.ok(), `GET /api/traces/${id} failed: ${api.status()}`).toBe(true);
    const payload = await api.json();
    expect(payload.total, 'the backend must hold both log rows for this trace').toBeGreaterThanOrEqual(2);

    await gotoTab(page, 'Traces');
    await page.locator('.search-section .search-bar input').fill(id);
    await page.locator('.search-bar button:has-text("Search")').click();

    // The logs the API just returned must be rendered.
    await expect(
      page.locator('table.logs-table tr.log-row').first(),
      'a trace the API can serve must render its log rows'
    ).toBeVisible({ timeout: 30_000 });
    await expect(page.locator('table.logs-table')).toContainText(marker);

    // And the page must not simultaneously claim the trace is empty.
    await expect(
      page.getByText(`No logs found for trace "${id}"`),
      'the page must not report an existing trace as empty'
    ).toHaveCount(0);
  });
});
