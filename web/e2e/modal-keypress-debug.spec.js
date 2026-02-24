import { test, expect } from '@playwright/test';

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('Modal Keypress Debug', () => {
  test.beforeEach(async ({ page, context }) => {
    await context.clearCookies();
    const cdp = await context.newCDPSession(page);
    await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });

    await page.goto(BASE);
    await page.waitForLoadState('networkidle');
    await page.locator('input').first().fill(USERNAME);
    await page.locator('input[type="password"]').fill(PASSWORD);
    await page.locator('button:has-text("Sign")').click();
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000);
    await expect(page.locator('text=Saved Searches')).toBeVisible({ timeout: 10000 });
  });

  test('find which key closes the modal', async ({ page }) => {
    // Open modal
    const addBtn = page.locator('.saved-searches .header-actions button').first();
    await addBtn.click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    // Click the input to focus it
    const nameInput = modal.locator('input').first();
    await nameInput.click();
    await page.waitForTimeout(300);

    // Verify focus is on input
    const activeEl = await page.evaluate(() => {
      const el = document.activeElement;
      return `${el.tagName}[type=${el.type || 'none'}].${el.className?.split(' ')[0] || ''}`;
    });
    console.log('Active element after click:', activeEl);

    // Type one character at a time and check modal
    const chars = ['a', 'b', 'c', ' ', 'd', 'Enter', 'Tab'];
    for (const char of chars) {
      if (!(await modal.isVisible())) {
        console.log(`Modal CLOSED before typing '${char}'`);
        break;
      }

      console.log(`Pressing '${char}'...`);
      await page.keyboard.press(char);
      await page.waitForTimeout(200);

      const visible = await modal.isVisible();
      console.log(`  After '${char}': modal visible = ${visible}`);

      if (!visible) {
        console.log(`\n!!! MODAL CLOSED BY KEY: '${char}' !!!`);
        break;
      }
    }
  });

  test('trace all keydown handlers that fire during typing', async ({ page }) => {
    const addBtn = page.locator('.saved-searches .header-actions button').first();
    await addBtn.click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    const nameInput = modal.locator('input').first();
    await nameInput.click();
    await page.waitForTimeout(300);

    // Install global keydown tracer
    await page.evaluate(() => {
      // Capture phase - fires first
      document.addEventListener('keydown', (e) => {
        console.log(`[CAPTURE] keydown: key='${e.key}' target=${e.target.tagName}.${e.target.className?.split(' ')[0] || ''} bubbles=${e.bubbles} defaultPrevented=${e.defaultPrevented}`);
      }, true);

      // Bubble phase
      document.addEventListener('keydown', (e) => {
        console.log(`[BUBBLE] keydown: key='${e.key}' target=${e.target.tagName}.${e.target.className?.split(' ')[0] || ''} propagationStopped=${e.cancelBubble} defaultPrevented=${e.defaultPrevented}`);
      }, false);

      // Body listener (Svelte delegation root)
      document.body.addEventListener('keydown', (e) => {
        console.log(`[BODY] keydown: key='${e.key}' target=${e.target.tagName} cancelBubble=${e.cancelBubble}`);
      }, false);

      // Window listener
      window.addEventListener('keydown', (e) => {
        console.log(`[WINDOW] keydown: key='${e.key}' target=${e.target.tagName} cancelBubble=${e.cancelBubble}`);
      }, false);

      // Track modal close - observe DOM changes
      const observer = new MutationObserver((mutations) => {
        for (const m of mutations) {
          for (const node of m.removedNodes) {
            if (node.nodeType === 1 && (node.classList?.contains('modal-overlay') || node.querySelector?.('[role="dialog"]'))) {
              console.log('[MUTATION] modal-overlay REMOVED from DOM!');
            }
          }
        }
      });
      observer.observe(document.body, { childList: true, subtree: true });
    });

    const consoleLogs = [];
    page.on('console', msg => consoleLogs.push(msg.text()));

    // Type just 'a' and see what happens
    console.log('\n--- Pressing "a" ---');
    await page.keyboard.press('a');
    await page.waitForTimeout(500);

    let visible = await modal.isVisible();
    console.log('After "a": modal visible =', visible);

    if (visible) {
      // Try space
      console.log('\n--- Pressing Space ---');
      await page.keyboard.press(' ');
      await page.waitForTimeout(500);
      visible = await modal.isVisible();
      console.log('After Space: modal visible =', visible);
    }

    if (visible) {
      // Try more characters
      console.log('\n--- Pressing "b" ---');
      await page.keyboard.press('b');
      await page.waitForTimeout(500);
      visible = await modal.isVisible();
      console.log('After "b": modal visible =', visible);
    }

    // Print all captured console logs
    console.log('\n=== ALL CONSOLE LOGS ===');
    consoleLogs.forEach(log => console.log('  ', log));

    // Take final screenshot
    await page.screenshot({ path: 'test-results/keypress-debug-final.png' });
  });

  test('check if modal has window keydown or event stealing', async ({ page }) => {
    const addBtn = page.locator('.saved-searches .header-actions button').first();
    await addBtn.click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    // Check how many window keydown listeners exist
    const listenerInfo = await page.evaluate(() => {
      // Check for Svelte event delegation on body
      const bodyListeners = getEventListeners ? getEventListeners(document.body) : {};
      const windowListeners = getEventListeners ? getEventListeners(window) : {};

      // Check all elements with keydown handlers
      const allElements = document.querySelectorAll('*');
      const keydownElements = [];
      allElements.forEach(el => {
        if (el.__listeners || el.onkeydown || el.getAttribute('onkeydown')) {
          keydownElements.push(`${el.tagName}.${el.className?.split(' ')[0]}`);
        }
      });

      // Check the modal overlay specifically
      const overlay = document.querySelector('.modal-overlay');
      const dialog = document.querySelector('[role="dialog"]');

      return {
        hasOverlay: !!overlay,
        hasDialog: !!dialog,
        overlayParent: overlay?.parentElement?.tagName + '.' + (overlay?.parentElement?.className?.split(' ')[0] || ''),
        dialogParent: dialog?.parentElement?.tagName + '.' + (dialog?.parentElement?.className?.split(' ')[0] || ''),
        overlayOnClick: !!overlay?.onclick,
        dialogOnClick: !!dialog?.onclick,
      };
    });

    console.log('Listener info:', JSON.stringify(listenerInfo, null, 2));

    // Focus the input and check if focus stays
    const nameInput = modal.locator('input').first();
    await nameInput.click();
    await page.waitForTimeout(300);

    for (let i = 0; i < 5; i++) {
      const activeTag = await page.evaluate(() => {
        const el = document.activeElement;
        return `${el.tagName}[type=${el.type || 'none'}].${el.className?.split(' ')[0] || ''}`;
      });
      console.log(`Focus check ${i}: ${activeTag}`);
      await page.waitForTimeout(100);
    }

    // Try typing a single character and check focus before/after
    await nameInput.click();
    await page.waitForTimeout(200);

    const beforeFocus = await page.evaluate(() => document.activeElement.tagName + '.' + (document.activeElement.className?.split(' ')[0] || ''));
    console.log('Before keypress focus:', beforeFocus);

    await page.keyboard.type('x');
    await page.waitForTimeout(200);

    const afterFocus = await page.evaluate(() => document.activeElement?.tagName + '.' + (document.activeElement?.className?.split(' ')[0] || ''));
    const modalVisible = await modal.isVisible();
    console.log('After keypress focus:', afterFocus);
    console.log('Modal visible after keypress:', modalVisible);
  });
});
