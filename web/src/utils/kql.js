/**
 * Building search-bar (KQL) clauses from values the user did not type — a
 * facet click, an autocomplete pick, the cluster picker.
 *
 * The server's tokenizer (lib/Purl/Util/KQL.pm) reads a bare value up to the
 * next space or parenthesis, treats an unquoted `*` as a wildcard and bare
 * AND/OR/NOT as operators. A value such as `my ns`, `a(b)` or `web*` therefore
 * has to be sent quoted — `"..."` with `\` escaping `"` and `\` — or the
 * clause means something else, or does not parse at all.
 */

const NEEDS_QUOTES = /[\s()"'*\\]/;
const KEYWORDS = new Set(['AND', 'OR', 'NOT']);

/**
 * @param {string} value
 * @returns {string} the value as a KQL literal: bare when safe, quoted otherwise
 */
export function kqlValue(value) {
  const text = String(value ?? '');
  if (text && !NEEDS_QUOTES.test(text) && !KEYWORDS.has(text.toUpperCase())) return text;
  return `"${text.replace(/[\\"]/g, '\\$&')}"`;
}

/**
 * @param {string} field - e.g. `namespace`, `meta.cluster`
 * @param {string} value - matched literally
 * @returns {string} `field:value`, with the value quoted when needed
 */
export function kqlClause(field, value) {
  return `${field}:${kqlValue(value)}`;
}
