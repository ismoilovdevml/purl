import { test, expect } from '@playwright/test';
import { login, openSettingsSection, patchJson } from './fixtures/purl.js';

/**
 * "Remove stored value" — <ClearSecretToggle bind:armed> in the panels that
 * own write-only secrets.
 *
 * Regression for #85: NotificationSettings bound the toggle to `clearing[key]`
 * on an empty object, so every bound value started `undefined`. The toggle's
 * prop is `$bindable(false)`, and Svelte 5 throws props_invalid_value when a
 * bound prop with a fallback receives `undefined` — the panel crashed as soon
 * as a channel with a stored secret rendered its toggles.
 *
 * Each test drives the full path: the toggle arms, the field locks, Save asks
 * for confirmation, and the PUT carries exactly the one clear_* flag armed.
 *
 * The "a secret is stored" flags are injected into the real GET responses and
 * the PUT is captured rather than performed: the suite shares one server, and
 * the point under test is the UI's side of the clear_* contract.
 */
test.describe('Clearing a stored secret', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('a notification secret can be armed for removal and is cleared on confirmed save', async ({ page }) => {
    const pageErrors = [];
    page.on('pageerror', (err) => pageErrors.push(err.message));

    await page.route(
      (url) => url.pathname === '/api/settings',
      (route) =>
        route.request().method() === 'GET'
          ? patchJson(route, (body) => {
              body.notifications = body.notifications || {};
              body.notifications.telegram = {
                ...(body.notifications.telegram || {}),
                enabled: 1,
                from_env: 0,
                bot_token: 1,
                chat_id: 1,
              };
              body.notifications.from_env_keys = {
                ...(body.notifications.from_env_keys || {}),
                'telegram.bot_token': 0,
                'telegram.chat_id': 0,
              };
            })
          : route.continue()
    );

    let savedPayload = null;
    await page.route(
      (url) => url.pathname === '/api/settings/notifications/telegram',
      (route) => {
        if (route.request().method() !== 'PUT') return route.continue();
        savedPayload = route.request().postDataJSON();
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            status: 'ok',
            message: 'Telegram notification settings updated.',
            cleared: ['telegram.bot_token'],
          }),
        });
      }
    );

    await openSettingsSection(page, 'Notifications');

    const card = page.locator('.card', {
      has: page.locator('.notification-header h4', { hasText: 'Telegram' }),
    });
    await expect(card.locator('.notification-form')).toBeVisible();

    const removeToken = card.locator('input[aria-label="Remove stored Bot token"]');
    const removeChatId = card.locator('input[aria-label="Remove stored Chat ID"]');
    await expect(removeToken).not.toBeChecked();
    await expect(removeChatId).not.toBeChecked();

    await removeToken.check();
    await expect(card.locator('[data-clear-secret="telegram.bot_token"] [role="status"]'))
      .toContainText('will be deleted when you save');
    await expect(
      card.locator('.form-row', { hasText: 'Bot Token' }).locator('input.input-field'),
      'an input whose value is armed for removal must be locked'
    ).toBeDisabled();

    await card.locator('button', { hasText: 'Save' }).click();

    const dialog = page.locator('[role="alertdialog"], [role="dialog"]', { hasText: 'Remove saved secret?' });
    await expect(dialog).toBeVisible();
    await dialog.locator('button', { hasText: 'Remove and save' }).click();

    await expect.poll(() => savedPayload, 'confirming must PUT the channel').not.toBeNull();
    expect(savedPayload.clear_bot_token).toBe(true);
    expect(savedPayload.bot_token).toBe('');
    expect(savedPayload, 'a disarmed removal must not be sent at all').not.toHaveProperty('clear_chat_id');

    // Disarmed after the save, not carried into the next one.
    await expect(removeToken).not.toBeChecked();
    expect(pageErrors, 'the panel must not throw').toEqual([]);
  });

  test('a Backup S3 credential can be armed for removal and is cleared on confirmed save', async ({ page }) => {
    const pageErrors = [];
    page.on('pageerror', (err) => pageErrors.push(err.message));

    await page.route(
      (url) => url.pathname === '/api/backup/s3',
      (route) => {
        const method = route.request().method();
        if (method === 'GET') {
          return patchJson(route, (body) => {
            body.s3 = {
              ...(body.s3 || {}),
              enabled: true,
              bucket: 'e2e-bucket',
              region: 'us-east-1',
              has_credentials: true,
              from_env: false,
              from_env_keys: {},
            };
          });
        }
        return route.fallback();
      }
    );

    let savedPayload = null;
    await page.route(
      (url) => url.pathname === '/api/backup/s3',
      (route) => {
        if (route.request().method() !== 'PUT') return route.fallback();
        savedPayload = route.request().postDataJSON();
        return route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ status: 'ok', cleared: ['s3_secret_key'] }),
        });
      }
    );

    await openSettingsSection(page, 'Backups');

    const removeAccess = page.locator('input[aria-label="Remove stored Access key ID"]');
    const removeSecret = page.locator('input[aria-label="Remove stored Secret access key"]');
    await expect(removeAccess).toBeVisible();
    await expect(removeAccess).not.toBeChecked();
    await expect(removeSecret).not.toBeChecked();

    await removeSecret.check();
    await expect(page.locator('#s3-secret-key'), 'an armed credential must be locked').toBeDisabled();
    await expect(page.locator('#s3-access-key'), 'the other credential stays editable').toBeEnabled();
    await expect(page.locator('[data-clear-secret="s3_secret_key"] [role="status"]'))
      .toContainText('will be deleted when you save');

    await page.locator('button', { hasText: 'Save S3 Settings' }).click();

    const dialog = page.locator('[role="alertdialog"], [role="dialog"]', { hasText: 'Remove saved secret?' });
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText('Secret access key');
    await dialog.locator('button', { hasText: 'Remove and save' }).click();

    await expect.poll(() => savedPayload, 'confirming must PUT the S3 config').not.toBeNull();
    expect(savedPayload.clear_s3_secret_key).toBe(true);
    expect(savedPayload, 'a cleared credential must not also be set').not.toHaveProperty('s3_secret_key');
    expect(savedPayload, 'a disarmed removal must not be sent at all').not.toHaveProperty('clear_s3_access_key');

    await expect(removeSecret).not.toBeChecked();
    expect(pageErrors, 'the panel must not throw').toEqual([]);
  });
});
