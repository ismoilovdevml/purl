import { test, expect } from '@playwright/test';
import { login, gotoTab, ingestLogs, logEntry, unique } from './fixtures/purl.js';

/** Turn off the Logs page's polling so the stream is the only way rows arrive. */
async function disableAutoRefresh(page) {
  await page.addInitScript(() => {
    const raw = window.localStorage.getItem('purl_settings');
    const parsed = raw ? JSON.parse(raw) : {};
    parsed.refreshInterval = 0;
    window.localStorage.setItem('purl_settings', JSON.stringify(parsed));
  });
  await page.reload();
}

/** Click Live and wait for the server's greeting, so nothing ingested after this is missed. */
async function startLive(page) {
  const frames = [];
  page.on('websocket', (ws) => {
    ws.on('framereceived', (f) => frames.push(f.payload));
  });
  await page.locator('.search-bar button:has-text("Live")').click();
  await expect
    .poll(() => frames.some((f) => typeof f === 'string' && f.includes('"connected"')), {
      message: 'socket must be established before ingesting',
      timeout: 20_000,
    })
    .toBe(true);
  return frames;
}

/**
 * Record the text of every log row the table ever inserts.
 *
 * The table is virtualised and live rows are prepended, so on a stack with
 * real traffic a streamed line is pushed out of the render window within a
 * second. "Is it in the DOM now" then tests scroll position, not delivery;
 * "was it ever rendered" tests delivery.
 */
async function recordRenderedRows(page) {
  await page.evaluate(() => {
    window.__renderedRows = [];
    const table = document.querySelector('.log-table');
    new MutationObserver((mutations) => {
      for (const m of mutations) {
        for (const node of m.addedNodes) {
          if (node.nodeType === 1 && node.matches('tr.log-row')) {
            window.__renderedRows.push(node.textContent);
          }
        }
      }
    }).observe(table, { childList: true, subtree: true });
  });
}

/**
 * Live tail: the WebSocket stream behind the "Live" button on the Logs page.
 *
 * Nothing covered this before. It is available to every role, and it is the
 * only part of the product that pushes rather than polls — so it fails in ways no request/response spec can see.
 *
 * The two assertions are deliberately separate because they fail for different
 * reasons:
 *   1. the socket opens and the server greets it  -> transport/auth works
 *   2. an ingested line actually shows up in the table -> the frame the server
 *      sends is a frame the client understands
 * A test that only checked (1) would call live tail "working" while the pane
 * stayed empty forever, which is exactly the state the product is in.
 */
