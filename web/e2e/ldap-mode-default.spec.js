import { test, expect } from '@playwright/test';
import { login, openSettingsSection } from './fixtures/purl.js';

/**
 * #92 — the LDAP Mode select and the stored ldap.mode agree.
 *
 * The backend (Middleware/LDAP.pm) reads groups the Active Directory way only
 * for mode 'ad' and treats anything else as OpenLDAP; its default is 'ldap'
 * (Config/Defaults.pm). The page offered 'activedirectory' / 'openldap' and
 * loaded an unset mode as 'ldap', so an unconfigured instance rendered a Mode
 * select matching no option, and "Active Directory" saved a value the backend
 * did not recognise as AD.
 *
 * GET and PUT /api/settings/ldap are mocked: these tests are about how the
 * page maps a stored mode, and must not change the stack's LDAP config.
 */
const BASE_CONFIG = {
  enabled: 0,
  server: 'ldap://localhost',
  port: 389,
  bind_dn: '',
  bind_password: '',
  search_base: '',
  search_filter: '({user_attr}={username})',
  tls_enabled: 0,
  tls_verify: 'require',
  user_attr: 'uid',
  mail_attr: 'mail',
  group_attr: 'memberOf',
};

function modeSelect(page) {
  return page
    .locator('.settings-section .select-wrapper')
    .filter({ has: page.locator('.select-label', { hasText: /^\s*Mode(\s+ENV)?\s*$/ }) })
    .locator('select');
}

async function openWith(page, { config, fromEnv = {} }) {
  const puts = [];
  await page.route(
    (url) => url.pathname === '/api/settings/ldap',
    (route) => {
      const req = route.request();
      if (req.method() === 'GET') {
        return route.fulfill({ json: { config, from_env: fromEnv } });
      }
      if (req.method() === 'PUT') {
        puts.push(req.postDataJSON());
        return route.fulfill({ json: { status: 'ok', message: 'LDAP settings updated.' } });
      }
      return route.fallback();
    }
  );
  await openSettingsSection(page, 'LDAP / AD');
  await expect(modeSelect(page)).toBeVisible();
  return puts;
}

async function save(page, puts) {
  await page.getByRole('button', { name: 'Save Settings' }).click();
  await expect(page.locator('.settings-section .save-msg')).toHaveText('Settings saved successfully.');
  expect(puts).toHaveLength(1);
  return puts[0];
}

test.describe('LDAP mode select (#92)', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('an unconfigured instance shows OpenLDAP and saves the backend default', async ({ page }) => {
    // No `mode` key at all — nothing ever saved one.
    const puts = await openWith(page, { config: BASE_CONFIG });

    const select = modeSelect(page);
    await expect(select).toHaveValue('ldap');
    await expect(select.locator('option:checked')).toHaveText('OpenLDAP');
    await expect(select.locator('option')).toHaveText(['Select...', 'Active Directory', 'OpenLDAP']);

    const body = await save(page, puts);
    expect(body.mode).toBe('ldap');
  });

  test('the server default "ldap" loads as OpenLDAP', async ({ page }) => {
    await openWith(page, { config: { ...BASE_CONFIG, mode: 'ldap' } });
    await expect(modeSelect(page)).toHaveValue('ldap');
    await expect(modeSelect(page).locator('option:checked')).toHaveText('OpenLDAP');
  });

  test('the old "activedirectory" value loads as Active Directory and saves as "ad"', async ({ page }) => {
    // 'activedirectory' is what this page used to save for Active Directory.
    const puts = await openWith(page, { config: { ...BASE_CONFIG, mode: 'activedirectory' } });
    await expect(modeSelect(page)).toHaveValue('ad');
    await expect(modeSelect(page).locator('option:checked')).toHaveText('Active Directory');
    expect((await save(page, puts)).mode).toBe('ad');
  });

  test('choosing Active Directory saves "ad", the value the backend acts on', async ({ page }) => {
    const puts = await openWith(page, { config: { ...BASE_CONFIG, enabled: 1, mode: 'ldap' } });

    await modeSelect(page).selectOption({ label: 'Active Directory' });
    const body = await save(page, puts);
    expect(body.mode).toBe('ad');
    expect(body.user_attr).toBe('sAMAccountName');
  });

  test('an ENV-pinned mode is shown and sent back verbatim', async ({ page }) => {
    const puts = await openWith(page, {
      config: { ...BASE_CONFIG, mode: 'openldap' },
      fromEnv: { mode: 1 },
    });

    const select = modeSelect(page);
    await expect(select).toBeDisabled();
    await expect(select).toHaveValue('openldap');

    // Anything else would be a 409 from reject_env_managed.
    expect((await save(page, puts)).mode).toBe('openldap');
  });
});
