import { test, expect } from '@playwright/test';
import { login, gotoTab, openSettingsSection } from './fixtures/purl.js';

/**
 * Settings page structure.
 *
 * The previous version of this file was ten tests that all did the same thing
 * — assert a nav button exists — and eight of them were wrapped in
 * `if (!isLocked) { ... }`, so on any instance whose licence had lapsed the
 * whole file passed without asserting anything. One test was
 * an assertion that a locked-section count was non-negative — true of every
 * possible count, including zero.
 *
 * `openSettingsSection()` treats a locked section as a failure, so a licence
 * regression now shows up as a red suite instead of a quiet green one.
 */
test.describe('Settings page', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
    await gotoTab(page, 'Settings');
  });

  test('renders the settings shell', async ({ page }) => {
    await expect(page.locator('.settings-page')).toBeVisible();
    await expect(page.locator('.settings-nav h2')).toHaveText('Settings');
  });

  test('lists the expected sections', async ({ page }) => {
    const nav = page.locator('.settings-nav');
    for (const label of [
      'Database',
      'Notifications',
      'Display',
      'API Keys',
      'Sources',
      'License',
      'Users',
      'Integrations',
      'About',
    ]) {
      await expect(nav.locator(`button:has-text("${label}")`), `section "${label}" must be listed`).toBeVisible();
    }
  });

  test.describe('sections open for an admin on the trial plan', () => {
    // These used to be `if (!isLocked)` no-ops. Each one now fails if the
    // section is unreachable for the logged-in admin.
    for (const label of ['Database', 'Notifications', 'Display', 'License', 'API Keys', 'Users', 'About']) {
      test(`${label} opens`, async ({ page }) => {
        await openSettingsSection(page, label);
      });
    }
  });

  test('only one section is active at a time', async ({ page }) => {
    const about = await openSettingsSection(page, 'About');
    await expect(about).toHaveClass(/active/);

    const display = await openSettingsSection(page, 'Display');
    await expect(display).toHaveClass(/active/);
    await expect(about).not.toHaveClass(/active/);
  });

  test('the About section reports the running version', async ({ page }) => {
    await openSettingsSection(page, 'About');
    // Assert an actual version string, not just that the word "version" is on
    // the page somewhere.
    await expect(page.locator('.settings-content')).toContainText(/\d+\.\d+\.\d+/);
  });

  test('enterprise-only sections are marked locked on a trial plan', async ({ page }) => {
    // Trial grants Pro, not Enterprise — so SSO/LDAP must still be gated.
    // This is the positive half of the locking contract; the assertion this
    // replaces covered neither half.
    const nav = page.locator('.settings-nav');
    const sso = nav.locator('button:has-text("SSO / SAML")');
    await expect(sso).toBeVisible();
    await expect(sso).toHaveClass(/locked/);
    await expect(sso).toHaveAttribute('title', /Enterprise/);
  });
});
