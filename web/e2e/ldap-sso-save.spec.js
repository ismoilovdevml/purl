import { test, expect } from '@playwright/test';
import { login, openSettingsSection, csrfHeaders } from './fixtures/purl.js';

/**
 * LDAP / SSO settings: what the page PUTs, and what comes back.
 *
 * The runes migration rewrote both pages' form state (one `form` object keyed
 * by the config keys, `port` held as a string for the number input). These
 * specs pin the wire contract — the exact PUT body, `port` a number, every
 * flag a real boolean — and then reload to prove the saved values repopulate
 * the form from the server.
 *
 * They drive the real backend. The original config is read first and PUT
 * back in `finally`, so an enabled LDAP / SAML config never leaks into the
 * rest of the (serial) suite — login.spec.js, for one, expects SSO off.
 */

/** Flip a role=switch to `want`, whatever state the stack left it in. */
async function setSwitch(toggle, want) {
  await expect(toggle).toBeEnabled();
  if ((await toggle.getAttribute('aria-checked')) !== String(want)) {
    await toggle.click();
  }
  await expect(toggle).toHaveAttribute('aria-checked', String(want));
}

/** The <select> of a ui/Select whose label is exactly `label`. */
function selectByLabel(scope, label) {
  return scope
    .locator('.select-wrapper')
    .filter({ has: scope.page().locator('.select-label', { hasText: new RegExp(`^\\s*${label}\\s*$`) }) })
    .locator('select');
}

async function readConfig(page, path) {
  const res = await page.request.get(path);
  expect(res.ok(), `GET ${path} failed: ${res.status()}`).toBe(true);
  return (await res.json()).config;
}

async function restoreConfig(page, path, config) {
  const res = await page.request.put(path, {
    headers: await csrfHeaders(page),
    // A masked secret ('********') is the API's "unchanged" marker, so a
    // secret this spec overwrote stays overwritten; the e2e stack sets none.
    data: config,
  });
  expect(res.ok(), `restoring ${path} failed: ${res.status()} ${await res.text()}`).toBe(true);
}

