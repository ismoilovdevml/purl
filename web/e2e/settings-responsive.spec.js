import { test, expect } from '@playwright/test';
import { login } from './fixtures/purl.js';

/**
 * #119: the Settings section nav was a fixed 220px column at every width, so
 * on a phone the section itself got ~150px — table headers ran together,
 * "Add User" was cut off at the right edge, role badges were truncated.
 *
 * Below 900px the nav collapses into a section <select> and the section uses
 * the full width. At phone and tablet widths every section must render with
 * nothing past the right edge of the viewport. Content inside a horizontal
 * scroller (a wide table in an overflow-x: auto wrapper) is reachable, so it
 * does not count.
 */

const VIEWPORTS = [
  { width: 390, height: 844 },
  { width: 768, height: 1024 },
];

/** Every rendered element in the settings page whose box leaves the viewport. */
async function settingsOverflow(page) {
  return page.evaluate(() => {
    const vw = document.documentElement.clientWidth;
    const root = document.querySelector('.settings-page');
    const scrollsX = (el) => ['auto', 'scroll'].includes(getComputedStyle(el).overflowX);
    // A scroller *inside* the section (a table wrapper). .settings-content
    // itself scrolls vertically, which makes its overflow-x compute to auto
    // too — a section sliding sideways inside it is exactly the defect.
    const content = root.querySelector('.settings-content');
    const insideScroller = (el) => {
      for (let a = el.parentElement; a && a !== content && a !== root; a = a.parentElement) {
        if (scrollsX(a) && a.getBoundingClientRect().right <= vw + 0.5) return true;
      }
      return false;
    };
    const offenders = [];
    for (const el of root.querySelectorAll('*')) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      if ((r.right > vw + 0.5 || r.left < -0.5) && !insideScroller(el)) {
        const label = (el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 30);
        offenders.push(`${el.tagName.toLowerCase()}.${[...el.classList].join('.')} "${label}" [${Math.round(r.left)}..${Math.round(r.right)}]`);
      }
    }
    return { vw, scrollWidth: document.documentElement.scrollWidth, offenders: offenders.slice(0, 10) };
  });
}

test.describe('Settings on narrow screens (#119)', () => {
  for (const viewport of VIEWPORTS) {
    test(`every section fits at ${viewport.width}x${viewport.height}`, async ({ page }) => {
      test.setTimeout(180_000);
      await page.setViewportSize(viewport);
      await login(page);
      await page.goto('/#settings');
      await expect(page.locator('.settings-page')).toBeVisible();

      // The sidebar gives way to a picker, and the content gets the width.
      await expect(page.locator('.settings-nav')).toBeHidden();
      const picker = page.locator('.settings-mobile-nav select');
      await expect(picker).toBeVisible();
      const content = await page.locator('.settings-content').boundingBox();
      expect(content.width, 'section content must use the full width').toBeGreaterThanOrEqual(viewport.width - 1);

      const sections = await picker.locator('option:not([disabled])').evaluateAll((opts) =>
        opts.map((o) => ({ id: o.value, label: o.textContent.trim() }))
      );
      expect(sections.length, 'an admin must be able to pick every section').toBeGreaterThan(10);

      const failures = [];
      for (const section of sections) {
        await picker.selectOption(section.id);
        await expect(page).toHaveURL(new RegExp(`#settings/${section.id}$`));
        // Sections load their data after mounting (and some keep polling, so
        // there is no network-idle to wait for): give each one a few seconds
        // to settle into a layout that fits before calling it a failure.
        let last = null;
        const fits = await expect
          .poll(async () => {
            last = await settingsOverflow(page);
            return last.offenders.length === 0 && last.scrollWidth <= last.vw;
          }, { timeout: 5_000 })
          .toBe(true)
          .then(() => true, () => false);
        if (!fits) {
          failures.push(`${section.label}: scrollWidth ${last.scrollWidth} vs ${last.vw}: ${last.offenders.join(' | ')}`);
        }
      }
      expect(failures, 'no settings section may extend past the viewport').toEqual([]);
    });
  }

  test('the section picker navigates and keeps the deep link', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await login(page);
    await page.goto('/#settings/users');
    const picker = page.locator('.settings-mobile-nav select');
    await expect(picker).toHaveValue('users');
    await expect(page.locator('.settings-content')).toContainText('Add User');

    await picker.selectOption('about');
    await expect(page).toHaveURL(/#settings\/about$/);
    await expect(picker).toHaveValue('about');
  });

  test('the sidebar is still the nav on a desktop', async ({ page }) => {
    await login(page);
    await page.goto('/#settings');
    await expect(page.locator('.settings-nav')).toBeVisible();
    await expect(page.locator('.settings-mobile-nav')).toBeHidden();
  });
});
