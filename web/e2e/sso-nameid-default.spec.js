import { test, expect } from '@playwright/test';
import { login, openSettingsSection } from './fixtures/purl.js';

/**
 * #99 — the SSO NameID Format select and the stored saml.name_id_format agree.
 *
 * Middleware/SAML.pm maps the short names emailAddress / persistent /
 * transient / unspecified to their URNs and falls back to emailAddress for
 * anything else; the server default is 'emailAddress' (Config/Defaults.pm).
 * The page offered and saved full URNs — which that map does not contain, so
 * every choice silently became emailAddress — and rendered an unconfigured
 * instance's 'emailAddress' as a select matching no option.
 *
 * GET and PUT /api/settings/sso are mocked: these tests are about how the
 * page maps a stored format, and must not change the stack's SAML config.
 */
const BASE_CONFIG = {
  enabled: 0,
  entity_id: '',
  idp_entity_id: '',
  idp_sso_url: '',
  idp_slo_url: '',
  idp_cert: '',
  acs_url: '',
  sign_requests: 0,
  sp_cert: '',
  sp_key: '',
  username_attr: 'email',
  groups_attr: 'groups',
  allowed_groups: '',
  force_authn: 0,
};

function nameIdSelect(page) {
  return page
    .locator('.settings-section .select-wrapper')
    .filter({ has: page.locator('.select-label', { hasText: /^\s*NameID Format\s*$/ }) })
    .locator('select');
}

async function openWith(page, { config, fromEnv = {} }) {
  const puts = [];
  await page.route(
    (url) => url.pathname === '/api/settings/sso',
    (route) => {
      const req = route.request();
      if (req.method() === 'GET') {
        return route.fulfill({ json: { config, from_env: fromEnv } });
      }
      if (req.method() === 'PUT') {
        puts.push(req.postDataJSON());
        return route.fulfill({ json: { status: 'ok', message: 'SSO settings updated.' } });
      }
      return route.fallback();
    }
  );
  await openSettingsSection(page, 'SSO / SAML');
  await expect(nameIdSelect(page)).toBeVisible();
  return puts;
}

async function save(page, puts) {
  await page.getByRole('button', { name: 'Save Settings' }).click();
  await expect(page.locator('.settings-section .save-msg')).toHaveText('Settings saved successfully.');
  expect(puts).toHaveLength(1);
  return puts[0];
}

test.describe('SSO NameID format select (#99)', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('an unconfigured instance shows Email Address and saves the backend default', async ({ page }) => {
    const puts = await openWith(page, { config: { ...BASE_CONFIG, name_id_format: 'emailAddress' } });

    const select = nameIdSelect(page);
    await expect(select).toHaveValue('emailAddress');
    await expect(select.locator('option:checked')).toHaveText('Email Address');
    await expect(select.locator('option')).toHaveText(['Select...', 'Email Address', 'Persistent', 'Transient', 'Unspecified']);

    expect((await save(page, puts)).name_id_format).toBe('emailAddress');
  });

  test('a missing format loads as Email Address', async ({ page }) => {
    await openWith(page, { config: BASE_CONFIG });
    await expect(nameIdSelect(page)).toHaveValue('emailAddress');
  });

  test('a URN saved by the old page loads as its short name and saves as it', async ({ page }) => {
    const puts = await openWith(page, {
      config: { ...BASE_CONFIG, name_id_format: 'urn:oasis:names:tc:SAML:2.0:nameid-format:persistent' },
    });
    await expect(nameIdSelect(page)).toHaveValue('persistent');
    await expect(nameIdSelect(page).locator('option:checked')).toHaveText('Persistent');
    expect((await save(page, puts)).name_id_format).toBe('persistent');
  });

  test('choosing Transient saves "transient", the value the backend maps', async ({ page }) => {
    const puts = await openWith(page, { config: { ...BASE_CONFIG, enabled: 1, name_id_format: 'emailAddress' } });
    await nameIdSelect(page).selectOption({ label: 'Transient' });
    expect((await save(page, puts)).name_id_format).toBe('transient');
  });

  test('an ENV-pinned format is shown and sent back verbatim', async ({ page }) => {
    const pinned = 'urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified';
    const puts = await openWith(page, {
      config: { ...BASE_CONFIG, name_id_format: pinned },
      fromEnv: { name_id_format: 1 },
    });

    const select = nameIdSelect(page);
    await expect(select).toBeDisabled();
    await expect(select).toHaveValue(pinned);

    // Anything else would be a 409 from reject_env_managed.
    expect((await save(page, puts)).name_id_format).toBe(pinned);
  });
});
