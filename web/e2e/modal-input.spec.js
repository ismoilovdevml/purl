import { test, expect } from '@playwright/test';

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('Modal Input Interaction', () => {
  test.beforeEach(async ({ page }) => {
    // Login first
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    // Check if we're on login page
    const loginForm = page.locator('input[type="password"]');
    if (await loginForm.isVisible({ timeout: 3000 }).catch(() => false)) {
      const usernameInput = page.locator('input[type="text"], input[name="username"]').first();
      await usernameInput.fill(USERNAME);
      await loginForm.fill(PASSWORD);
      await page.locator('button[type="submit"], button:has-text("Login"), button:has-text("Sign")').first().click();
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(1000);
    }
  });

  test('SavedSearches modal - input fields should be clickable and typeable', async ({ page }) => {
    // Expand Saved Searches section
    const savedSearchesHeader = page.locator('text=Saved Searches').first();
    await expect(savedSearchesHeader).toBeVisible({ timeout: 10000 });

    // Click the + button to open the save modal
    // The + button is in the header-actions span next to "Saved Searches"
    const addButton = page.locator('.saved-searches .header-actions button, .saved-searches [title="Save current search"]').first();
    await expect(addButton).toBeVisible({ timeout: 5000 });
    await addButton.click();

    // Wait for modal to appear
    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });

    // Try to click and type in the Name input
    const nameInput = modal.locator('input').first();
    await expect(nameInput).toBeVisible({ timeout: 3000 });

    // DEBUG: Log the state before clicking
    console.log('Modal visible:', await modal.isVisible());
    console.log('Input visible:', await nameInput.isVisible());
    console.log('Input enabled:', await nameInput.isEnabled());

    // Click the input
    await nameInput.click();
    await page.waitForTimeout(300);

    // Check modal is still open after clicking input
    const modalStillVisible = await modal.isVisible();
    console.log('Modal still visible after input click:', modalStillVisible);
    expect(modalStillVisible).toBe(true);

    // Type in the input
    await nameInput.fill('Test Search Name');
    const inputValue = await nameInput.inputValue();
    console.log('Input value after fill:', inputValue);
    expect(inputValue).toBe('Test Search Name');

    // Try the query input too
    const allInputs = modal.locator('input');
    const inputCount = await allInputs.count();
    console.log('Number of inputs in modal:', inputCount);

    if (inputCount > 1) {
      const queryInput = allInputs.nth(1);
      await queryInput.click();
      await page.waitForTimeout(300);

      // Modal should still be open
      expect(await modal.isVisible()).toBe(true);

      await queryInput.fill('level:ERROR');
      expect(await queryInput.inputValue()).toBe('level:ERROR');
    }

    console.log('PASS: All inputs are clickable and typeable');
  });

  test('Alerts modal - input fields should be clickable and typeable', async ({ page }) => {
    // Find and expand Alerts section
    const alertsHeader = page.locator('text=Alerts').first();
    await expect(alertsHeader).toBeVisible({ timeout: 10000 });

    // Click the + button to create alert
    const addButton = page.locator('.alerts-panel .header-actions button[title="Create alert"], .alerts-panel .header-actions button').last();
    await expect(addButton).toBeVisible({ timeout: 5000 });
    await addButton.click();

    // Wait for modal
    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });

    // Try Name input
    const nameInput = modal.locator('input').first();
    await expect(nameInput).toBeVisible();

    await nameInput.click();
    await page.waitForTimeout(300);

    // Modal should still be open
    expect(await modal.isVisible()).toBe(true);

    await nameInput.fill('Test Alert Name');
    expect(await nameInput.inputValue()).toBe('Test Alert Name');

    // Try other inputs
    const allInputs = modal.locator('input');
    const count = await allInputs.count();
    console.log('Alert modal input count:', count);

    for (let i = 0; i < count; i++) {
      const input = allInputs.nth(i);
      const type = await input.getAttribute('type');
      console.log(`Input ${i}: type=${type}, visible=${await input.isVisible()}`);

      if (type === 'number') {
        await input.click();
        await page.waitForTimeout(200);
        expect(await modal.isVisible()).toBe(true);
      }
    }

    console.log('PASS: Alert modal inputs work');
  });

  test('DEBUG: capture what happens on modal input click', async ({ page }) => {
    // This test captures detailed event info for debugging

    const savedSearchesHeader = page.locator('text=Saved Searches').first();
    await expect(savedSearchesHeader).toBeVisible({ timeout: 10000 });

    const addButton = page.locator('.saved-searches .header-actions button').first();
    await addButton.click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });

    // Inject event listeners to trace what happens
    await page.evaluate(() => {
      const modal = document.querySelector('[role="dialog"]');
      if (!modal) { console.log('DEBUG: No modal found'); return; }

      const inputs = modal.querySelectorAll('input');
      console.log('DEBUG: Found', inputs.length, 'inputs in modal');

      // Track ALL events on the first input
      const events = ['click', 'mousedown', 'mouseup', 'focus', 'focusin', 'pointerdown', 'pointerup'];
      inputs.forEach((input, i) => {
        events.forEach(evt => {
          input.addEventListener(evt, (e) => {
            console.log(`DEBUG: input[${i}] received ${evt}, target=${e.target.tagName}, defaultPrevented=${e.defaultPrevented}`);
          }, true);
        });
      });

      // Track events on modal overlay
      const overlay = modal.closest('.modal-overlay') || modal.parentElement;
      if (overlay) {
        ['click', 'mousedown', 'pointerdown'].forEach(evt => {
          overlay.addEventListener(evt, (e) => {
            console.log(`DEBUG: overlay received ${evt}, target=${e.target.tagName}.${e.target.className?.split(' ')[0] || ''}`);
          }, true);
        });
      }

      // Track on body
      ['click', 'mousedown'].forEach(evt => {
        document.body.addEventListener(evt, (e) => {
          console.log(`DEBUG: body received ${evt}, target=${e.target.tagName}.${e.target.className?.split(' ')[0] || ''}, propagation stopped=${e.cancelBubble}`);
        }, true);
      });
    });

    // Now click the input and capture console logs
    const consoleLogs = [];
    page.on('console', msg => {
      if (msg.text().includes('DEBUG:')) {
        consoleLogs.push(msg.text());
      }
    });

    const nameInput = modal.locator('input').first();
    await nameInput.click({ force: false });
    await page.waitForTimeout(500);

    // Check if modal closed
    const stillVisible = await modal.isVisible();
    console.log('\n=== DEBUG RESULTS ===');
    console.log('Modal still visible after click:', stillVisible);
    console.log('Console logs captured:');
    consoleLogs.forEach(log => console.log('  ', log));

    // Try to get the active element
    const activeTag = await page.evaluate(() => {
      const el = document.activeElement;
      return `${el.tagName}${el.type ? '[type=' + el.type + ']' : ''}${el.className ? '.' + el.className.split(' ')[0] : ''}`;
    });
    console.log('Active element after click:', activeTag);

    // Check if overlay is covering the input
    const inputBox = await nameInput.boundingBox();
    if (inputBox) {
      const elementAtPoint = await page.evaluate(({ x, y }) => {
        const el = document.elementFromPoint(x, y);
        return el ? `${el.tagName}${el.type ? '[type=' + el.type + ']' : ''}.${el.className?.split(' ')[0] || ''}` : 'null';
      }, { x: inputBox.x + inputBox.width / 2, y: inputBox.y + inputBox.height / 2 });
      console.log('Element at input center point:', elementAtPoint);
    }

    expect(stillVisible).toBe(true);
  });
});
