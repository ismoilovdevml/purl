import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * #96 — "Ask AI" → "Apply as search" applies the generated query.
 *
 * SearchBar forwarded the AI result through `onaiapply`, but LogsToolbar never
 * passed one, so the button closed the AI bar and nothing else happened. The
 * query must land in the search bar and a search must run with it.
 *
 * AI is off on the e2e stack (no provider key): /api/ai/providers is mocked to
 * unlock the entry point and /api/ai/query to answer without a billed LLM
 * call. /api/logs is mocked so the assertion is about the request the page
 * makes, not about whether the stack's search parser accepts the text.
 */
const GENERATED = "SELECT * FROM purl.logs WHERE level = 'ERROR' ORDER BY timestamp DESC LIMIT 100";

test.describe('Ask AI apply (#96)', () => {
  let aiQueryBodies;

  test.beforeEach(async ({ page }) => {
    aiQueryBodies = [];

    await page.route(
      (url) => url.pathname === '/api/ai/providers',
      (route) => route.fulfill({
        json: { current: 'openai', configured: true, providers: [{ id: 'openai', name: 'OpenAI' }] },
      })
    );
    await page.route(
      (url) => url.pathname === '/api/ai/suggest',
      (route) => route.fulfill({ json: { suggestions: [] } })
    );
    await page.route(
      (url) => url.pathname === '/api/ai/query',
      (route) => {
        aiQueryBodies.push(route.request().postDataJSON());
        return route.fulfill({
          json: {
            sql: GENERATED,
            results: [{ level: 'ERROR', message: 'boom' }],
            total: 1,
          },
        });
      }
    );
    await page.route(
      (url) => url.pathname === '/api/logs',
      (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        return route.fulfill({ json: { hits: [], total: 0 } });
      }
    );

    await login(page);
    await gotoTab(page, 'Logs');
  });

  test('Apply as search puts the generated query in the search bar and runs it', async ({ page }) => {
    await page.locator('.ai-toggle-btn', { hasText: 'Ask AI' }).click();

    const bar = page.locator('.ai-query-bar');
    await expect(bar).toBeVisible();
    await bar.locator('textarea.ai-input').fill('show me errors from the last hour');
    await bar.locator('button[aria-label="Send question to AI"]').click();

    await expect(bar.locator('pre.sql-block')).toHaveText(GENERATED);
    expect(aiQueryBodies).toHaveLength(1);
    expect(aiQueryBodies[0].question).toBe('show me errors from the last hour');

    const searched = page.waitForRequest((req) => {
      const url = new URL(req.url());
      return url.pathname === '/api/logs' && req.method() === 'GET' && url.searchParams.get('q') === GENERATED;
    });
    await bar.locator('button.apply-btn', { hasText: 'Apply as search' }).click();
    await searched;

    // Back in KQL mode, showing the applied query.
    await expect(page.locator('.ai-query-bar')).toHaveCount(0);
    await expect(page.locator('input[aria-label="Search logs"]')).toHaveValue(GENERATED);
  });
});
