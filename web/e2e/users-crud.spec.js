import { test, expect } from '@playwright/test';
import { login, openSettingsSection, unique, stackEnv } from './fixtures/purl.js';

/**
 * User management: create -> appears in the list -> can log in -> delete.
 *
 * Entirely uncovered before. Note that a created user is a *credential*, so
 * "the row appeared" is not enough — the account has to actually work, and it
 * has to stop working after deletion.
 *
 * The Users section is Pro + admin gated; the managed e2e stack runs on the
 * trial plan as admin, and openSettingsSection() fails loudly rather than
 * skipping if that ever stops being true.
 */
test.describe('Users CRUD', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  const userRow = (page, username) =>
    page.locator('.user-row', { has: page.locator('.username', { hasText: username }) });

  /*
   * `request` (the isolated fixture), never `page.request`.
   *
   * `page.request` shares the BrowserContext cookie jar, so logging in as the
   * newly created operator would overwrite the admin session cookie the page
   * is holding. The very next step — DELETE /api/settings/users/:username — is
   * admin-gated (Settings.pm) and CSRF-checked against the session that just
   * got replaced, so it answered 403 every single run. The isolated fixture
   * has its own jar: the credential is exercised for real, the page's session
   * is untouched. See csrf-mutation.spec.js for the inverse case, where the
   * cookie is copied across deliberately.
   */
  test('creates a user, lists it, then deletes it', async ({ page, request }) => {
    const username = unique('e2euser').replace(/-/g, '');
    const password = 'e2e-User-Pass-1234';

    await openSettingsSection(page, 'Users');
    await expect(userRow(page, username)).toHaveCount(0);

    // --- create -------------------------------------------------------
    await page.locator('.users-header button:has-text("Add User")').click();
    const form = page.locator('.add-form');
    await expect(form).toBeVisible();

    await form.getByLabel('Username').fill(username);
    await form.getByLabel('Password').fill(password);
    await form.locator('#new-role-select').selectOption('operator');

    const createResponse = page.waitForResponse(
      (res) =>
        new URL(res.url()).pathname === '/api/settings/users' && res.request().method() === 'POST'
    );
    await form.locator('button:has-text("Create")').click();

    const created = await createResponse;
    expect(
      created.status(),
      `POST /api/settings/users failed: ${created.status()} ${await created.text()}`
    ).toBeLessThan(300);

    // --- appears with the role we asked for ----------------------------
    const row = userRow(page, username);
    await expect(row).toHaveCount(1);
    await expect(row.locator('.role-badge')).toHaveText('Operator');
    await expect(row.locator('.role-badge')).toHaveClass(/role-operator/);

    // --- survives a reload ---------------------------------------------
    await page.reload();
    await openSettingsSection(page, 'Users');
    await expect(userRow(page, username)).toHaveCount(1);

    // --- the credential actually works ---------------------------------
    const loginOk = await request.post('/api/auth/login', {
      data: { username, password },
    });
    expect(loginOk.status(), 'a newly created user must be able to log in').toBe(200);
    expect((await loginOk.json()).role).toBe('operator');

    // Guard the mistake this spec used to make: the operator login above must
    // not have touched the browser's session. If this ever reads back
    // "operator", the isolation broke and every admin-gated step below would
    // start failing with a 403 that looks like a backend authz bug.
    const whoami = await page.request.get('/api/auth/me');
    expect(whoami.status()).toBe(200);
    expect(
      (await whoami.json()).username,
      'the page must still be the admin — an out-of-band login may not hijack the browser session'
    ).toBe(stackEnv.ADMIN_USERNAME);

    // --- delete (two-click inline confirm, not a dialog) ---------------
    const deleteResponse = page.waitForResponse(
      (res) =>
        new URL(res.url()).pathname === `/api/settings/users/${username}` &&
        res.request().method() === 'DELETE'
    );
    await userRow(page, username).locator('button:has-text("Delete")').click();
    await userRow(page, username).locator('button:has-text("Confirm")').click();

    const deleted = await deleteResponse;
    expect(deleted.status(), `DELETE /api/settings/users failed: ${await deleted.text()}`).toBeLessThan(300);
    await expect(userRow(page, username)).toHaveCount(0);

    // --- and the credential stops working ------------------------------
    const loginAfter = await request.post('/api/auth/login', {
      data: { username, password },
    });
    expect(
      loginAfter.status(),
      'a deleted user must no longer be able to log in'
    ).not.toBe(200);
  });

  test('cancelling the delete confirmation keeps the user', async ({ page }) => {
    const username = unique('e2ekeep').replace(/-/g, '');

    await openSettingsSection(page, 'Users');
    await page.locator('.users-header button:has-text("Add User")').click();
    const form = page.locator('.add-form');
    await form.getByLabel('Username').fill(username);
    await form.getByLabel('Password').fill('e2e-User-Pass-1234');
    await form.locator('button:has-text("Create")').click();
    await expect(userRow(page, username)).toHaveCount(1);

    await userRow(page, username).locator('button:has-text("Delete")').click();
    await userRow(page, username).locator('button:has-text("Cancel")').click();
    await expect(userRow(page, username)).toHaveCount(1);

    // Clean up.
    await userRow(page, username).locator('button:has-text("Delete")').click();
    await userRow(page, username).locator('button:has-text("Confirm")').click();
    await expect(userRow(page, username)).toHaveCount(0);
  });

  test('Create stays disabled until both fields are filled', async ({ page }) => {
    await openSettingsSection(page, 'Users');
    await page.locator('.users-header button:has-text("Add User")').click();

    const form = page.locator('.add-form');
    const create = form.locator('button:has-text("Create")');
    await expect(create).toBeDisabled();

    await form.getByLabel('Username').fill('someone');
    await expect(create).toBeDisabled();

    // Whitespace is not a password.
    await form.getByLabel('Password').fill('   ');
    await expect(create).toBeDisabled();

    await form.getByLabel('Password').fill('e2e-User-Pass-1234');
    await expect(create).toBeEnabled();
  });

  test('the signed-in admin cannot delete their own account', async ({ page }) => {
    await openSettingsSection(page, 'Users');

    const self = userRow(page, stackEnv.ADMIN_USERNAME);
    await expect(self).toHaveCount(1);
    await expect(self.locator('.col-actions button:has-text("Delete")')).toHaveCount(0);
  });
});
