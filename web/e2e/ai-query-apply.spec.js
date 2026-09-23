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
// #98: the server may also return the search-bar form of the question.
const SEARCH_QUERY = 'level:ERROR AND service:api';

/**
 * Two response shapes from POST /api/ai/query:
 *   - without `query` (older servers, or no search-bar equivalent): the SQL is
 *     applied, as before #98
 *   - with `query` (#98): it wins over the SQL — it is already valid search-bar
 *     syntax — and the time picker is left alone (it never carries a range)
 */
const CASES = [
  { name: 'without query: the generated SQL', response: {}, applied: GENERATED },
  { name: 'with query: the search-bar query, not the SQL (#98)', response: { query: SEARCH_QUERY }, applied: SEARCH_QUERY },
];

test.describe('Ask AI apply (#96, #98)', () => {
  let aiQueryBodies;
  let aiResponse;
  let logRequests;

  test.beforeEach(async ({ page }) => {
    aiQueryBodies = [];
    aiResponse = {};
    logRequests = [];

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
            question: aiQueryBodies.at(-1).question,
            sql: GENERATED,
            provider: 'openai',
            results: [{ level: 'ERROR', message: 'boom' }],
            total: 1,
            ...aiResponse,
          },
        });
      }
    );
    await page.route(
      (url) => url.pathname === '/api/logs',
      (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        logRequests.push(new URL(route.request().url()));
        return route.fulfill({ json: { hits: [], total: 0 } });
      }
    );

    await login(page);
    await gotoTab(page, 'Logs');
  });

  for (const { name, response, applied } of CASES) {
    test(`Apply as search runs ${name}`, async ({ page }) => {
      aiResponse = response;
      await expect.poll(() => logRequests.length).toBeGreaterThan(0);
      const rangeBefore = logRequests.at(-1).searchParams.get('range');

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
        return url.pathname === '/api/logs' && req.method() === 'GET' && url.searchParams.get('q') === applied;
      });
      await bar.locator('button.apply-btn', { hasText: 'Apply as search' }).click();
      const request = new URL((await searched).url());

      // The time range the page was already using is untouched.
      expect(request.searchParams.get('range')).toBe(rangeBefore);

      // Back in KQL mode, showing the applied query.
      await expect(page.locator('.ai-query-bar')).toHaveCount(0);
      await expect(page.locator('input[aria-label="Search logs"]')).toHaveValue(applied);
    });
  }
});
