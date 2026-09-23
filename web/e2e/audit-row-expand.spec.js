import { test, expect } from '@playwright/test';
import { login, openSettingsSection } from './fixtures/purl.js';

/**
 * Audit Logs: a row with details expands and collapses.
 *
 * Regression for the runes migration of AuditSettings: `expandedRows` is a Set
 * in $state, and $state does not track Set mutations — toggling a row by
 * mutating the Set in place left the details hidden. The fix replaces the Set
 * on every toggle.
 *
 * /api/audit is mocked so the rows (and which ones carry details) are known.
 * total_count is large to pin the "Showing a–b of N" format: full numbers
 * with separators (formatNumber), not compact counts.
 */
const NOW = new Date().toISOString();

const EVENTS = [
  {
    id: 'audit-1', timestamp: NOW, actor: 'admin', action: 'user.create',
    resource_type: 'user', resource_id: 'alice', status: 'success',
    ip_address: '10.0.0.1', details: 'created user alice with role viewer',
  },
  {
    id: 'audit-2', timestamp: NOW, actor: 'admin', action: 'settings.update',
    resource_type: 'settings', resource_id: 'retention', status: 'success',
    ip_address: '10.0.0.1', details: 'retention_days 30 -> 14',
  },
  {
    id: 'audit-3', timestamp: NOW, actor: 'bob', action: 'login.failed',
    resource_type: '', resource_id: '', status: 'failure',
    ip_address: '10.0.0.2', details: '',
  },
];

test.describe('Audit log row details', () => {
  test.beforeEach(async ({ page }) => {
    await page.route(
      (url) => url.pathname === '/api/audit',
      (route) => route.fulfill({ json: { logs: EVENTS, total_count: 1234 } })
    );
    await page.route(
      (url) => url.pathname === '/api/audit/stats',
      (route) => route.fulfill({ json: { stats: [] } })
    );
    await login(page);
    await openSettingsSection(page, 'Audit Logs');
  });

  const section = (page) =>
    page.locator('.settings-section', { has: page.locator('h3', { hasText: 'Audit Logs' }) });

  test('clicking a row toggles its details, independently of other rows', async ({ page }) => {
    const rows = section(page).locator('.log-row');
    const details = section(page).locator('.log-details');
    await expect(rows).toHaveCount(EVENTS.length);
    await expect(details).toHaveCount(0);

    await rows.nth(0).click();
    await expect(details).toHaveCount(1);
    await expect(details.first()).toHaveText(EVENTS[0].details);

    await rows.nth(1).click();
    await expect(details).toHaveCount(2);

    // Collapse the first one; the second stays open.
    await rows.nth(0).click();
    await expect(details).toHaveCount(1);
    await expect(details.first()).toHaveText(EVENTS[1].details);
  });

  test('Enter toggles an expandable row; a row without details is not expandable', async ({ page }) => {
    const rows = section(page).locator('.log-row');
    const details = section(page).locator('.log-details');

    await rows.nth(0).focus();
    await page.keyboard.press('Enter');
    await expect(details).toHaveCount(1);
    await page.keyboard.press('Enter');
    await expect(details).toHaveCount(0);

    const plain = rows.nth(2);
    await expect(plain).not.toHaveAttribute('role', 'button');
    await plain.click();
    await expect(details).toHaveCount(0);
  });

  test('the range line uses full numbers with separators', async ({ page }) => {
    await expect(section(page).locator('.event-count')).toHaveText('Showing 1–3 of 1,234');
  });
});
