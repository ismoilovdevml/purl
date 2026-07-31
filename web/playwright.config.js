import { defineConfig } from '@playwright/test';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { stackEnv } from './e2e/fixtures/env.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Where the suite points.
 *
 * Default: an ephemeral docker compose stack this config boots itself. The old
 * config hardcoded the legacy demo server (37.27.187.72:3000), which has been
 * dead for weeks — the entire suite was unrunnable and nobody noticed, because
 * nothing in .github ever executed it.
 *
 * Set PLAYWRIGHT_BASE_URL to aim at an already-running instance (dev k8s, a
 * `make up` stack, a review env). Doing so also disables the webServer block:
 * you asked for that target, so we do not start or stop containers.
 */
const externalTarget = process.env.PLAYWRIGHT_BASE_URL;
const baseURL = externalTarget || `http://localhost:${stackEnv.PURL_PORT}`;
const managesStack = !externalTarget;

export default defineConfig({
  testDir: './e2e',
  // A cold `docker build` of the Perl image can take minutes; the per-test
  // budget still has to cover ClickHouse write→read visibility on ingest.
  timeout: 90_000,
  expect: { timeout: 15_000 },

  // Never let a stray .only silently shrink the CI gate.
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,

  /*
   * Serial on purpose. The specs mutate shared server state — alerts, saved
   * searches, users, retention settings — against a single backend. Parallel
   * workers would make "created item appears in the list" flaky in a way that
   * looks like a product bug.
   */
  workers: 1,
  fullyParallel: false,

  reporter: process.env.CI
    ? [['line'], ['html', { outputFolder: 'playwright-report', open: 'never' }]]
    : [['list']],

  use: {
    baseURL,
    headless: true,
    screenshot: 'only-on-failure',
    video: process.env.CI ? 'retain-on-failure' : 'off',
    trace: 'retain-on-failure',
    actionTimeout: 20_000,
    navigationTimeout: 30_000,
  },

  /*
   * `channel: 'chromium'` is load-bearing, not decoration.
   *
   * Since Playwright 1.49 a headless `browserName: 'chromium'` run defaults to
   * the separate `chrome-headless-shell` binary, which is a second download on
   * top of the browser itself. Pinning the channel selects Chromium's built-in
   * headless mode, so `npx playwright install chromium` is all any machine —
   * or CI job — needs.
   */
  /*
   * PLAYWRIGHT_CHANNEL=chrome runs against a locally installed Google Chrome
   * instead of Playwright's bundled build — useful on a machine where the
   * 160MB browser download is blocked or unreliable. CI leaves it unset.
   */
  projects: [
    {
      name: 'chromium',
      use: {
        browserName: 'chromium',
        channel: process.env.PLAYWRIGHT_CHANNEL || 'chromium',
        viewport: { width: 1280, height: 800 },
      },
    },
  ],

  globalTeardown: managesStack ? './e2e/stack/global-teardown.js' : undefined,

  webServer: managesStack
    ? {
        command: `bash ${path.join(__dirname, 'e2e/stack/up.sh')}`,
        url: `${baseURL}/api/health`,
        // First run has to build the image from source. 15 minutes is the
        // difference between "slow cold start" and a red CI job.
        timeout: 900_000,
        reuseExistingServer: !process.env.CI,
        stdout: 'pipe',
        stderr: 'pipe',
      }
    : undefined,
});
