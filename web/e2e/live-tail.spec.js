import { test, expect } from '@playwright/test';
import { login, gotoTab, ingestLogs, logEntry, unique } from './fixtures/purl.js';

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
    await page.addInitScript(() => {
      const raw = window.localStorage.getItem('purl_settings');
      const parsed = raw ? JSON.parse(raw) : {};
      parsed.refreshInterval = 0;
      window.localStorage.setItem('purl_settings', JSON.stringify(parsed));
    });
    await page.reload();

    await gotoTab(page, 'Logs');

    const frames = [];
    page.on('websocket', (ws) => {
      ws.on('framereceived', (f) => frames.push(f.payload));
    });

    const liveButton = page.locator('.search-bar button:has-text("Live")');
    await liveButton.click();
    await expect(page.locator('.search-bar .live-indicator.active')).toBeVisible();

    // Wait for the greeting so the subscription is definitely established
    // before anything is ingested — otherwise a miss here would be a race in
    // the test rather than a defect in the product.
    await expect
      .poll(() => frames.some((f) => typeof f === 'string' && f.includes('"connected"')), {
        message: 'socket must be established before ingesting',
        timeout: 20_000,
      })
      .toBe(true);

    const marker = unique('tailmark');
    await ingestLogs(request, [logEntry({ message: `${marker} streamed line`, level: 'ERROR' })]);

    // The whole point of live tail: no reload, no Refresh click.
    await expect(
      page.locator('.log-table', { hasText: marker }).first(),
      'a log ingested while tailing must appear in the table with no manual refresh'
    ).toBeVisible({ timeout: 30_000 });
  });
});
