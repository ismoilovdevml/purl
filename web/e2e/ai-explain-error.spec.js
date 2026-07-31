import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * A failed AI explanation must be POSTed exactly ONCE.
 *
 * `explainLog()` resolves with `null` on failure instead of rejecting, so the
 * modal's reactive guard — `if (open && log && !result && !loading)` — went
 * true again the instant the failed request settled, and fired another POST on
 * every subsequent invalidation. The user never saw an error state (it was
 * overwritten immediately), and each retry was a *billed* upstream LLM call:
 * a 200 carrying `{ error: ... }` means the provider already ran and charged.
 *
 * NOTE on the shape of the bug, corrected from the original issue #32 text:
 * this is not a free-running infinite loop. Svelte 5 runs the guard once per
 * invalidation, so it is "another billed call on every invalidation for as long
 * as the modal stays open", with no ceiling across a session — bad enough, and
 * what this spec measures. Do not assert "hundreds of POSTs in 3 seconds";
 * that does not reproduce.
 *
 * The fix adds a sticky `aiExplainError` store that the guard honours. This
 * spec pins the count at 1 and proves the error UI is reachable, which it
 * previously was not.
 *
 * AI is off on the e2e stack (no provider key), so /api/ai/providers is
 * intercepted to unlock the entry point. That is the honest way to test this:
 * the alternative is a real, billed LLM call in CI.
 */
test.describe('AI explain error handling', () => {
  let explainCalls = 0;
  /** 'error-200' = HTTP 200 carrying {error}, the already-billed case. */
  let mode = 'error-200';

  test.beforeEach(async ({ page }) => {
    explainCalls = 0;
    mode = 'error-200';

    await page.route(
      (url) => url.pathname === '/api/ai/providers',
      (route) =>
        route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            current: 'openai',
            configured: true,
            providers: [{ id: 'openai', name: 'OpenAI' }],
          }),
        })
    );

    await page.route(
      (url) => url.pathname === '/api/logs',
      async (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            hits: [
              {
                id: 'ai-1',
                timestamp: new Date().toISOString(),
                level: 'ERROR',
                service: 'e2e',
                host: 'e2e-host',
                message: 'connection reset by peer',
              },
            ],
            total: 1,
          }),
        });
      }
    );

    await page.route(
      (url) => url.pathname === '/api/ai/explain',
      async (route) => {
        explainCalls += 1;
        if (mode === 'ok') {
          return route.fulfill({
            status: 200,
            contentType: 'application/json',
            body: JSON.stringify({ explanation: 'The upstream peer closed the socket.' }),
          });
        }
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'AI provider rate limit exceeded' }),
        });
      }
    );

    await login(page);
    await gotoTab(page, 'Logs');
  });

  const openExplain = async (page) => {
    await page.locator('tr.log-row').first().click();
    await page.locator('.ai-explain-btn').click();
    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible();
    return modal;
  };

  test('a failed explanation POSTs once, shows the error, and stays put', async ({ page }) => {
    const modal = await openExplain(page);

    // The error state is reachable at all — before the fix it was overwritten
    // by the next run before it could ever render.
    const empty = modal.locator('.empty-state');
    await expect(empty.locator('.empty-title')).toHaveText('Could not explain this log');
    await expect(empty).toContainText('AI provider rate limit exceeded');

    expect(explainCalls, 'a failed explanation must be requested exactly once').toBe(1);

    // Now provoke invalidations. Each one used to fire another billed POST.
    for (let i = 0; i < 5; i++) {
      await page.mouse.move(200 + i * 10, 200 + i * 10);
      await modal.locator('.modal-close').hover();
      await page.waitForTimeout(200);
    }

    await expect(empty.locator('.empty-title')).toHaveText('Could not explain this log');
    expect(
      explainCalls,
      `the sticky error store must suppress re-runs; saw ${explainCalls} POSTs to /api/ai/explain`
    ).toBe(1);
  });

  test('Retry issues exactly one more request and can succeed', async ({ page }) => {
    const modal = await openExplain(page);
    await expect(modal.locator('.empty-state .empty-title')).toHaveText('Could not explain this log');
    expect(explainCalls).toBe(1);

    mode = 'ok';
    await modal.locator('.empty-state button:has-text("Retry")').click();

    await expect(modal).toContainText('The upstream peer closed the socket.');
    await expect(modal.locator('.empty-state')).toHaveCount(0);
    expect(explainCalls, 'Retry is one more call, not a new stream of them').toBe(2);

    // And a SUCCEEDED explanation must not re-request either.
    await page.waitForTimeout(500);
    expect(explainCalls).toBe(2);
  });
});
