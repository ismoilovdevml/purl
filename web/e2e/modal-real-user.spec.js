import { test, expect } from '@playwright/test';

const BASE = 'http://37.27.187.72:3000';
const USERNAME = 'admin';
const PASSWORD = process.env.PURL_TEST_PASSWORD || 'changeme';

test.describe('Modal Real User Interaction (no cache)', () => {
  test.use({
    // Disable cache to ensure fresh assets
    contextOptions: {
      bypassCSP: true,
    },
  });

  test.beforeEach(async ({ page, context }) => {
    // Clear all cookies and cache
    await context.clearCookies();

    // Disable cache at CDP level
    const cdp = await context.newCDPSession(page);
    await cdp.send('Network.setCacheDisabled', { cacheDisabled: true });

    // Login
    await page.goto(BASE);
    await page.waitForLoadState('networkidle');

    const usernameInput = page.locator('input').first();
    const passwordInput = page.locator('input[type="password"]');
    await usernameInput.fill(USERNAME);
    await passwordInput.fill(PASSWORD);
    await page.locator('button:has-text("Sign")').click();
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000);

    // Verify we're logged in - should see the main dashboard
    await expect(page.locator('text=Saved Searches')).toBeVisible({ timeout: 10000 });
  });

  test('SavedSearches: click input, type with keyboard, verify modal stays open', async ({ page }) => {
    // Click + button
    const addBtn = page.locator('.saved-searches .header-actions button').first();
    await addBtn.click();

    // Wait for modal
    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500); // wait for transition

    // Get the name input
    const nameInput = modal.locator('input').first();
    await expect(nameInput).toBeVisible();

    // Step 1: Simple click - modal should stay open
    await nameInput.click();
    await page.waitForTimeout(500);
    expect(await modal.isVisible()).toBe(true);
    console.log('STEP 1 PASS: Modal stayed open after input click');

    // Step 2: Type with real keyboard (not fill)
    await nameInput.pressSequentially('Hello World', { delay: 50 });
    await page.waitForTimeout(300);
    expect(await modal.isVisible()).toBe(true);
    const val = await nameInput.inputValue();
    expect(val).toBe('Hello World');
    console.log('STEP 2 PASS: Typed "Hello World" successfully, value:', val);

    // Step 3: Click another input in the same modal
    const allInputs = modal.locator('input');
    const queryInput = allInputs.nth(1);
    await queryInput.click();
    await page.waitForTimeout(300);
    expect(await modal.isVisible()).toBe(true);

    await queryInput.pressSequentially('level:ERROR', { delay: 50 });
    expect(await queryInput.inputValue()).toBe('level:ERROR');
    console.log('STEP 3 PASS: Second input also works');

    // Step 4: Click Cancel to close modal
    const cancelBtn = modal.locator('button:has-text("Cancel")');
    await cancelBtn.click();
    await page.waitForTimeout(300);
    expect(await modal.isVisible()).toBe(false);
    console.log('STEP 4 PASS: Modal closed via Cancel button');
  });

  test('Alerts: click input, type with keyboard, verify modal stays open', async ({ page }) => {
    // Click + button in Alerts section (last button or "Create alert" title)
    const createBtn = page.locator('.alerts-panel button[title="Create alert"]');
    await createBtn.click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    // Name input
    const nameInput = modal.locator('input').first();
    await nameInput.click();
    await page.waitForTimeout(300);
    expect(await modal.isVisible()).toBe(true);

    await nameInput.pressSequentially('High Error Rate', { delay: 50 });
    expect(await nameInput.inputValue()).toBe('High Error Rate');
    console.log('PASS: Alert name input works');

    // Query input
    const queryInput = modal.locator('input').nth(1);
    await queryInput.click();
    await page.waitForTimeout(300);
    expect(await modal.isVisible()).toBe(true);

    await queryInput.pressSequentially('level:ERROR', { delay: 50 });
    expect(await queryInput.inputValue()).toBe('level:ERROR');
    console.log('PASS: Alert query input works');

    // Number inputs (threshold, window)
    const thresholdInput = modal.locator('input[type="number"]').first();
    await thresholdInput.click();
    await page.waitForTimeout(300);
    expect(await modal.isVisible()).toBe(true);
    console.log('PASS: Number input clickable, modal stays open');

    // Cancel
    const cancelBtn = modal.locator('button:has-text("Cancel")');
    await cancelBtn.click();
    await page.waitForTimeout(300);
    expect(await modal.isVisible()).toBe(false);
    console.log('PASS: Alert modal closed normally');
  });

  test('DEBUG: element layering check at input coordinates', async ({ page }) => {
    const addBtn = page.locator('.saved-searches .header-actions button').first();
    await addBtn.click();

    const modal = page.locator('[role="dialog"]');
    await expect(modal).toBeVisible({ timeout: 5000 });
    await page.waitForTimeout(500);

    // Check every input's elementFromPoint
    const inputInfo = await page.evaluate(() => {
      const modal = document.querySelector('[role="dialog"]');
      const inputs = modal.querySelectorAll('input');
      const results = [];

      inputs.forEach((input, i) => {
        const rect = input.getBoundingClientRect();
        const centerX = rect.left + rect.width / 2;
        const centerY = rect.top + rect.height / 2;
        const elementAtPoint = document.elementFromPoint(centerX, centerY);

        // Check all ancestors for overflow, transform, etc
        let ancestor = input.parentElement;
        const ancestors = [];
        while (ancestor && ancestor !== document.body) {
          const style = getComputedStyle(ancestor);
          const info = {};
          if (style.overflow !== 'visible') info.overflow = style.overflow;
          if (style.overflowX !== 'visible') info.overflowX = style.overflowX;
          if (style.overflowY !== 'visible') info.overflowY = style.overflowY;
          if (style.transform !== 'none') info.transform = style.transform;
          if (style.position !== 'static') info.position = style.position;
          if (style.zIndex !== 'auto') info.zIndex = style.zIndex;
          if (style.pointerEvents !== 'auto') info.pointerEvents = style.pointerEvents;

          if (Object.keys(info).length > 0) {
            info.tag = `${ancestor.tagName}.${ancestor.className?.split(' ')[0] || ''}`;
            ancestors.push(info);
          }
          ancestor = ancestor.parentElement;
        }

        results.push({
          index: i,
          type: input.type,
          rect: { x: Math.round(centerX), y: Math.round(centerY), w: Math.round(rect.width), h: Math.round(rect.height) },
          elementAtPoint: elementAtPoint ? `${elementAtPoint.tagName}${elementAtPoint.type ? '[' + elementAtPoint.type + ']' : ''}.${elementAtPoint.className?.split(' ')[0] || ''}` : 'null',
          isSameElement: elementAtPoint === input,
          ancestors,
        });
      });

      return results;
    });

    console.log('\n=== INPUT ELEMENT LAYERING DEBUG ===');
    inputInfo.forEach(info => {
      console.log(`Input[${info.index}] type=${info.type}:`);
      console.log(`  Position: (${info.rect.x}, ${info.rect.y}) ${info.rect.w}x${info.rect.h}`);
      console.log(`  elementFromPoint: ${info.elementAtPoint}`);
      console.log(`  isSameElement: ${info.isSameElement}`);
      if (info.ancestors.length > 0) {
        console.log(`  Interesting ancestors:`);
        info.ancestors.forEach(a => console.log(`    ${a.tag}: ${JSON.stringify(a)}`));
      }
    });

    // All inputs should be the top element at their position
    inputInfo.forEach(info => {
      expect(info.isSameElement).toBe(true);
    });
  });
});
