import { test, expect } from '@playwright/test';
import { login, gotoTab } from './fixtures/purl.js';

/**
 * Accessibility regression guards.
 *
 * Two tests in the previous version of this file did this:
 *
 *     const hasAlertRole = await page.evaluate(() => {
 *       const alerts = document.querySelectorAll('[role="alert"]');
 *       return true; // Pattern verified in source code
 *     });
 *     expect(hasAlertRole).toBe(true);
 *
 * — a DOM query whose result was thrown away, followed by an assertion that a
 * hardcoded literal equals itself. Neither test could fail under any
 * circumstance. They are replaced below by tests that actually render
 * the error banner (by injecting a server failure) and assert on the real DOM.
 */
test.describe('Accessibility', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
  });

  test('nav buttons are keyboard focusable', async ({ page }) => {
    const navButtons = page.locator('.nav-tabs button');
    const count = await navButtons.count();
    expect(count).toBeGreaterThan(0);

    for (let i = 0; i < count; i++) {
      const btn = navButtons.nth(i);
      await btn.focus();
      await expect(btn).toBeFocused();
    }
  });

  test('a nav tab can be activated with the keyboard alone', async ({ page }) => {
    const tracesBtn = page.locator('.nav-tabs button:has-text("Traces")');
    await tracesBtn.focus();
    await expect(tracesBtn).toBeFocused();

    await page.keyboard.press('Enter');
    await expect(tracesBtn).toHaveClass(/active/);
    expect(page.url()).toContain('#traces');
  });

  test('Tab moves focus through interactive elements only', async ({ page }) => {
    await gotoTab(page, 'Logs');
    await page.locator('body').click({ position: { x: 1, y: 1 } });

    const seen = [];
    for (let i = 0; i < 12; i++) {
      await page.keyboard.press('Tab');
      seen.push(
        await page.evaluate(() => {
          const el = document.activeElement;
          if (!el || el === document.body) return 'body';
          const tag = el.tagName.toLowerCase();
          const role = el.getAttribute('role');
          return role ? `${tag}[role=${role}]` : tag;
        })
      );
    }

    // Every stop must be interactive: either a natively focusable element or
    // one carrying an interactive ARIA role. A bare `tabindex` on a plain
    // <div> with no role would show up here as a regression.
    const interactiveTags = ['button', 'input', 'a', 'select', 'textarea'];
    const interactiveRoles = ['button', 'link', 'checkbox', 'switch', 'tab', 'menuitem', 'combobox', 'textbox', 'search'];
    const nonInteractive = seen.filter((entry) => {
      const [, tag, role] = entry.match(/^([a-z]+)(?:\[role=(.+)\])?$/) || [];
      if (interactiveTags.includes(tag)) return false;
      return !(role && interactiveRoles.includes(role));
    });
    expect(nonInteractive, `focus landed on non-interactive elements: ${nonInteractive.join(', ')}`).toEqual([]);
  });

  test('shared Button keeps a visible focus ring', async ({ page }) => {
    await gotoTab(page, 'Logs');
    const refreshBtn = page.locator('.header-actions button.btn', { hasText: 'Refresh' }).first();
    await expect(refreshBtn).toBeVisible();

    // Focus via the keyboard so :focus-visible applies (a programmatic
    // .focus() after a mouse click does not match in Chromium).
    await refreshBtn.evaluate((el) => el.focus({ focusVisible: true }));
    const outline = await refreshBtn.evaluate((el) => {
      const s = getComputedStyle(el);
      return { width: s.outlineWidth, style: s.outlineStyle, color: s.outlineColor };
    });

    // `outline-width` on its own proves nothing — Chromium computes `3px` even
    // for a button with `outline: none`, because the width property keeps its
    // value and the *style* is what suppresses the ring. So the style check has
    // to come first, and the colour has to be checked too: a transparent ring
    // is an invisible ring.
    expect(outline.style, 'focused Button must render an outline').not.toBe('none');
    expect(parseFloat(outline.width), 'focus outline must have non-zero width').toBeGreaterThan(0);
    expect(outline.color, 'focus outline must not be transparent').not.toMatch(/transparent|, ?0\)$/);
  });

  test('the hamburger button is labelled', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    const hamburger = page.locator('button.hamburger');
    await expect(hamburger).toBeVisible();
    await expect(hamburger).toHaveAttribute('aria-label', 'Toggle menu');
  });

  test('the search input is labelled', async ({ page }) => {
    await gotoTab(page, 'Logs');
    await expect(page.locator('input[aria-label="Search logs"]')).toBeVisible();
  });

  test('dropdown triggers toggle aria-expanded', async ({ page }) => {
    await gotoTab(page, 'Logs');

    const trigger = page.locator('[aria-haspopup="menu"]').first();
    await expect(trigger).toBeVisible();

    // The old version only asserted `expect(expanded).toBeDefined()` — true for
    // the string "false", for "null" and for undefined alike. Assert the state
    // machine instead.
    await expect(trigger).toHaveAttribute('aria-expanded', 'false');
    await trigger.click();
    await expect(trigger).toHaveAttribute('aria-expanded', 'true');
    await expect(page.locator('.dropdown-menu.open')).toHaveCount(1);
    await page.keyboard.press('Escape');
    await expect(trigger).toHaveAttribute('aria-expanded', 'false');
    // The attribute must describe reality: the menu itself is closed too.
    await expect(page.locator('.dropdown-menu.open')).toHaveCount(0);
  });

  test('the error banner is announced with role="alert" and has a labelled dismiss button', async ({ page }) => {
    await gotoTab(page, 'Logs');

    // Force a real failure rather than asserting on a pattern we hope exists.
    await page.route(
      (url) => url.pathname === '/api/logs',
      async (route) => {
        if (route.request().method() !== 'GET') return route.fallback();
        await route.fulfill({
          status: 500,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'e2e injected failure' }),
        });
      }
    );

    await page.locator('.header-actions button.btn', { hasText: 'Refresh' }).first().click();

    const banner = page.locator('.error-banner');
    await expect(banner).toBeVisible();
    await expect(banner).toHaveAttribute('role', 'alert');
    await expect(banner.locator('span').first()).not.toBeEmpty();

    const dismiss = banner.locator('.dismiss-btn');
    await expect(dismiss).toBeVisible();
    await expect(dismiss).toHaveAttribute('aria-label', 'Dismiss error');

    await dismiss.click();
    await expect(banner).toHaveCount(0);
  });

  test('a modal is a dialog, traps initial focus and closes on Escape', async ({ page }) => {
    await gotoTab(page, 'Logs');

    const actions = page.locator('.actions-dropdown button.dropdown-trigger', { hasText: 'Actions' }).last();
    await expect(actions).toBeVisible();
    await actions.click();
    await page.locator('.dropdown-menu.open button:has-text("Save Search")').click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible();
    await expect(modal).toHaveAttribute('aria-modal', 'true');
    await expect(modal).toHaveAttribute('aria-labelledby', 'modal-title');
    await expect(modal.locator('.modal-close')).toHaveAttribute('aria-label', 'Close modal');

    // Modal.svelte moves focus into the dialog on open; without it a screen
    // reader user stays parked behind the overlay.
    const focusInsideModal = await page.evaluate(() =>
      Boolean(document.querySelector('[role="dialog"]')?.contains(document.activeElement))
    );
    expect(focusInsideModal, 'focus must move into the dialog when it opens').toBe(true);

    await page.keyboard.press('Escape');
    await expect(modal).toHaveCount(0);
  });

  test('body text meets the WCAG AA contrast ratio against the page background', async ({ page }) => {
    // The previous version asserted `expect(bg).toBeTruthy()`, which
    // getComputedStyle can never fail — it always returns a non-empty string,
    // even for a fully transparent colour. The test claimed contrast and
    // measured nothing. Compute the real ratio instead.
    const { bg, fg } = await page.locator('body').evaluate((el) => {
      const s = getComputedStyle(el);
      // `background-color` on <body> is commonly transparent, with the paint
      // coming from <html>. Walk up until something opaque is found.
      let bgEl = el;
      let bgColor = s.backgroundColor;
      while (bgEl && /^rgba\(.*,\s*0\)$/.test(bgColor)) {
        bgEl = bgEl.parentElement;
        bgColor = bgEl ? getComputedStyle(bgEl).backgroundColor : 'rgb(255, 255, 255)';
      }
      return { bg: bgColor, fg: s.color };
    });

    const luminance = (color) => {
      const [r, g, b] = color.match(/[\d.]+/g).slice(0, 3).map(Number);
      const channel = (v) => {
        const c = v / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
      };
      return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
    };

    const l1 = luminance(fg);
    const l2 = luminance(bg);
    const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);

    expect(
      ratio,
      `body text ${fg} on ${bg} has a contrast ratio of ${ratio.toFixed(2)}:1, below the WCAG AA minimum of 4.5:1`
    ).toBeGreaterThanOrEqual(4.5);
  });
});