test.describe('Live tail', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('the Live button opens the stream and the server greets it', async ({ page }) => {
    await gotoTab(page, 'Logs');

    // Capture frames before the click so the greeting cannot be missed.
    const frames = [];
    const wsPromise = page.waitForEvent('websocket', { timeout: 20_000 });
    page.on('websocket', (ws) => {
      ws.on('framereceived', (f) => frames.push(f.payload));
    });

    const liveButton = page.locator('.search-bar button:has-text("Live")');
    await expect(liveButton).toBeVisible();
    await liveButton.click();

    const ws = await wsPromise;
    expect(ws.url(), 'live tail must connect to /api/logs/stream').toContain('/api/logs/stream');

    // The button reflects the live state — this is the only UI affordance for
    // "am I tailing?", since the liveStatus store is never rendered.
    await expect(
      page.locator('.search-bar .live-indicator.active'),
      'the Live button must show an active indicator while tailing'
    ).toBeVisible();

    await expect
      .poll(() => frames.find((f) => typeof f === 'string' && f.includes('"connected"')) || null, {
        message: 'the server must send its {"type":"connected"} greeting',
        timeout: 20_000,
      })
      .not.toBeNull();

    // Toggling off must close the socket rather than leave it dangling.
    await liveButton.click();
    await expect(page.locator('.search-bar .live-indicator.active')).toHaveCount(0);
  });

  test('a log ingested while tailing appears without a manual refresh', async ({ page, request }) => {
    /*
     * Auto-refresh MUST be off for this test to mean anything.
     *
     * The Logs page polls `searchLogs()` every `refreshInterval` seconds
     * (default 30, App.svelte:241). With polling on, an ingested line shows up
     * within ~30s whether or not the WebSocket delivered anything — the first
     * version of this test passed in 30.8s for exactly that reason and would
     * have stayed green with live tail entirely broken.
     *
     * 0 is a legal value (NUMERIC_BOUNDS.refreshInterval.min === 0) and
     * disables the interval, so the stream becomes the only path by which the
     * marker can reach the table.
     */
    await disableAutoRefresh(page);
    await gotoTab(page, 'Logs');

    // startLive waits for the greeting so the subscription is definitely
    // established before anything is ingested — otherwise a miss here would be
    // a race in the test rather than a defect in the product.
    await startLive(page);
    await expect(page.locator('.search-bar .live-indicator.active')).toBeVisible();

    const marker = unique('tailmark');
    await ingestLogs(request, [logEntry({ message: `${marker} streamed line`, level: 'ERROR' })]);

    // The whole point of live tail: no reload, no Refresh click.
    await expect(
      page.locator('.log-table', { hasText: marker }).first(),
      'a log ingested while tailing must appear in the table with no manual refresh'
    ).toBeVisible({ timeout: 30_000 });
  });

  test('a burst of same-timestamp logs all appear while tailing', async ({ page, request }) => {
    /*
     * Streamed logs carry no `id` (ClickHouse assigns it on insert), so the
     * client makes one up. It used to be `${timestamp}-${Date.now()}`, which is
     * identical for same-timestamp logs handled in the same millisecond — and
     * the table is a keyed {#each}. Svelte >= 5.5x throws each_key_duplicate
     * on that in production builds too, which froze the table mid-burst.
     *
     * Checked against rows the table rendered, not rows it shows right now:
     * on a busy instance other traffic pushes the burst below the virtual
     * render window within a second (#117).
     */
    const pageErrors = [];
    page.on('pageerror', (err) => pageErrors.push(err.message));

    // Something in the table first, so .log-table exists to observe.
    await ingestLogs(request, [logEntry({ message: `${unique('burst-seed')} seed line` })]);
    await disableAutoRefresh(page);
    await gotoTab(page, 'Logs');
    await expect(page.locator('.log-table tr.log-row').first()).toBeVisible({ timeout: 30_000 });
    await recordRenderedRows(page);
    const frames = await startLive(page);

    const marker = unique('burst');
    const timestamp = new Date().toISOString();
    const count = 25;
    await ingestLogs(
      request,
      Array.from({ length: count }, (_, i) =>
        logEntry({ timestamp, message: `${marker} line-${String(i).padStart(2, '0')}` })
      )
    );

    const linesIn = (texts) =>
      new Set(texts.flatMap((t) => (typeof t === 'string' ? t.match(new RegExp(`${marker} line-\\d\\d`, 'g')) || [] : []))).size;

    await expect
      .poll(() => linesIn(frames), { message: 'every burst line must arrive on the socket', timeout: 30_000 })
      .toBe(count);
    await expect
      .poll(async () => linesIn(await page.evaluate(() => window.__renderedRows)), {
        message: 'every burst line must be rendered in the table',
        timeout: 30_000,
      })
      .toBe(count);
    expect(pageErrors, 'rendering a same-timestamp burst must not throw').toEqual([]);
  });

  test('a high-rate stream renders without runtime errors', async ({ page, request }) => {
    /*
     * #117: under real traffic (~100 lines/s) starting Live threw dozens of
     * "Cannot read properties of undefined (reading 'prev')" from Svelte's
     * keyed-each reconcile, and a reconcile that throws mid-update can skip or
     * duplicate rows. Feed several hundred id-less lines a second for 10s,
     * starting while the first search's rows are on screen.
     */
    test.setTimeout(120_000);
    const pageErrors = [];
    page.on('pageerror', (err) => pageErrors.push(err.stack || err.message));

    const seed = unique('rate-seed');
    await ingestLogs(
      request,
      Array.from({ length: 300 }, (_, i) => logEntry({ message: `${seed} seed-${i}` }))
    );
    await disableAutoRefresh(page);
    await gotoTab(page, 'Logs');
    await expect(page.locator('.log-table tr.log-row').first()).toBeVisible({ timeout: 30_000 });
    await recordRenderedRows(page);
    const frames = await startLive(page);

    const marker = unique('rate');
    const BATCH = 40;
    const INTERVAL_MS = 100; // 40 lines every 100ms = 400 lines/s
    const deadline = Date.now() + 10_000;
    let sent = 0;
    while (Date.now() < deadline) {
      const started = Date.now();
      const timestamp = new Date().toISOString();
      await ingestLogs(
        request,
        Array.from({ length: BATCH }, (_, i) =>
          logEntry({ timestamp, message: `${marker} n-${sent + i}` })
        )
      );
      sent += BATCH;
      await page.waitForTimeout(Math.max(0, INTERVAL_MS - (Date.now() - started)));
    }

    const lastLine = `${marker} n-${sent - 1}`;
    await expect
      .poll(() => frames.some((f) => typeof f === 'string' && f.includes(`${lastLine}"`)), {
        message: 'the last line of the feed must arrive on the socket',
        timeout: 30_000,
      })
      .toBe(true);
    // Rendered, not "on top": any other log arriving afterwards is prepended above it.
    await expect
      .poll(() => page.evaluate((l) => window.__renderedRows.some((t) => t.includes(l)), lastLine), {
        message: 'the last line of the feed must be rendered',
        timeout: 15_000,
      })
      .toBe(true);

    expect(pageErrors, 'a high-rate live stream must not throw').toEqual([]);
    // A reconcile that throws skips rows. (A row may legitimately be drawn
    // twice when the virtual window grows, so count distinct lines.)
    const rendered = await page.evaluate(
      (m) => new Set(window.__renderedRows.flatMap((t) => t.match(new RegExp(`${m} n-\\d+`, 'g')) || [])).size,
      marker
    );
    expect(rendered, 'every streamed line must be rendered').toBe(sent);
  });

  test('streamed logs that carry their own duplicate "id" field still all render', async ({ page, request }) => {
    /*
     * `id` is an ordinary field to a sender (plenty of app logs have one), and
     * ingest accepts it. The table keys rows on `id`, so trusting a streamed
     * one lets two lines share a key and the keyed each throws (#117).
     */
    const pageErrors = [];
    page.on('pageerror', (err) => pageErrors.push(err.message));

    await ingestLogs(request, [logEntry({ message: `${unique('dupid-seed')} seed line` })]);
    await disableAutoRefresh(page);
    await gotoTab(page, 'Logs');
    await expect(page.locator('.log-table tr.log-row').first()).toBeVisible({ timeout: 30_000 });
    await startLive(page);

    const marker = unique('dupid');
    await ingestLogs(request, [
      logEntry({ id: 'same-id', message: `${marker} first` }),
      logEntry({ id: 'same-id', message: `${marker} second` }),
    ]);

    await expect(page.locator('.log-table tr.log-row', { hasText: `${marker} first` })).toHaveCount(1, { timeout: 30_000 });
    await expect(page.locator('.log-table tr.log-row', { hasText: `${marker} second` })).toHaveCount(1);
    expect(pageErrors, 'a duplicate sender-supplied id must not throw').toEqual([]);
  });
});
