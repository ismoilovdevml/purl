import { test, expect } from '@playwright/test';
import { login, openSettingsSection } from './fixtures/purl.js';

/**
 * Settings that are actually saved.
 *
 * "The section opens" was the entire previous coverage. These tests change a
 * value, prove the write happened, reload the page, and prove the new value
 * came back — which is the only definition of "saved" a user cares about.
 *
 * Two different persistence mechanisms are covered on purpose:
 *   - Display   -> localStorage, no API call at all
 *   - Retention -> PUT /api/settings/retention, server-side
 * They fail in completely different ways, so one test cannot stand in for the
 * other.
 */
test.describe('Settings persistence', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  const settingItem = (page, label) =>
    page.locator('.setting-item', { has: page.locator('.setting-label', { hasText: label }) });

  test('a Display setting survives a reload (client-side persistence)', async ({ page }) => {
    await openSettingsSection(page, 'Display');

    const maxResults = settingItem(page, 'Max Results').locator('input.input-field');
    await expect(maxResults).toBeVisible();

    const original = await maxResults.inputValue();
    const changed = original === '750' ? '850' : '750';

    // updateSetting is wired to `on:change`, so the value only commits on blur.
    await maxResults.fill(changed);
    await maxResults.blur();

    // It must reach the store's backing storage, not just the input element.
    await expect
      .poll(async () =>
        page.evaluate(() => JSON.parse(localStorage.getItem('purl_settings') || '{}').maxResults)
      )
      .toBe(Number(changed));

    await page.reload();
    await openSettingsSection(page, 'Display');
    await expect(settingItem(page, 'Max Results').locator('input.input-field')).toHaveValue(changed);

    // Restore so the rest of the suite sees the default page size.
    const restored = settingItem(page, 'Max Results').locator('input.input-field');
    await restored.fill(original);
    await restored.blur();
  });

  test('a Display toggle survives a reload', async ({ page }) => {
    await openSettingsSection(page, 'Display');

    const compact = page.getByRole('switch', { name: 'Compact Mode' });
    await expect(compact).toBeVisible();
    const before = await compact.getAttribute('aria-checked');

    await compact.click();
    await expect(compact).toHaveAttribute('aria-checked', before === 'true' ? 'false' : 'true');

    await page.reload();
    await openSettingsSection(page, 'Display');
    await expect(page.getByRole('switch', { name: 'Compact Mode' })).toHaveAttribute(
      'aria-checked',
      before === 'true' ? 'false' : 'true'
    );

    await page.getByRole('switch', { name: 'Compact Mode' }).click();
  });

  test('the retention period is persisted server-side', async ({ page }) => {
    await openSettingsSection(page, 'Database');

    const input = page.locator('.retention-control input.input-field');
    await expect(input).toBeVisible();

    const original = await input.inputValue();
    const changed = original === '45' ? '60' : '45';

    await input.fill(changed);

    const savePromise = page.waitForResponse(
      (res) =>
        new URL(res.url()).pathname === '/api/settings/retention' && res.request().method() === 'PUT'
    );
    await page.locator('.retention-control button.btn-success').click();

    const saved = await savePromise;
    expect(saved.status(), `PUT /api/settings/retention failed: ${await saved.text()}`).toBeLessThan(300);

    // The server is the source of truth here, so ask it directly as well as
    // re-rendering the page.
    const fromApi = await page.request.get('/api/config/retention');
    expect(fromApi.ok()).toBe(true);
    expect(String((await fromApi.json()).days)).toBe(changed);

    await page.reload();
    await openSettingsSection(page, 'Database');
    await expect(page.locator('.retention-control input.input-field')).toHaveValue(changed);

    // Restore the original retention so a later run starts from a known state.
    const restore = page.locator('.retention-control input.input-field');
    await restore.fill(original);
    await page.locator('.retention-control button.btn-success').click();
    await expect(page.locator('.retention-control input.input-field')).toHaveValue(original);
  });

  test('a notification channel config is persisted server-side', async ({ page }) => {
    await openSettingsSection(page, 'Notifications');

    const card = page.locator('.notification-card', { has: page.locator('h4', { hasText: 'Webhook' }) });
    await expect(card).toBeVisible();

    const enable = card.locator('.notification-toggle input[type="checkbox"]');
    if (!(await enable.isChecked())) {
      await enable.check();
    }
    await expect(card.locator('.notification-form')).toBeVisible();

    // Scope to .notification-form so the enable checkbox (which lives in
    // .notification-toggle) cannot be picked up as "the first input".
    const url = card.locator('.notification-form input').first();
    const value = `https://e2e.invalid/hook/${Date.now()}`;
    await url.fill(value);

    const savePromise = page.waitForResponse(
      (res) =>
        new URL(res.url()).pathname === '/api/settings/notifications/webhook' &&
        res.request().method() === 'PUT'
    );
    await card.locator('.form-actions button.btn-success').click();

    const saved = await savePromise;
    expect(
      saved.status(),
      `PUT /api/settings/notifications/webhook failed: ${await saved.text()}`
    ).toBeLessThan(300);

    await page.reload();
    await openSettingsSection(page, 'Notifications');
    const reloadedCard = page.locator('.notification-card', {
      has: page.locator('h4', { hasText: 'Webhook' }),
    });
    await expect(reloadedCard.locator('.notification-form')).toBeVisible();
    await expect(reloadedCard.locator('.notification-form input').first()).toHaveValue(value);
  });
});
