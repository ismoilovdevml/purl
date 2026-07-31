import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Playwright kills the webServer process, which stops the log tail but leaves
 * the containers and their volumes running. Without this the next run would
 * inherit the previous run's ClickHouse data and a partly-consumed trial
 * license — i.e. results that depend on run order.
 */
export default function globalTeardown() {
  try {
    execFileSync('bash', [path.join(__dirname, 'down.sh')], { stdio: 'inherit' });
  } catch (err) {
    // A failed teardown must not turn a green run red; report it loudly instead.
    console.error('[e2e] stack teardown failed:', err.message);
  }
}
