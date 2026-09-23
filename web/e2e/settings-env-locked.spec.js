import { test, expect } from '@playwright/test';
import { login, openSettingsSection, patchJson } from './fixtures/purl.js';

/**
 * Fields the environment owns must render disabled — and say why.
 *
 * The server publishes a per-key map (`from_env_keys`, or `from_env` on the
 * LDAP/SAML/AI/Redis endpoints) saying exactly which keys it will refuse to
 * change. It answers 409 for any attempt. Before this was wired up, the UI only
 * knew about ONE coarse flag per panel, so a field pinned by a different
 * variable — PURL_BACKUP_RETENTION_DAYS, PURL_TELEGRAM_CHAT_ID — rendered fully
 * editable and failed the save.
 *
 * The map is injected into the real responses rather than driven by the stack's
 * environment: the suite must not require restarting the container with extra
 * variables, and the point under test is the UI's reaction to the contract.
 */

test.describe('ENV-pinned settings fields', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('a backup field pinned by ENV is disabled, explained, and does not freeze its neighbours', async ({ page }) => {
    await page.route(
      (url) => url.pathname === '/api/backup/schedule',
      (route) =>
        route.request().method() === 'GET'
          ? patchJson(route, (body) => {
              body.schedule = body.schedule || {};
              body.schedule.enabled = true;
              // Coarse flag OFF on purpose: only the per-key map may explain
              // what follows, so this cannot pass on the old behaviour.
              body.schedule.from_env = 0;
              body.schedule.from_env_keys = {
                ...(body.schedule.from_env_keys || {}),
                retention_days: 1,
                schedule_interval_hours: 0,
              };
            })
          : route.continue()
    );

    await openSettingsSection(page, 'Backups');

    const retention = page.locator('#backup-retention');
    await expect(retention).toBeVisible();
    await expect(retention, 'a field pinned by PURL_BACKUP_RETENTION_DAYS must not be editable').toBeDisabled();

    // Disabled is not enough — the user has to be told why.
    const badge = page.locator('label[for="backup-retention"] [data-env-locked="true"]');
    await expect(badge).toBeVisible();
    await expect(badge).toHaveAttribute('title', /environment variable/i);

    // Per-key, not per-panel: the unpinned sibling stays editable.
    await expect(page.locator('#backup-interval')).toBeEnabled();
    await expect(page.locator('label[for="backup-interval"] [data-env-locked="true"]')).toHaveCount(0);
  });

  test('an ENV-pinned notification field is disabled and is left out of the save payload', async ({ page }) => {
    await page.route(
      (url) => url.pathname === '/api/settings',
      (route) =>
        route.request().method() === 'GET'
          ? patchJson(route, (body) => {
              body.notifications = body.notifications || {};
              body.notifications.telegram = { ...(body.notifications.telegram || {}), enabled: 1, from_env: 0 };
              body.notifications.from_env_keys = {
                ...(body.notifications.from_env_keys || {}),
                'telegram.chat_id': 1,
                'telegram.bot_token': 0,
              };
            })
          : route.continue()
    );

    // Capture the save instead of performing it: this spec is about the
    // payload, and the rest of the suite shares this server's settings.
    let savedPayload = null;
    await page.route(
      (url) => url.pathname === '/api/settings/notifications/telegram',
      (route) => {
        if (route.request().method() !== 'PUT') return route.continue();
        savedPayload = route.request().postDataJSON();
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ status: 'ok', message: 'Telegram notification settings updated.' }),
        });
      }
    );

    await openSettingsSection(page, 'Notifications');

    // NOT `.notification-card`: that class is passed to <Card>, which declares
    // no `class` prop, so Svelte drops it and the element never carries it.
    // The card is found through markup it actually renders.
    const card = page.locator('.card', {
      has: page.locator('.notification-header h4', { hasText: 'Telegram' }),
    });
    await expect(card).toBeVisible();

    const chatIdRow = card.locator('.form-row', { hasText: 'Chat ID' });
    await expect(
      chatIdRow.locator('input.input-field'),
      'a field pinned by PURL_TELEGRAM_CHAT_ID must not be editable'
    ).toBeDisabled();
    await expect(chatIdRow.locator('[data-env-locked="true"]')).toBeVisible();

    // The unpinned token field in the same channel is still editable.
    const tokenRow = card.locator('.form-row', { hasText: 'Bot Token' });
    await expect(tokenRow.locator('input.input-field')).toBeEnabled();
    await tokenRow.locator('input.input-field').fill('123456:test-token');

    await card.locator('button', { hasText: 'Save' }).click();
    await expect.poll(() => savedPayload, 'the Save button must PUT the channel').not.toBeNull();

    // Sending the disabled (blank) field would be a *change* to an ENV-owned
    // key: the server 409s the whole request and nothing gets saved.
    expect(savedPayload).not.toHaveProperty('chat_id');
    expect(savedPayload.bot_token).toBe('123456:test-token');
  });
});
