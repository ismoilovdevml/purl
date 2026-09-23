import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * #102: a focused text field drew TWO focus indicators — the shell's ring and
 * a second rectangle around the text area. The global `input:focus-visible`
 * outline landed on the borderless <input> that sits inside ui/Input's
 * bordered `.input-container` (same pattern: the fields filter, the cluster
 * picker). The fix (styles/focus.css `.focus-shell`) moves the one ring onto
 * the shell.
 *
 * Asserted on computed styles, which is what the user sees: the inner field
 * must draw no outline while its shell draws a visible one. Without the fix
 * the inner <input> reports `outline-style: solid` and the shell `none`.
 */

async function outlines(field) {
  return field.evaluate((el) => {
    const shell = el.parentElement;
    const inner = getComputedStyle(el);
    const outer = getComputedStyle(shell);
    return {
      focusVisible: el.matches(':focus-visible'),
      innerStyle: inner.outlineStyle,
      innerWidth: parseFloat(inner.outlineWidth),
      shellStyle: outer.outlineStyle,
      shellWidth: parseFloat(outer.outlineWidth),
    };
  });
}

function expectSingleRing(o, what) {
  expect(o.focusVisible, `${what}: focus must be keyboard-visible`).toBe(true);
  expect(
    o.innerStyle === 'none' || o.innerWidth === 0,
    `${what}: the inner field must not draw its own ring (got ${o.innerStyle} ${o.innerWidth}px)`
  ).toBe(true);
  expect(o.shellStyle, `${what}: the shell must carry the focus ring`).toBe('solid');
  expect(o.shellWidth, `${what}: the shell ring must be visible`).toBeGreaterThanOrEqual(2);
}

test.describe('Focus ring on wrapped inputs (#102)', () => {
  test('login fields show exactly one ring when reached by keyboard', async ({ page }) => {
    await page.goto('/');
    const username = page.locator('input[autocomplete="username"]');
    const password = page.locator('input[type="password"]');
    await expect(username).toBeVisible({ timeout: 30_000 });

    await username.focus();
    await page.keyboard.press('Tab');
    await expect(password).toBeFocused();
    expectSingleRing(await outlines(password), 'password');

    await page.keyboard.press('Shift+Tab');
    await expect(username).toBeFocused();
    expectSingleRing(await outlines(username), 'username');

    // Focus leaves: no ring left behind on the shell.
    await page.locator('body').click({ position: { x: 5, y: 5 } });
    const after = await outlines(password);
    expect(after.shellStyle).toBe('none');
  });

  test('the fields-sidebar filter shows exactly one ring', async ({ page }) => {
    await login(page);
    await gotoTab(page, 'Logs');

    const filter = page.locator('input[aria-label="Filter fields"]');
    await expect(filter).toBeVisible();
    await filter.focus();
    expectSingleRing(await outlines(filter), 'fields filter');
  });
});
