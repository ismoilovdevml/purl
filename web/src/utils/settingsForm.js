/**
 * Purl - settings form loading
 * Turns a settings GET's `config` into form state shaped like the page's
 * DEFAULTS, so what the page later PUTs has the types the API expects.
 */

const TRUE_TEXT = new Set(['1', 'true', 'yes', 'on']);

/**
 * Read a config flag as a real boolean. The server stores flags as 0/1 (Perl)
 * or true/false (JSON) depending on who wrote them last; ENV values arrive as
 * text.
 * @param {unknown} value - Stored flag
 * @returns {boolean}
 */
export function toBoolean(value) {
  if (typeof value === 'boolean') return value;
  if (typeof value === 'number') return value !== 0;
  return TRUE_TEXT.has(String(value).trim().toLowerCase());
}

/**
 * Build form state from `defaults` and a stored config: every key of
 * `defaults`, taking the stored value when there is one, coerced to the type
 * of the default (boolean default -> boolean, string default -> string).
 * Keys not in `defaults` are ignored.
 * @template {Record<string, any>} T
 * @param {T} defaults - Form defaults, which also fix each field's type
 * @param {Record<string, any> | null | undefined} config - Stored config
 * @returns {T} New form state
 */
export function formFromConfig(defaults, config) {
  const cfg = config ?? {};
  const form = /** @type {Record<string, any>} */ ({});
  for (const [key, fallback] of Object.entries(defaults)) {
    const value = cfg[key];
    if (value === null || value === undefined) {
      form[key] = fallback;
    } else if (typeof fallback === 'boolean') {
      form[key] = toBoolean(value);
    } else if (typeof fallback === 'string') {
      form[key] = String(value);
    } else {
      form[key] = value;
    }
  }
  return /** @type {T} */ (form);
}
