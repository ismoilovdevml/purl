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

  /**
   * Locate a notification channel card by its heading. (Card forwards `class`
   * since #93, so `.notification-card` also matches now — see
   * card-class.spec.js — but the heading is what tells the channels apart.)
   */
  const notificationCard = (page, channel) =>
    page.locator('.card', {
      has: page.locator('.notification-header h4', { hasText: channel }),
    });

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

  /*
   * Retention is pinned by PURL_RETENTION_DAYS on the managed e2e stack
   * (web/e2e/stack/e2e.env), so the server OWNS `retention.days` and answers
   * 409 to any attempt to change it.
   *
   * The previous version of this test typed a new value and asserted the save
   * succeeded. Against this stack that can never pass — the response is
   * `409 {"error":"Cannot modify ENV-configured values: days"}` — so what it
   * really documented was a UI that offers an edit the server will always
   * reject. That is the bug, not the test, and this is the regression test for
   * it: every other ENV-pinned field in Settings (backup retention, the
   * Telegram chat id, the LDAP/SSO/AI/Redis fields) is rendered disabled and
   * badged, and this one must behave the same way.
   */
  test('the ENV-pinned retention period is disabled rather than offered and rejected', async ({
    page,
  }) => {
    // Precondition, asserted rather than assumed: if a target ever stops
    // pinning this key the test must say so loudly instead of quietly
    // testing nothing.
    const settings = await page.request.get('/api/settings');
    expect(settings.ok()).toBe(true);
    expect(
      (await settings.json()).retention?.days?.from_env,
      'this spec targets a stack that pins PURL_RETENTION_DAYS (see web/e2e/stack/e2e.env)'
    ).toBeTruthy();

    await openSettingsSection(page, 'Database');

    const input = page.locator('.retention-control input.input-field');
    await expect(input).toBeVisible();

    await expect(
      input,
      'a retention period owned by PURL_RETENTION_DAYS must not be editable — the server 409s the save'
    ).toBeDisabled();

    // Disabled without a reason is its own defect: the user has to be told why
    // the field is frozen, the same way every other ENV-pinned field explains
    // itself via <EnvBadge>.
    await expect(
      page.locator('.retention-control [data-env-locked="true"]'),
      'an ENV-pinned retention field must carry the ENV badge explaining why'
    ).toBeVisible();

    // The Apply button must not offer an action that cannot succeed.
    await expect(
      page.locator('.retention-control button.btn-success'),
      'Apply must be disabled when the value it would send is ENV-owned'
    ).toBeDisabled();
  });

  test('a notification channel config is persisted server-side', async ({ page }) => {
    await openSettingsSection(page, 'Notifications');

    const card = notificationCard(page, 'Webhook');
    await expect(card).toBeVisible();

    /*
     * The checkbox itself is styled away (`.toggle input { opacity:0; width:0;
     * height:0 }`), so it is never actionable and `.check()` times out. Drive
     * it the way a user does — by clicking the visible slider — and assert on
     * the input's state. `isChecked()` needs no visibility, so reading it is
     * still fine.
     */
    const enable = card.locator('.notification-toggle input[type="checkbox"]');
    if (!(await enable.isChecked())) {
      await card.locator('.notification-toggle .toggle-slider').click();
    }
    await expect(enable).toBeChecked();
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

    /*
     * Persistence is asserted against the SERVER, not by reading the input
     * back.
     *
     * GET /api/settings deliberately never echoes a configured webhook URL or
     * token — it reports `url_set: 1` and nothing else, so the secret does not
     * travel back to every dashboard that loads the page. The form is
     * therefore blank after a reload BY DESIGN, and the previous assertion
     * (`toHaveValue(value)`) was asserting a contract the product does not
     * have and never could satisfy.
     */
    const stored = await page.request.get('/api/settings');
    expect(stored.ok()).toBe(true);
    const webhook = (await stored.json()).notifications.webhook;
    expect(webhook.url_set, 'the saved webhook URL must be recorded server-side').toBe(1);
    expect(webhook.enabled, 'the channel must stay enabled across the save').toBeTruthy();

    // The reloaded UI must still show the channel as enabled and expanded,
    // even though the URL itself is intentionally not returned.
    await page.reload();
    await openSettingsSection(page, 'Notifications');
    const reloadedCard = notificationCard(page, 'Webhook');
    await expect(reloadedCard.locator('.notification-form')).toBeVisible();
    await expect(reloadedCard.locator('.notification-toggle input[type="checkbox"]')).toBeChecked();
  });
});
