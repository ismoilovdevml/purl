import { test, expect } from '@playwright/test';
import http from 'node:http';
import { login, ingestLogs, logEntry, waitForIngested, unique, csrfHeaders, stackEnv } from './fixtures/purl.js';

/**
 * Alert firing, end to end: condition -> evaluation -> channel dispatch.
 *
 * WHY THIS FILE EXISTS
 *
 * alerts-crud.spec.js covers the CRUD lifecycle and deliberately picks
 * `telegram` so that nothing is ever dispatched. alert-pending-ttl.spec.js
 * mocks `/api/alerts` wholesale with `page.route` and never touches the server.
 * So until now NOTHING asserted that an alert actually evaluates or that a
 * notification actually leaves the process — the entire point of the feature.
 *
 * HOW THE OUTBOUND NOTIFICATION IS CAPTURED (rather than mocked)
 *
 * A real HTTP listener is started in the test process and the alert's
 * `notify_target` points at it. `Purl::Alert::Webhook` performs no URL
 * validation whatsoever — the SSRF guard added in 0797b08 lives only in
 * Controller/Config.pm and guards `POST /api/config/test-clickhouse` — so a
 * private-network target is accepted and really POSTed to. The request
 * originates INSIDE the purl container, so the target must be
 * `host.docker.internal`, not `localhost`.
 *
 * This means the assertion is on the genuine outbound request Purl builds
 * (method, headers, JSON body), not on a stub of it.
 *
 * WHY EVALUATION IS FORCED RATHER THAN AWAITED
 *
 * The background timer defaults to 60s, is leader-gated and runs in a forked
 * subprocess. `POST /api/alerts/check` runs the SAME Scheduler synchronously in
 * the request and returns what fired, so the test is deterministic and fast.
 * Delivery is synchronous and single-attempt, so by the time that response
 * returns, the webhook has already been delivered.
 */

