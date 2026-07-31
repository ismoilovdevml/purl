import { test, expect } from '@playwright/test';
import { login, gotoTab, expandSidebarPanel, unique } from './fixtures/purl.js';

/**
 * An optimistic alert row that the server never confirms must expire — and say
 * so — even when the confirming request is the thing that is broken.
 *
 * The bug: the TTL sweep lived inside `loadAlerts()`'s `try`, after the
 * `await api.get('/alerts')`. So it only ran when that call SUCCEEDED. The one
 * situation the TTL exists for — the server is down, the write may never have
 * landed — was precisely the situation where the sweep was skipped, and the
 * dashed ghost row sat on screen for as long as the panel stayed open, above a
 * success toast that said the alert had been created.
 *
 * The fix moves the sweep into `finally` and raises an explicit error toast per
 * expired row: expiry is not confirmation, and the user was already told the
 * write succeeded, so they have to hear that it did not.
 *
 * Time is faked with page.clock — the TTL is 90s and the poll is 60s, so the
 * real-time version of this test would take over two minutes and hold up every
 * run. Everything else (the requests, the DOM) is real.
 */
test.describe('Alert pending-row TTL', () => {
  test('an unconfirmed alert row expires and the failure is announced, even while GET /alerts is down', async ({ page }) => {
    const name = unique('e2e-ghost');
    let listShouldFail = false;

    await page.route(
      (url) => url.pathname === '/api/alerts',
      async (route) => {
        const method = route.request().method();
        if (method === 'POST') {
          // The write "succeeds" — this is what produces the optimistic row
          // and the success toast the user is entitled to believe.
          return route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify({ status: 'ok' }),
          });
        }
        if (method !== 'GET') return route.fallback();
        if (listShouldFail) {
          return route.fulfill({
            status: 500,
            contentType: 'application/json',
            body: JSON.stringify({ error: 'ClickHouse unreachable' }),
          });
        }
        // The server never learns about the alert: the list stays empty, so
        // the optimistic row can only ever leave via the TTL.
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ alerts: [] }),
        });
      }
    );

    // Must be installed before the app boots so the panel's setInterval and
    // the row's `createdAt` share the same fake clock.
    await page.clock.install();

    await login(page);
    await gotoTab(page, 'Logs');
    const panel = await expandSidebarPanel(page, '.alerts-panel');

    // --- create, and take the server down at the same moment -----------
    await panel.locator('[title="Create alert"]').click();
    const modal = page.locator('[role="dialog"]');
    await modal.getByLabel('Name', { exact: true }).fill(name);
    await modal.locator('select.select-field').selectOption('telegram');

    listShouldFail = true;
    await modal.locator('.modal-footer button.btn-success').click();

    // The optimistic row is on screen, marked pending, with its actions
    // disabled because it has no real server id yet.
    const ghost = panel.locator('.content li.pending', { hasText: name });
    await expect(ghost).toHaveCount(1);
    await expect(ghost.locator('.delete-btn')).toBeDisabled();

    // --- and it does NOT disappear before its time ---------------------
    await page.clock.fastForward('01:00'); // 60s: one poll, still inside the TTL
    await expect(
      panel.locator('.content li.pending', { hasText: name }),
      'the row must survive until the TTL actually elapses'
    ).toHaveCount(1);

    // --- past the 90s TTL ----------------------------------------------
    await page.clock.fastForward('02:00');

    await expect(
      panel.locator('.content li', { hasText: name }),
      'an unconfirmed row must be swept even though GET /alerts is failing'
    ).toHaveCount(0);

    // Vanishing quietly would leave the user believing the success toast.
    // The wording is deliberately "could not confirm", not "was not saved":
    // the pending row only exists after POST /alerts returned 2xx, so the
    // client knows the write was not echoed back — never that it did not
    // persist. Claiming otherwise made users recreate alerts that already
    // existed, producing duplicate notifications.
    await expect(
      page.locator('.toast.toast-warning', { hasText: `Could not confirm alert "${name}"` })
    ).toBeVisible();
  });

  test('a confirmed alert row is never swept and never announced as lost', async ({ page }) => {
    // The other half of the contract: the sweep must not fire on rows the
    // server did acknowledge, or every successful create would eventually
    // produce a false "could not confirm" alarm.
    const name = unique('e2e-real');
    let confirmed = false;

    await page.route(
      (url) => url.pathname === '/api/alerts',
      async (route) => {
        const method = route.request().method();
        if (method === 'POST') {
          confirmed = true;
          return route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify({ status: 'ok' }),
          });
        }
        if (method !== 'GET') return route.fallback();
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            alerts: confirmed
              ? [
                  {
                    id: '11111111-1111-1111-1111-111111111111',
                    name,
                    query: '',
                    threshold: 10,
                    window_minutes: 5,
                    notify_type: 'telegram',
                    notify_target: '',
                    enabled: 1,
                    last_triggered: null,
                  },
                ]
              : [],
          }),
        });
      }
    );

    await page.clock.install();
    await login(page);
    await gotoTab(page, 'Logs');
    const panel = await expandSidebarPanel(page, '.alerts-panel');

    await panel.locator('[title="Create alert"]').click();
    const modal = page.locator('[role="dialog"]');
    await modal.getByLabel('Name', { exact: true }).fill(name);
    await modal.locator('select.select-field').selectOption('telegram');
    await modal.locator('.modal-footer button.btn-success').click();

    const row = panel.locator('.content li', { hasText: name });
    await expect(row).toHaveCount(1);
    await expect(panel.locator('.content li.pending', { hasText: name })).toHaveCount(0);

    await page.clock.fastForward('05:00');

    await expect(row, 'a confirmed alert must outlive the pending TTL').toHaveCount(1);
    await expect(
      page.locator('.toast.toast-warning', { hasText: 'Could not confirm' }),
      'a confirmed alert must never be reported as unconfirmed'
    ).toHaveCount(0);
  });
});
