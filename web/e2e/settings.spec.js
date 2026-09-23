import { test, expect } from '@playwright/test';
import { login, gotoTab, openSettingsSection } from './fixtures/purl.js';

/**
 * Settings page structure.
 *
 * The previous version of this file was ten tests that all did the same thing
 * — assert a nav button exists — and eight of them were wrapped in
 * `if (!isLocked) { ... }`, so an unreachable section passed without asserting
 * anything. One test was an assertion that a locked-section count was
 * non-negative — true of every possible count, including zero.
 *
 * `openSettingsSection()` treats a locked section as a failure, so a gating
 * regression now shows up as a red suite instead of a quiet green one.
 *
 * Purl is open source: there is no License section and no plan gating. The
 * only lock left in this sidebar is the admin-role one, and the suite runs as
 * admin, so every section must be reachable.
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
      'Users',
      'Integrations',
      'About',
    ]) {
      await expect(nav.locator(`button:has-text("${label}")`), `section "${label}" must be listed`).toBeVisible();
    }
  });

  test.describe('sections open for an admin', () => {
    // These used to be `if (!isLocked)` no-ops. Each one now fails if the
    // section is unreachable for the logged-in admin.
    for (const label of [
      'Database', 'Notifications', 'Display', 'API Keys', 'Users', 'Audit Logs',
      'Pipelines', 'LDAP / AD', 'SSO / SAML', 'AI', 'About',
    ]) {
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

  test('no section is locked and there is no License section', async ({ page }) => {
    const nav = page.locator('.settings-nav');
    await expect(nav.locator('button').first()).toBeVisible();
    await expect(nav.locator('button.locked'), 'an admin must reach every section').toHaveCount(0);
    await expect(nav.locator('button', { hasText: 'License' })).toHaveCount(0);
  });

  // These three used to render an "Upgrade" banner in place of the form.
  test('SSO renders its configuration form, not a plan banner', async ({ page }) => {
    await openSettingsSection(page, 'SSO / SAML');
    const content = page.locator('.settings-content');
    await expect(content).toContainText('Enable SAML SSO');
    await expect(content).not.toContainText(/Enterprise|Upgrade/i);
  });

  test('LDAP renders its configuration form, not a plan banner', async ({ page }) => {
    await openSettingsSection(page, 'LDAP / AD');
    const content = page.locator('.settings-content');
    await expect(content).toContainText('Enable LDAP Authentication');
    await expect(content).not.toContainText(/Enterprise|Upgrade/i);
  });

  test('Pipelines offers pipeline creation, not a plan banner', async ({ page }) => {
    await openSettingsSection(page, 'Pipelines');
    const content = page.locator('.settings-content');
    await expect(content.locator('button', { hasText: 'Create Pipeline' })).toBeVisible();
    await expect(content).not.toContainText(/Upgrade/i);
  });
});
