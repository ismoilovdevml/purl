import { test, expect } from '@playwright/test';
import { login, gotoTab, unique, ingestLogs, logEntry, waitForIngested } from './fixtures/purl.js';

/**
 * #104: Kubernetes logs carry namespace/pod/container, but the fields sidebar
 * only offered level, service and host, so there was no way to pick a
 * namespace or pod. The sidebar now asks `/api/stats/fields/{namespace,pod,
 * container}` and a click puts `namespace:<v>` (etc.) into the query. Facets
 * are asked with the current search as `q`, so their counts narrow with it,
 * and a value the KQL tokenizer would split (spaces, `*`, quotes) is quoted.
 *
 * The first two tests are route-mocked: they pin the frontend half of the
 * contract (field names requested, `q`, quoting, hiding empty facets). The
 * last one runs the whole path against the real backend: k8s-shaped logs
 * (namespace/pod/container in `meta`, as the chart's Vector DaemonSet sends
 * them) are ingested, faceted and filtered.
 */

const FIELD_VALUES = {
  level: [{ value: 'ERROR', count: 4 }],
  service: [{ value: 'api', count: 9 }],
  namespace: [{ value: 'trk', count: 12 }, { value: 'kube-system', count: 3 }, { value: 'team "a" ns', count: 1 }],
  pod: [{ value: 'trk-api-7d9f8c-x2x9q', count: 10 }],
  container: [{ value: 'api', count: 10 }],
};

async function mockFieldStats(page, values) {
  /** field -> the `q` of its latest request ('' when none was sent) */
  const requested = new Map();
  await page.route(
    (url) => url.pathname.startsWith('/api/stats/fields/'),
    (route) => {
      const url = new URL(route.request().url());
      const field = decodeURIComponent(url.pathname.split('/').pop());
      requested.set(field, url.searchParams.get('q') ?? '');
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ field, values: values[field] ?? [] }),
      });
    }
  );
  return requested;
}

/** Record the `q` of every search the page issues. */
async function trackSearches(page) {
  const queries = [];
  await page.route(
    (url) => url.pathname === '/api/logs',
    (route) => {
      if (route.request().method() !== 'GET') return route.fallback();
      queries.push(new URL(route.request().url()).searchParams.get('q') ?? '');
      return route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ hits: [], total: 0 }),
      });
    }
  );
  return queries;
}

const section = (page, name) =>
  page.locator('.fields-sidebar .field-section', {
    has: page.locator('.section-name', { hasText: new RegExp(`^${name}$`) }),
  });

test.describe('Kubernetes facets in the fields sidebar (#104)', () => {
  test('namespace, pod and container facets filter the search', async ({ page }) => {
    const requested = await mockFieldStats(page, FIELD_VALUES);
    const queries = await trackSearches(page);
    await login(page);
    await gotoTab(page, 'Logs');

    await expect(section(page, 'namespace')).toBeVisible();
    await expect(section(page, 'pod')).toBeVisible();
    await expect(section(page, 'container')).toBeVisible();
    await expect(page.locator('.fields-sidebar .section-divider', { hasText: 'Kubernetes' })).toBeVisible();
    for (const field of ['namespace', 'pod', 'container']) {
      expect(requested.has(field), `/api/stats/fields/${field} must be requested`).toBe(true);
    }

    const search = page.locator('input[aria-label="Search logs"]');

    await page.getByRole('button', { name: 'Filter by namespace:trk' }).click();
    await expect(search).toHaveValue('namespace:trk');
    await expect.poll(() => queries.at(-1)).toBe('namespace:trk');
    // Every facet is re-counted within the new search, level/service included.
    for (const field of ['level', 'service', 'namespace', 'pod', 'container']) {
      await expect.poll(() => requested.get(field), `${field} facet q`).toBe('namespace:trk');
    }

    await page.getByRole('button', { name: 'Filter by pod:trk-api-7d9f8c-x2x9q' }).click();
    await expect(search).toHaveValue('pod:trk-api-7d9f8c-x2x9q');
    await expect.poll(() => queries.at(-1)).toBe('pod:trk-api-7d9f8c-x2x9q');

    // A value the tokenizer would split is sent quoted, with `"` escaped.
    await page.getByRole('button', { name: 'Filter by namespace:team "a" ns' }).click();
    await expect(search).toHaveValue('namespace:"team \\"a\\" ns"');
    await expect.poll(() => queries.at(-1)).toBe('namespace:"team \\"a\\" ns"');

    // Container starts collapsed; opening it offers the same filter.
    await section(page, 'container').locator('.section-header').click();
    await page.getByRole('button', { name: 'Filter by container:api' }).click();
    await expect(search).toHaveValue('container:api');
    await expect.poll(() => queries.at(-1)).toBe('container:api');
  });

  test('a non-Kubernetes install shows no empty Kubernetes facets', async ({ page }) => {
    await mockFieldStats(page, { level: FIELD_VALUES.level, service: FIELD_VALUES.service });
    await trackSearches(page);
    await login(page);
    await gotoTab(page, 'Logs');

    await expect(section(page, 'level')).toBeVisible();
    await expect(section(page, 'service')).toBeVisible();
    for (const name of ['namespace', 'pod', 'container']) {
      await expect(section(page, name)).toHaveCount(0);
    }
    await expect(page.locator('.fields-sidebar .section-divider')).toHaveCount(0);
  });

  test('real k8s-shaped logs: pick a namespace, then a pod', async ({ page, request }) => {
    const service = unique('e2e-k8s');
    const nsA = unique('ns-a');
    const nsB = unique('ns-b');
    const podA1 = `${nsA}-api-1`;
    const podA2 = `${nsA}-worker-1`;
    const k8s = (namespace, pod, container) => ({ meta: { namespace, pod, container } });
    await ingestLogs(request, [
      logEntry({ service, message: `${service} a1 first`, ...k8s(nsA, podA1, 'api') }),
      logEntry({ service, message: `${service} a1 second`, ...k8s(nsA, podA1, 'api') }),
      logEntry({ service, message: `${service} a2`, ...k8s(nsA, podA2, 'worker') }),
      logEntry({ service, message: `${service} b1`, ...k8s(nsB, `${nsB}-api-1`, 'api') }),
    ]);
    await waitForIngested(request, `service:${service}`);

    await login(page);
    await gotoTab(page, 'Logs');
    const search = page.locator('input[aria-label="Search logs"]');
    const rows = page.locator('table.log-table tbody tr.log-row');

    // Scope to this test's rows; the facets narrow with the search.
    await search.fill(`service:${service}`);
    await search.press('Enter');
    await expect(rows).toHaveCount(4);
    await expect(section(page, 'namespace').locator('.field-value')).toHaveCount(2);

    await page.getByRole('button', { name: `Filter by namespace:${nsA}` }).click();
    await expect(search).toHaveValue(`namespace:${nsA}`);
    await expect(rows).toHaveCount(3);
    await expect(page.locator('table.log-table')).not.toContainText(`${service} b1`);

    // Within namespace A, the pod facet lists only A's pods.
    await expect(section(page, 'pod').locator('.field-value')).toHaveCount(2);
    await page.getByRole('button', { name: `Filter by pod:${podA1}` }).click();
    await expect(search).toHaveValue(`pod:${podA1}`);
    await expect(rows).toHaveCount(2);
    await expect(page.locator('table.log-table')).not.toContainText(`${service} a2`);
  });
});
