import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENV_FILE = path.resolve(__dirname, '../stack/e2e.env');

/**
 * Parse the same KEY=VALUE file docker compose consumes via --env-file.
 *
 * One file, two readers. The alternative — the credentials written once in the
 * compose env and again in the spec files — is how a suite ends up logging in
 * with a password the server was never given.
 */
function parseEnvFile(file) {
  if (!fs.existsSync(file)) return {};
  const out = {};
  for (const rawLine of fs.readFileSync(file, 'utf8').split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    out[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return out;
}

const fileEnv = parseEnvFile(ENV_FILE);

/**
 * Real process env wins over the file so the same specs can run against the
 * dev cluster (`PLAYWRIGHT_BASE_URL=... PURL_ADMIN_PASSWORD=... npm run test:e2e`)
 * without editing a committed file.
 */
function pick(key, fallback) {
  return process.env[key] || fileEnv[key] || fallback;
}

export const stackEnv = {
  /*
   * Deliberately NOT `pick()`: this is the port of the stack up.sh boots, and
   * up.sh reads it from the file. A developer who happens to have PURL_PORT
   * exported for their own `make up` stack must not be able to redirect the
   * suite onto it — that is what PLAYWRIGHT_BASE_URL is for, and when that is
   * set this value is not consulted at all.
   */
  PURL_PORT: fileEnv.PURL_PORT || '3100',
  ADMIN_USERNAME: pick('PURL_ADMIN_USERNAME', 'admin'),
  ADMIN_PASSWORD: pick('PURL_ADMIN_PASSWORD', ''),
  // PURL_API_KEYS is a comma-separated list; ingest only needs one of them.
  API_KEY: pick('PURL_API_KEYS', '').split(',')[0].trim(),
};
