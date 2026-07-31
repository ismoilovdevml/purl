import { test, expect } from '@playwright/test';
import { login, gotoTab, expandSidebarPanel } from './fixtures/purl.js';

/**
 * Regression guard for the modal-input bug: clicking or typing into a field
 * inside a modal used to close the modal, because the overlay's click handler
 * saw the event.
 *
 * This file replaces three: modal-input.spec.js, modal-keypress-debug.spec.js
 * and modal-real-user.spec.js. The first two were debugging scratchpads left
 * in the suite —
 *   - modal-keypress-debug.spec.js had no assertion in any of its three tests
 *     and called getEventListeners(), a DevTools-console-only API that does not
 *     exist in a Playwright page, so it could never fail;
 *   - modal-input.spec.js duplicated modal-real-user.spec.js, and its third test
 *     announced itself as a debugging capture in its own name.
 * The layering check from modal-real-user.spec.js is kept because it carried a
 * real assertion; the console.log narration around it is gone.
 */
test.describe('Modal input interaction', () => {
  test.beforeEach(async ({ page }) => {
    await login(page);
    await gotoTab(page, 'Logs');
  });

  const openSavedSearchModal = async (page) => {
    const panel = await expandSidebarPanel(page, '.saved-searches');
    await panel.locator('[title="Save current search"]').click();
    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible();
    return modal;
  };

  const openAlertModal = async (page) => {
    const panel = await expandSidebarPanel(page, '.alerts-panel');
    await panel.locator('[title="Create alert"]').click();
    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible();
    return modal;
  };

  test('Saved Search modal survives clicking and typing in its fields', async ({ page }) => {
    const modal = await openSavedSearchModal(page);

    const name = modal.getByLabel('Name', { exact: true });
    await name.click();
    await expect(modal, 'clicking an input must not dismiss the modal').toBeVisible();

    // pressSequentially, not fill: the bug was in the per-keystroke handling.
    await name.pressSequentially('Hello World', { delay: 20 });
    await expect(modal).toBeVisible();
    await expect(name).toHaveValue('Hello World');

    const query = modal.getByLabel('Query', { exact: true });
    await query.click();
    await expect(modal).toBeVisible();
    await query.pressSequentially('level:ERROR', { delay: 20 });
    await expect(query).toHaveValue('level:ERROR');
    await expect(modal).toBeVisible();

    // Space and Enter are the keys most likely to be swallowed by an overlay
    // or to submit the form out from under the user.
    await name.click();
    await page.keyboard.press('Space');
    await expect(modal).toBeVisible();

    await modal.locator('.modal-footer button.btn-default').click();
    await expect(modal).toHaveCount(0);
  });

  test('Alert modal survives clicking and typing in its fields, including number inputs', async ({ page }) => {
    const modal = await openAlertModal(page);

    const name = modal.getByLabel('Name', { exact: true });
    await name.click();
    await expect(modal).toBeVisible();
    await name.pressSequentially('High Error Rate', { delay: 20 });
    await expect(name).toHaveValue('High Error Rate');

    const query = modal.getByLabel('Query (optional)');
    await query.click();
    await query.pressSequentially('level:ERROR', { delay: 20 });
    await expect(query).toHaveValue('level:ERROR');
    await expect(modal).toBeVisible();

    const threshold = modal.locator('input[type="number"]').first();
    await threshold.click();
    await expect(modal, 'number inputs must not dismiss the modal either').toBeVisible();
    await threshold.fill('42');
    await expect(threshold).toHaveValue('42');

    await modal.locator('select.select-field').selectOption('browser');
    await expect(modal, 'using the select must not dismiss the modal').toBeVisible();

    await modal.locator('.modal-footer button.btn-default').click();
    await expect(modal).toHaveCount(0);
  });

  test('no overlay covers the modal inputs', async ({ page }) => {
    const modal = await openSavedSearchModal(page);
    await expect(modal.locator('input')).not.toHaveCount(0);

    // The original bug's mechanism: elementFromPoint at an input's centre
    // returned the overlay, so the click hit the overlay's dismiss handler.
    const layering = await page.evaluate(() => {
      const dialog = document.querySelector('[role="dialog"]');
      return [...dialog.querySelectorAll('input')].map((input, index) => {
        const rect = input.getBoundingClientRect();
        const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
        return {
          index,
          type: input.type,
          isTopMost: hit === input,
          coveredBy: hit === input ? null : `${hit?.tagName}.${hit?.className || ''}`,
        };
      });
    });

    expect(layering.length).toBeGreaterThan(0);
    const covered = layering.filter((i) => !i.isTopMost);
    expect(
      covered,
      `modal inputs are covered by another element: ${JSON.stringify(covered)}`
    ).toEqual([]);
  });

  test('the overlay still closes the modal when clicked outside the dialog', async ({ page }) => {
    // The other half of the contract: fixing the input bug must not have
    // disabled click-outside-to-close.
    const modal = await openSavedSearchModal(page);
    await page.locator('.modal-overlay').click({ position: { x: 5, y: 5 } });
    await expect(modal).toHaveCount(0);
  });
});