/** A throwaway HTTP server that records what Purl POSTs to it. */
async function startWebhookListener() {
  const received = [];

  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      let json = null;
      try {
        json = JSON.parse(raw);
      } catch {
        // Recorded as null; the assertions below say what was expected.
      }
      received.push({ method: req.method, headers: req.headers, raw, json });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
    });
  });

  // Port 0 = let the OS pick a free one, so parallel checkouts cannot collide.
  await new Promise((resolve) => server.listen(0, '0.0.0.0', resolve));

  return {
    received,
    // Reachable from inside the purl container; `localhost` there is the
    // container itself and would silently deliver nowhere.
    url: `http://host.docker.internal:${server.address().port}/hook`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

/** Find an alert by name in GET /api/alerts. */
async function findAlert(page, name) {
  const res = await page.request.get('/api/alerts');
  expect(res.ok(), `GET /api/alerts failed: ${res.status()}`).toBe(true);
  const { alerts } = await res.json();
  return (alerts || []).find((a) => a.name === name) || null;
}

test.describe('Alert firing', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('a breached threshold evaluates, fires, and POSTs to the webhook target', async ({ page, request }) => {
    const listener = await startWebhookListener();
    const name = unique('e2e-fire');
    // A marker unique to this run: it is both the log message and the alert
    // query, so no other spec's logs can push this alert over its threshold.
    const marker = unique('firemark');
    const headers = await csrfHeaders(page);

    try {
      const created = await page.request.post('/api/alerts', {
        headers,
        data: {
          name,
          query: marker,
          threshold: 2,
          window_minutes: 5,
          notify_type: 'webhook',
          notify_target: listener.url,
        },
      });
      expect(
        created.status(),
        `POST /api/alerts failed: ${created.status()} ${await created.text()}`
      ).toBe(200);

      // --- below threshold: must NOT fire -----------------------------
      // Without this half the test would pass against a server that fires
      // unconditionally, which is the more dangerous bug (alert spam).
      await ingestLogs(request, [logEntry({ message: `${marker} first` })]);
      await waitForIngested(request, marker);

      const early = await page.request.post('/api/alerts/check', { headers });
      expect(early.ok(), `POST /api/alerts/check failed: ${early.status()}`).toBe(true);
      const earlyBody = await early.json();
      expect(
        (earlyBody.triggered || []).map((a) => a.name),
        '1 matching log must not trip a threshold of 2'
      ).not.toContain(name);
      expect(listener.received, 'no webhook may be sent below the threshold').toHaveLength(0);

      // --- at threshold: must fire ------------------------------------
      await ingestLogs(request, [logEntry({ message: `${marker} second` })]);
      await expect
        .poll(
          async () => {
            const res = await request.get(
              `/api/logs?limit=50&range=15m&q=${encodeURIComponent(marker)}`,
              { headers: { 'X-API-Key': stackEnv.API_KEY } }
            );
            return res.ok() ? (await res.json()).total ?? 0 : 0;
          },
          { message: 'both marker logs must be searchable before the alert is evaluated' }
        )
        .toBeGreaterThanOrEqual(2);

      const fired = await page.request.post('/api/alerts/check', { headers });
      expect(fired.ok(), `POST /api/alerts/check failed: ${fired.status()}`).toBe(true);
      const firedBody = await fired.json();

      const triggered = (firedBody.triggered || []).find((a) => a.name === name);
      expect(
        triggered,
        `alert did not fire. triggered=${JSON.stringify(firedBody.triggered)}`
      ).toBeTruthy();
      expect(triggered.count).toBeGreaterThanOrEqual(2);

      // The server's own account of what it dispatched.
      const dispatched = (firedBody.notifications || []).find((n) => n.alert === name);
      expect(dispatched, `no notification recorded: ${JSON.stringify(firedBody.notifications)}`).toBeTruthy();
      expect(dispatched.sent).toContain('webhook');

      // --- the actual outbound request --------------------------------
      // Delivery is synchronous, but assert via poll so a slow loopback
      // cannot make this flaky.
      await expect
        .poll(() => listener.received.length, { message: 'Purl must POST to the webhook target' })
        .toBe(1);

      const hook = listener.received[0];
      expect(hook.method).toBe('POST');
      expect(hook.headers['content-type']).toMatch(/application\/json/);
      expect(hook.headers['user-agent']).toBe('Purl-Alert/1.0');

      expect(hook.json, `webhook body was not JSON: ${hook.raw}`).not.toBeNull();
      expect(hook.json.event).toBe('purl.alert');
      expect(hook.json.alert.alert).toBe(name);
      expect(hook.json.alert.query).toBe(marker);
      expect(hook.json.alert.threshold).toBe(2);
      expect(hook.json.alert.count).toBeGreaterThanOrEqual(2);
      // count(2) < threshold*2(4), so this is a warning, not critical.
      expect(hook.json.alert.severity).toBe('warning');

      // --- persisted firing state -------------------------------------
      // `last_triggered` is written with mutations_sync=1, so it is readable
      // immediately. Epoch zero means "never fired".
      const after = await findAlert(page, name);
      expect(after, 'alert vanished from the list').toBeTruthy();
      expect(after.last_triggered).not.toBe('1970-01-01T00:00:00Z');

      // --- cooldown ---------------------------------------------------
      // Re-checking inside window_minutes must not re-notify, or every check
      // interval would spam the channel for as long as the logs stay in range.
      const again = await page.request.post('/api/alerts/check', { headers });
      expect(again.ok()).toBe(true);
      await expect
        .poll(() => listener.received.length, { message: 'cooldown must suppress a second dispatch' })
        .toBe(1);
    } finally {
      const existing = await findAlert(page, name);
      if (existing) {
        await page.request.delete(`/api/alerts/${existing.id}`, { headers });
      }
      await listener.close();
    }
  });

  test('a disabled alert is not evaluated and dispatches nothing', async ({ page, request }) => {
    const listener = await startWebhookListener();
    const name = unique('e2e-off');
    const marker = unique('offmark');
    const headers = await csrfHeaders(page);

    try {
      const created = await page.request.post('/api/alerts', {
        headers,
        data: {
          name,
          query: marker,
          threshold: 1,
          window_minutes: 5,
          notify_type: 'webhook',
          notify_target: listener.url,
        },
      });
      expect(created.status(), `POST /api/alerts failed: ${await created.text()}`).toBe(200);

      const alert = await findAlert(page, name);
      expect(alert, 'alert was not created').toBeTruthy();

      const disabled = await page.request.put(`/api/alerts/${alert.id}`, {
        headers,
        data: { enabled: 0 },
      });
      expect(disabled.ok(), `PUT /api/alerts failed: ${await disabled.text()}`).toBe(true);

      // Enough matching logs to breach the threshold several times over.
      await ingestLogs(request, [
        logEntry({ message: `${marker} a` }),
        logEntry({ message: `${marker} b` }),
      ]);
      await waitForIngested(request, marker);

      const res = await page.request.post('/api/alerts/check', { headers });
      expect(res.ok()).toBe(true);
      const body = await res.json();

      expect(
        (body.triggered || []).map((a) => a.name),
        'a disabled alert must never be evaluated'
      ).not.toContain(name);
      expect(listener.received, 'a disabled alert must dispatch nothing').toHaveLength(0);

      const after = await findAlert(page, name);
      expect(after.last_triggered, 'a disabled alert must not record a firing').toBe(
        '1970-01-01T00:00:00Z'
      );
    } finally {
      const existing = await findAlert(page, name);
      if (existing) {
        await page.request.delete(`/api/alerts/${existing.id}`, { headers });
      }
      await listener.close();
    }
  });
});