test.describe('LDAP and SSO settings save round-trip', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('LDAP: the PUT body is typed correctly and the saved values reload', async ({ page }) => {
    const original = await readConfig(page, '/api/settings/ldap');
    try {
      await openSettingsSection(page, 'LDAP / AD');
      const section = page.locator('.settings-section', {
        has: page.locator('h3', { hasText: 'LDAP / Active Directory' }),
      });

      await setSwitch(section.getByRole('switch', { name: 'Enable LDAP Authentication' }), true);
      await section.getByLabel('LDAP Server URL', { exact: true }).fill('ldap://ldap.e2e.test');
      await section.getByLabel('Port', { exact: true }).fill('1389');
      await setSwitch(section.getByRole('switch', { name: 'Use TLS / LDAPS' }), true);
      await selectByLabel(section, 'TLS Verify').selectOption('optional');
      await section.getByLabel('Bind DN', { exact: true }).fill('cn=svc,dc=e2e,dc=test');
      await section.getByLabel('Bind Password', { exact: true }).fill('e2e-secret');
      await section.getByLabel('Search Base', { exact: true }).fill('dc=e2e,dc=test');
      await selectByLabel(section, 'Mode').selectOption('ad');
      await section.getByLabel('Search Filter', { exact: true }).fill('(sAMAccountName={username})');

      await section.locator('button.advanced-toggle').click();
      // Choosing Active Directory prefills the attributes; set them anyway so
      // the expected body does not depend on that side effect.
      await section.getByLabel('Username Attribute', { exact: true }).fill('sAMAccountName');
      await section.getByLabel('Mail Attribute', { exact: true }).fill('userPrincipalName');
      await section.getByLabel('Group Attribute', { exact: true }).fill('memberOf');

      const put = page.waitForRequest(
        (req) => new URL(req.url()).pathname === '/api/settings/ldap' && req.method() === 'PUT'
      );
      await section.getByRole('button', { name: 'Save Settings' }).click();
      const body = (await put).postDataJSON();

      expect(body).toStrictEqual({
        enabled: true,
        server: 'ldap://ldap.e2e.test',
        port: 1389,
        tls_enabled: true,
        tls_verify: 'optional',
        bind_dn: 'cn=svc,dc=e2e,dc=test',
        bind_password: 'e2e-secret',
        search_base: 'dc=e2e,dc=test',
        mode: 'ad',
        search_filter: '(sAMAccountName={username})',
        user_attr: 'sAMAccountName',
        mail_attr: 'userPrincipalName',
        group_attr: 'memberOf',
      });
      expect(typeof body.port).toBe('number');
      expect(typeof body.enabled).toBe('boolean');
      expect(typeof body.tls_enabled).toBe('boolean');
      await expect(section.locator('.save-msg')).toHaveText('Settings saved successfully.');

      await page.reload();
      await openSettingsSection(page, 'LDAP / AD');
      await expect(section.getByRole('switch', { name: 'Enable LDAP Authentication' }))
        .toHaveAttribute('aria-checked', 'true');
      await expect(section.getByLabel('LDAP Server URL', { exact: true })).toHaveValue('ldap://ldap.e2e.test');
      await expect(section.getByLabel('Port', { exact: true })).toHaveValue('1389');
      await expect(section.getByRole('switch', { name: 'Use TLS / LDAPS' })).toHaveAttribute('aria-checked', 'true');
      await expect(selectByLabel(section, 'TLS Verify')).toHaveValue('optional');
      await expect(section.getByLabel('Bind DN', { exact: true })).toHaveValue('cn=svc,dc=e2e,dc=test');
      // The server never discloses the password, only that one is set.
      await expect(section.getByLabel('Bind Password', { exact: true })).toHaveValue('********');
      await expect(section.getByLabel('Search Base', { exact: true })).toHaveValue('dc=e2e,dc=test');
      await expect(selectByLabel(section, 'Mode')).toHaveValue('ad');
      await expect(section.getByLabel('Search Filter', { exact: true })).toHaveValue('(sAMAccountName={username})');
      await section.locator('button.advanced-toggle').click();
      await expect(section.getByLabel('Mail Attribute', { exact: true })).toHaveValue('userPrincipalName');
    } finally {
      await restoreConfig(page, '/api/settings/ldap', original);
    }
  });

  test('SSO: the PUT body is typed correctly and the saved values reload', async ({ page }) => {
    const original = await readConfig(page, '/api/settings/sso');
    const cert = '-----BEGIN CERTIFICATE-----\nMIIBe2e\n-----END CERTIFICATE-----';
    // Middleware/SAML.pm maps the short name to its URN (#99).
    const persistent = 'persistent';
    try {
      await openSettingsSection(page, 'SSO / SAML');
      const section = page.locator('.settings-section', {
        has: page.locator('h3', { hasText: 'SAML / SSO' }),
      });

      await setSwitch(section.getByRole('switch', { name: 'Enable SAML SSO' }), true);
      await section.getByLabel('IdP Entity ID', { exact: true }).fill('https://idp.e2e.test/metadata');
      await section.getByLabel('IdP SSO URL', { exact: true }).fill('https://idp.e2e.test/sso');
      await section.getByLabel('IdP SLO URL (optional)', { exact: true }).fill('');
      await section.getByLabel('IdP Certificate (PEM)', { exact: true }).fill(cert);
      await section.getByLabel('SP Entity ID', { exact: true }).fill('https://purl.e2e.test');
      await section.getByLabel('Assertion Consumer Service (ACS) URL', { exact: true })
        .fill('https://purl.e2e.test/api/auth/saml/acs');
      await selectByLabel(section, 'NameID Format').selectOption(persistent);
      await setSwitch(section.getByRole('switch', { name: 'Sign Authentication Requests' }), true);
      await setSwitch(section.getByRole('switch', { name: 'Force Authentication' }), false);

      await section.locator('button.advanced-toggle').click();
      await section.getByLabel('Username Attribute', { exact: true }).fill('email');
      await section.getByLabel('Groups Attribute', { exact: true }).fill('groups');
      await section.getByLabel('Allowed Groups', { exact: true }).fill('purl-admins');
      await section.getByLabel('SP Certificate (PEM, optional)', { exact: true }).fill('');
      await section.getByLabel('SP Private Key (PEM, optional)', { exact: true }).fill('');

      const put = page.waitForRequest(
        (req) => new URL(req.url()).pathname === '/api/settings/sso' && req.method() === 'PUT'
      );
      await section.getByRole('button', { name: 'Save Settings' }).click();
      const body = (await put).postDataJSON();

      expect(body).toStrictEqual({
        enabled: true,
        idp_entity_id: 'https://idp.e2e.test/metadata',
        idp_sso_url: 'https://idp.e2e.test/sso',
        idp_slo_url: '',
        idp_cert: cert,
        entity_id: 'https://purl.e2e.test',
        acs_url: 'https://purl.e2e.test/api/auth/saml/acs',
        name_id_format: persistent,
        sign_requests: true,
        sp_cert: '',
        sp_key: '',
        username_attr: 'email',
        groups_attr: 'groups',
        allowed_groups: 'purl-admins',
        force_authn: false,
      });
      for (const flag of ['enabled', 'sign_requests', 'force_authn']) {
        expect(typeof body[flag], `${flag} must be a JSON boolean`).toBe('boolean');
      }
      await expect(section.locator('.save-msg')).toHaveText('Settings saved successfully.');

      await page.reload();
      await openSettingsSection(page, 'SSO / SAML');
      await expect(section.getByRole('switch', { name: 'Enable SAML SSO' })).toHaveAttribute('aria-checked', 'true');
      await expect(section.getByLabel('IdP Entity ID', { exact: true })).toHaveValue('https://idp.e2e.test/metadata');
      await expect(section.getByLabel('IdP SSO URL', { exact: true })).toHaveValue('https://idp.e2e.test/sso');
      await expect(section.getByLabel('IdP Certificate (PEM)', { exact: true })).toHaveValue(cert);
      await expect(section.getByLabel('SP Entity ID', { exact: true })).toHaveValue('https://purl.e2e.test');
      await expect(section.getByLabel('Assertion Consumer Service (ACS) URL', { exact: true }))
        .toHaveValue('https://purl.e2e.test/api/auth/saml/acs');
      await expect(selectByLabel(section, 'NameID Format')).toHaveValue(persistent);
      await expect(section.getByRole('switch', { name: 'Sign Authentication Requests' }))
        .toHaveAttribute('aria-checked', 'true');
      await expect(section.getByRole('switch', { name: 'Force Authentication' }))
        .toHaveAttribute('aria-checked', 'false');
      await section.locator('button.advanced-toggle').click();
      await expect(section.getByLabel('Allowed Groups', { exact: true })).toHaveValue('purl-admins');
    } finally {
      await restoreConfig(page, '/api/settings/sso', original);
    }
  });
});
