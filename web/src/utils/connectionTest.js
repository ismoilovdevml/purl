/**
 * "Test configuration" requests of the auth-provider settings pages (SSO, LDAP).
 *
 * Both endpoints answer `{ success, message?, error? }`; the pages show the
 * outcome as a banner, so the answer and any transport failure are folded into
 * one `{ ok, message }` shape here.
 */

import { api } from './api.js';

/**
 * POST a draft configuration to a `.../test` endpoint.
 *
 * @param {string} path - API path, e.g. '/settings/ldap/test'
 * @param {object} payload - The unsaved form values
 * @param {object} messages
 * @param {(data: object) => string} messages.ok - Text when the server sent no message on success
 * @param {string} messages.fail - Text when the server sent neither error nor message on failure
 * @returns {Promise<{ ok: boolean, message: string }>}
 */
export async function runConnectionTest(path, payload, { ok, fail }) {
  try {
    const data = await api.post(path, payload);
    if (data.success) {
      return { ok: true, message: data.message || ok(data) };
    }
    return { ok: false, message: data.error || data.message || fail };
  } catch (err) {
    return { ok: false, message: err.message || 'Request failed' };
  }
}
