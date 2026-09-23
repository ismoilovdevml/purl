import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * Analytics: the health badge follows the metrics poll.
 *
 * Before the runes migration HealthBadge computed its score in statements
 * that referenced no reactive value, so they ran once at mount and the badge
 * kept its first (empty-metrics) score forever. It now derives from its props.
 *
 * /api/metrics/json is mocked and its answer changed between two polls of
 * AnalyticsPage's 10 s interval — no click, no reload — and the score must
 * move. The expected numbers follow HealthBadge's weights:
 *   healthy:  every factor 100                                  -> 100
 *   degraded: errors 20% (0x30) p95 1500ms (20x25) p99 3000ms (20x15)
 *             cache 5% (30x15) uptime 2h (100x10) 150 rps (100x5) -> 27.5 -> 28
 */
function metricsBody({ errors, p95, p99, hitRate }) {
  return {
    requests: {
      total: 1000,
      errors,
      per_second: '150',
      p50_latency: '10ms',
      p95_latency: p95,
      p99_latency: p99,
      max_latency: p99,
      bytes_in: 1024,
      bytes_out: 2048,
    },
    cache: { hit_rate: hitRate },
    clickhouse: { avg_query_time: '5ms', queries_total: 10, queries_cached: 5, inserts_total: 3, bytes_inserted: 4096 },
    server: { uptime_secs: 7200, uptime_human: '2h 0m' },
  };
}

const HEALTHY = metricsBody({ errors: 0, p95: '50ms', p99: '80ms', hitRate: '80%' });
const DEGRADED = metricsBody({ errors: 200, p95: '1500ms', p99: '3000ms', hitRate: '5%' });

test.describe('Analytics health score', () => {
  test('the score changes when the polled metrics change', async ({ page }) => {
    let current = HEALTHY;
    let metricsCalls = 0;
    await page.route(
      (url) => url.pathname === '/api/metrics/json',
      (route) => {
        metricsCalls += 1;
        return route.fulfill({ json: current });
      }
    );

    await login(page);
    await gotoTab(page, 'Analytics');

    const score = page.locator('.health-badge .health-score');
    await expect(score).toHaveText('100');
    const callsBeforeSwitch = metricsCalls;

    current = DEGRADED;
    // Next interval tick (10 s) — generous timeout, no user action.
    await expect(score).toHaveText('28', { timeout: 25_000 });
    expect(metricsCalls, 'the change must come from the poll').toBeGreaterThan(callsBeforeSwitch);

    // The breakdown follows too.
    const errorRow = page.locator('.health-tooltip .tooltip-row', { hasText: 'Error Rate' });
    await expect(errorRow.locator('.factor-value')).toHaveText('20.00%');
    await expect(errorRow.locator('.factor-score')).toHaveText('0');
    await expect(page.locator('.health-tooltip .total-score')).toHaveText('28');
  });
});
