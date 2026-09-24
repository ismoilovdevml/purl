import { test, expect } from '@playwright/test';
import { login, gotoTab, ingestLogs, logEntry, unique, waitForIngested } from './fixtures/purl.js';

/**
 * #112: the cluster picker used to append ` meta.cluster:x` to the query text,
 * so `level:ERROR OR level:WARN` with cluster a became
 * `level:ERROR OR level:WARN meta.cluster:a` = `level:ERROR OR (level:WARN AND
 * cluster:a)`: every ERROR from every cluster leaked in. The cluster now goes
 * as its own `cluster` param, which the server ANDs with the whole expression.
 *
 * Real backend, real rows. Only /api/clusters is mocked: it is cached server
 * side, and the listing is not what this spec is about.
 */
test('the cluster picker filters an OR query as a whole (#112)', async ({ page, request }) => {
  const marker = unique('clusteror');
  const clusterA = `${marker}-a`;
  const clusterB = `${marker}-b`;
  const row = (cluster, level) =>
    logEntry({ level, message: `${marker} ${cluster} ${level}`, meta: { cluster } });

  await ingestLogs(request, [
    row(clusterA, 'ERROR'),
    row(clusterA, 'WARN'),
    row(clusterA, 'INFO'),
    row(clusterB, 'ERROR'),
    row(clusterB, 'WARN'),
  ]);
  await waitForIngested(request, marker);

  await page.route(
    (url) => url.pathname === '/api/clusters',
    (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ clusters: [clusterA, clusterB] }) })
  );

  await login(page);
  await gotoTab(page, 'Logs');
  await page.locator('select[aria-label="Select cluster"]').selectOption(clusterA);

  const search = page.locator('input[aria-label="Search logs"]');
  await search.fill('level:ERROR OR level:WARN');
  const orSearch = page.waitForResponse((res) => {
    const url = new URL(res.url());
    // startsWith: the old frontend appended the cluster clause to `q`.
    return url.pathname === '/api/logs' && (url.searchParams.get('q') ?? '').startsWith('level:ERROR OR level:WARN');
  });
  await search.press('Enter');
  const response = await orSearch;
  const params = new URL(response.url()).searchParams;
  const body = await response.json();

  // Cluster a's ERROR and WARN are in the table...
  const table = page.locator('.log-table');
  await expect(table).toContainText(`${marker} ${clusterA} ERROR`, { timeout: 30_000 });
  await expect(table).toContainText(`${marker} ${clusterA} WARN`);

  // ...and nothing from outside cluster a: not cluster b's ERROR (the OR
  // branch the old query left unscoped), not any other ERROR on the stack.
  const clustersInResult = new Set(body.hits.map((h) => h.meta?.cluster ?? '(none)'));
  expect([...clustersInResult], 'every row must come from cluster a').toEqual([clusterA]);
  expect(body.hits.map((h) => h.level).sort()).toEqual(['ERROR', 'WARN']);
  expect(params.get('q'), 'the search text must be sent as typed').toBe('level:ERROR OR level:WARN');
  expect(params.get('cluster'), 'the cluster must be its own param').toBe(clusterA);

  await expect(table).not.toContainText(`${marker} ${clusterB}`);
  await expect(page.locator('.table-toolbar .toolbar-info')).toHaveText('2 logs');
});
