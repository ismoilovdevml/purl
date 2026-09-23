import { test, expect } from '@playwright/test';
import { login, openSettingsSection, unique, stackEnv } from './fixtures/purl.js';

/**
 * #101 — the audit log actually records events.
 *
 * The audit helper used to call a storage helper that was never registered,
 * so Settings > Audit Logs was always empty and every spec that looked at it
 * had to mock /api/audit. This one runs against the real stack: it performs
 * an audited action and then finds the event through the UI.
 *
 * The user is created and deleted through the page's own session (same cookie
 * jar, CSRF header attached), so the recorded actor is the signed-in admin.
 * Audit inserts are asynchronous, so the table is re-queried until the event
 * shows up.
 */
test.describe('Audit log records events (#101)', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  const section = (page) =>
    page.locator('.settings-section', { has: page.locator('h3', { hasText: 'Audit Logs' }) });

  async function csrfHeaders(page) {
    const res = await page.request.get('/api/csrf-token');
    expect(res.ok(), 'GET /api/csrf-token must succeed for a signed-in session').toBeTruthy();
    return { 'X-CSRF-Token': (await res.json()).csrf_token };
  }

  /** Filter the audit table by action and wait for the row about `resourceId`. */
  async function expectEvent(page, action, resourceId) {
    const audit = section(page);
    await audit.locator('#audit-action').selectOption(action);

    const row = audit.locator('.log-row', {
      has: page.locator('.resource-id', { hasText: new RegExp(`^${resourceId}$`) }),
    });

    await expect
      .poll(
        async () => {
          await audit.getByRole('button', { name: 'Search' }).click();
          await expect(audit.getByRole('button', { name: 'Search' })).toBeEnabled();
          return row.count();
        },
        { message: `audit event ${action} for ${resourceId} must be recorded`, timeout: 10_000 }
      )
      .toBe(1);

    await expect(row.locator('.action-badge')).toHaveText(action);
    await expect(row.locator('.resource-type')).toHaveText('user');
    await expect(row.locator('.actor-name')).toHaveText(stackEnv.ADMIN_USERNAME);
  }

  test('creating and deleting a user shows up in Audit Logs', async ({ page }) => {
    const username = unique('audituser').replace(/-/g, '');
    const headers = await csrfHeaders(page);

    const created = await page.request.post('/api/settings/users', {
      headers,
      data: { username, password: 'e2e-Audit-Pass-1234', role: 'viewer' },
    });
    expect(created.status(), `create user failed: ${await created.text()}`).toBeLessThan(300);

    const deleted = await page.request.delete(`/api/settings/users/${username}`, { headers });
    expect(deleted.status(), `delete user failed: ${await deleted.text()}`).toBeLessThan(300);

    await openSettingsSection(page, 'Audit Logs');
    await expectEvent(page, 'create_user', username);
    await expectEvent(page, 'delete_user', username);
  });
});
