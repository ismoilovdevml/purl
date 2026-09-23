import { expect } from '@playwright/test';
import { stackEnv } from './env.js';

export { stackEnv };

/**
 * Shared helpers for the Purl e2e suite.
 *
 * Rule enforced here: helpers either succeed or throw. None of them return a
 * boolean the caller can shrug off. The suite this replaces was full of
 * `if (await x.isVisible()) { ...assert... }` blocks, which turn "the feature
 * disappeared" into a silent pass.
 */

/** Collision-proof name so a re-run never sees a leftover from the last one. */
export function unique(prefix) {
  return `${prefix}-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`;
}

/**
 * Log in and land on the dashboard.
 *
 * The managed stack runs with auth on, so the login page is rendered and the
 * admin user is bootstrapped from PURL_ADMIN_PASSWORD.
 */
export async function login(page) {
  if (!stackEnv.ADMIN_PASSWORD) {
    throw new Error(
      'No admin password available. Either run against the managed stack ' +
      '(web/e2e/stack/e2e.env) or export PURL_ADMIN_PASSWORD for your target.'
    );
  }

  await page.goto('/');

  const loginCard = page.locator('.login-card');
  const navTabs = page.locator('.nav-tabs');

  // Either the app wants credentials or a session cookie already got us in.
  await expect(loginCard.or(navTabs).first()).toBeVisible({ timeout: 30_000 });

  if (await loginCard.isVisible()) {
    await page.locator('input[autocomplete="username"]').fill(stackEnv.ADMIN_USERNAME);
    await page.locator('input[type="password"]').fill(stackEnv.ADMIN_PASSWORD);
    await page.locator('button:has-text("Sign In")').click();
  }

  await expect(navTabs).toBeVisible({ timeout: 30_000 });
  // The forced password-change screen also hides .login-card; make sure we are
  // actually in the app rather than parked on it.
  await expect(page.locator('.login-card')).toHaveCount(0);
}

/** Click a top-level nav tab and wait for the hash route to settle. */
export async function gotoTab(page, label) {
  const tab = page.locator(`.nav-tabs button:has-text("${label}")`);
  await expect(tab, `nav tab "${label}" must exist`).toBeVisible();
  await tab.click();
  await expect(tab).toHaveClass(/active/);
}

/**
 * Open a Settings section, failing loudly when it is locked.
 *
 * The old settings spec wrapped every click in `if (!isLocked)`, so an
 * unreachable section passed without asserting anything. Locked (admin-only
 * for a non-admin) here is a failure, not a skip.
 */
export async function openSettingsSection(page, label) {
  await gotoTab(page, 'Settings');
  await expect(page.locator('.settings-page')).toBeVisible();

  const item = page.locator('.settings-nav button', { hasText: label }).first();
  await expect(item, `settings section "${label}" must be present`).toBeVisible();
  await expect(
    item,
    `settings section "${label}" is role locked — the e2e stack must run as admin`
  ).not.toHaveClass(/locked/);

  await item.click();
  await expect(item).toHaveClass(/active/);
  return item;
}

/**
 * Expand one of the collapsible logs-sidebar panels (Alerts, Saved Searches).
 * Both render `expanded = false` initially, so the list is not merely hidden —
 * it is absent from the DOM until this runs.
 */
export async function expandSidebarPanel(page, rootSelector) {
  const panel = page.locator(rootSelector);
  await expect(panel).toBeVisible();
  if ((await panel.locator('.content').count()) === 0) {
    await panel.locator('.header').first().click();
  }
  await expect(panel.locator('.content')).toBeVisible();
  return panel;
}

/**
 * Ingest logs through the public API-key endpoint.
 *
 * Note the path: POST /api/logs. `tests/e2e/*.sh` posted to /api/v1/logs,
 * which has never existed — the 404 was swallowed by a `warn`, which is how
 * those scripts printed "All tests passed" without ingesting anything.
 */
export async function ingestLogs(request, entries) {
  if (!stackEnv.API_KEY) {
    throw new Error('No ingest API key available (PURL_API_KEYS).');
  }
  const res = await request.post('/api/logs', {
    headers: {
      'Content-Type': 'application/json',
      'X-API-Key': stackEnv.API_KEY,
    },
    data: entries,
  });
  expect(
    res.status(),
    `ingest failed: ${res.status()} ${await res.text().catch(() => '')}`
  ).toBe(200);
  return res;
}

/**
 * Headers for a session-authenticated mutation.
 *
 * `$protected` rejects a cookie-authenticated POST/PUT/DELETE that arrives
 * without a valid `X-CSRF-Token` (see csrf-mutation.spec.js). `page.request`
 * shares the browser's cookie jar, so pairing it with this header is the way a
 * spec drives an admin-only endpoint directly instead of clicking through the
 * UI.
 *
 * Note the role trap: `X-API-Key` auth is CSRF-exempt but sets NO session role,
 * and `require_role` defaults to 'viewer' — so an API-key request 403s on every
 * admin-gated route. Anything mutating must go through the session.
 */
export async function csrfHeaders(page) {
  const res = await page.request.get('/api/csrf-token');
  expect(res.ok(), `GET /api/csrf-token failed: ${res.status()}`).toBe(true);
  const { csrf_token: token } = await res.json();
  expect(token, 'server returned no csrf_token').toBeTruthy();
  return { 'X-CSRF-Token': token, 'Content-Type': 'application/json' };
}

/** Build a log entry pinned to "now" so it lands inside short time ranges. */
export function logEntry(overrides = {}) {
  return {
    timestamp: new Date().toISOString(),
    level: 'INFO',
    service: 'e2e',
    host: 'e2e-host',
    message: 'e2e log',
    ...overrides,
  };
}

/**
 * Poll the search API until an ingested marker is queryable.
 *
 * ClickHouse async_insert is configured with wait_for_async_insert=1 so this
 * is normally instant, but a bounded poll keeps the assertion about *search*
 * rather than about insert latency.
 */
export async function waitForIngested(request, marker, { range = '15m', timeout = 30_000 } = {}) {
  const deadline = Date.now() + timeout;
  let last = null;
  while (Date.now() < deadline) {
    const res = await request.get(`/api/logs?limit=50&range=${range}&q=${encodeURIComponent(marker)}`, {
      headers: { 'X-API-Key': stackEnv.API_KEY },
    });
    if (res.ok()) {
      last = await res.json();
      if ((last.total ?? 0) > 0) return last;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(
    `Ingested marker "${marker}" never became searchable within ${timeout}ms. Last response: ${JSON.stringify(last)}`
  );
}

/**
 * Fulfil a route with the REAL response, after `mutate` edits its JSON body.
 * Used to inject one contract field (from_env_keys, *_set flags) without
 * discarding everything else the server answered.
 */
export async function patchJson(route, mutate) {
  const response = await route.fetch();
  const body = await response.json();
  mutate(body);
  await route.fulfill({ response, json: body });
}
