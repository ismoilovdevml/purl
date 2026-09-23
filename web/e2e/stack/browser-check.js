import fs from 'node:fs';
import path from 'node:path';
import { chromium } from '@playwright/test';

/**
 * Fail loudly when Playwright's browser download is incomplete.
 *
 * The failure this guards against (issue #69) is silent and very expensive to
 * debug: `npx playwright install chromium` can exit 0 while leaving a
 * *truncated* browser behind. On this project's macOS machine it produced a
 * 428K `chromium-<rev>` directory — the `.app` bundle was there, the
 * executable was there, but `Contents/Frameworks/` (the ~330MB of actual
 * browser) was missing. Playwright's own launch path only checks that the
 * executable file exists, so it happily exec'd it and the process died on
 * SIGABRT before speaking the CDP protocol. Every spec then failed with
 * "Target page, context or browser has been closed", which points at the
 * tests and not at the real cause.
 *
 * Re-running `npx playwright install --force chromium` did NOT fix it: it
 * removed and re-downloaded the directory and arrived at the same 428K tree,
 * still exiting 0. The repair was to fetch the CDN zip by hand and unpack it
 * with `ditto`, which handles `.app` bundles correctly.
 *
 * What makes the truncated install detectable is Playwright's own completion
 * marker: it writes `INSTALLATION_COMPLETE` into the browser root only after
 * a successful unpack. A partially-written browser has the executable but not
 * the marker, which is exactly the state we hit — so that is what we check.
 *
 * This runs synchronously while playwright.config.js is being evaluated, i.e.
 * before the `webServer` hook starts building a Docker image. Discovering a
 * broken browser must not cost a 15-minute image build first.
 */

/**
 * Channels that resolve to a browser installed by the OS rather than by
 * Playwright. For those there is nothing in the Playwright cache to verify,
 * and Playwright's own "Chromium distribution 'chrome' is not found" message
 * is already actionable.
 */
const SYSTEM_CHANNELS = new Set([
  'chrome',
  'chrome-beta',
  'chrome-dev',
  'chrome-canary',
  'msedge',
  'msedge-beta',
  'msedge-dev',
  'msedge-canary',
]);

const INSTALL_HINT = [
  'Reinstall it with:',
  '',
  '    cd web && npx playwright install --force chromium',
  '',
  'If that command exits 0 and the browser is STILL reported as incomplete,',
  'the unpack step is failing silently (see issue #69). Install it by hand:',
  '',
  '    URL=$(cd web && npx playwright install --dry-run chromium |',
  '          awk \'/Download url/ {print $3; exit}\')',
  '    curl -L -o /tmp/cft.zip "$URL"',
  '    ditto -x -k /tmp/cft.zip /tmp/cft-out          # macOS: handles .app bundles',
  '    # then replace the directory named below with /tmp/cft-out/* and',
  '    # `touch INSTALLATION_COMPLETE` in its root.',
].join('\n');

/**
 * Locate the browser root (`.../chromium-1208`) that owns an executable, by
 * walking up until Playwright's completion marker would live.
 *
 * The layout differs per platform — macOS buries the binary six levels deep
 * inside `Google Chrome for Testing.app/Contents/MacOS/`, Linux keeps it two
 * levels down — so the root is found by structure, not by a hardcoded depth.
 */
function findBrowserRoot(executablePath) {
  let dir = path.dirname(executablePath);
  for (let i = 0; i < 10; i++) {
    if (fs.existsSync(path.join(dir, 'INSTALLATION_COMPLETE'))) {
      return { root: dir, complete: true };
    }
    // The cache root holds every browser; stop before escaping into it.
    if (fs.existsSync(path.join(dir, '.links'))) break;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return { root: null, complete: false };
}

/** Rough size of a directory tree, for a human-readable "this is too small". */
function treeSizeBytes(dir, budget = 20000) {
  let total = 0;
  let seen = 0;
  const walk = (d) => {
    if (seen > budget) return;
    let entries;
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (seen > budget) return;
      seen++;
      const full = path.join(d, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) walk(full);
      else {
        try { total += fs.statSync(full).size; } catch { /* ignore */ }
      }
    }
  };
  walk(dir);
  return total;
}

/**
 * Throw a diagnosable error if the browser this run will use is missing or
 * was only partially unpacked. Returns the executable path when it is sound.
 */
export function assertBrowserUsable(channel) {
  if (channel && SYSTEM_CHANNELS.has(channel)) return null;

  let executablePath;
  try {
    executablePath = chromium.executablePath();
  } catch (cause) {
    throw new Error(
      `Playwright cannot resolve a Chromium executable.\n\n${INSTALL_HINT}\n\nUnderlying error: ${cause.message}`,
      { cause }
    );
  }

  if (!fs.existsSync(executablePath)) {
    throw new Error(
      'Playwright\'s Chromium is not installed.\n\n' +
      `Expected executable: ${executablePath}\n\n${INSTALL_HINT}`
    );
  }

  const { root, complete } = findBrowserRoot(executablePath);
  if (!complete) {
    const dir = root || path.dirname(executablePath);
    const mb = (treeSizeBytes(dir) / 1024 / 1024).toFixed(1);
    throw new Error(
      'Playwright\'s Chromium is installed but INCOMPLETE — refusing to run.\n\n' +
      `Browser directory: ${dir}\n` +
      `Approximate size:  ${mb} MB (a healthy Chromium is ~300 MB)\n` +
      'Missing marker:    INSTALLATION_COMPLETE\n\n' +
      'Launching this build aborts with SIGABRT before it speaks CDP, which\n' +
      'surfaces as "Target page, context or browser has been closed" on every\n' +
      'single spec. That is a broken download, not a broken test suite.\n\n' +
      INSTALL_HINT
    );
  }

  return executablePath;
}
