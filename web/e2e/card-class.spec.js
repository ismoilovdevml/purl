import { test, expect } from '@playwright/test';
import { login, openSettingsSection } from './fixtures/purl.js';

/**
 * #93 — ui/Card forwards a `class` prop, merged with its own.
 *
 * Card declared no `class` prop, so `<Card class="notification-card">` dropped
 * the class and the caller's :global(.notification-card) / .auth-info-card /
 * .main-card rules never applied. Assert both the class and a rule it brings.
 */
test.describe('Card class forwarding (#93)', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('notification cards carry their class and its spacing', async ({ page }) => {
    await openSettingsSection(page, 'Notifications');

    const channelCards = page.locator('.card.notification-card');
    await expect(channelCards.first()).toBeVisible();
    // Card keeps its own classes next to the forwarded one.
    await expect(channelCards.first()).toHaveClass(/\bbordered\b/);
    await expect(channelCards.first()).toHaveCSS('margin-bottom', '16px');

    const storageInfo = page.locator('.card.auth-info-card');
    await expect(storageInfo).toBeVisible();
    await expect(storageInfo).toHaveCSS('margin-top', '24px');
  });

  test('the About card is centred by its forwarded class', async ({ page }) => {
    await openSettingsSection(page, 'About');
    const main = page.locator('.card.main-card');
    await expect(main).toBeVisible();
    await expect(main).toHaveCSS('text-align', 'center');
  });
});
