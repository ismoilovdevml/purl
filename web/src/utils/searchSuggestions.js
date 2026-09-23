/**
 * KQL autocomplete for the search bar: which suggestions to offer for the
 * token under the cursor, and how to splice a picked suggestion back into the
 * query. Pure functions — the caller supplies the known field values.
 */

import { kqlClause } from './kql.js';

// KQL operators and fields
const OPERATORS = ['AND', 'OR', 'NOT'];
// namespace/pod/container are real columns (#104), not meta.* keys.
const FIELDS = ['level', 'service', 'host', 'namespace', 'pod', 'container', 'message', 'timestamp'];
const META_FIELDS = [
  { field: 'meta.node', label: 'Node', group: 'Metadata' },
  { field: 'meta.cluster', label: 'Cluster', group: 'Metadata' },
  { field: 'meta.deployment', label: 'Deployment', group: 'Metadata' },
  { field: 'meta.team', label: 'Team', group: 'Metadata' },
  { field: 'meta.environment', label: 'Environment', group: 'Metadata' },
  { field: 'meta.region', label: 'Region', group: 'Metadata' },
  { field: 'meta.version', label: 'Version', group: 'Metadata' },
  { field: 'meta.app', label: 'App', group: 'Metadata' },
];

/**
 * Suggestions for the token being typed at the end of `textBeforeCursor`.
 * @param {string} textBeforeCursor - query text up to the caret
 * @param {Record<string, string[]>} fieldValues - known values keyed by
 *   lower-case field name (level/service/host/namespace/pod/container)
 * @returns {Array<{ type: 'field'|'value'|'operator', text: string, display: string, hint?: string, field?: string, group?: string }>}
 *   empty when there is no current token
 */
export function buildSuggestions(textBeforeCursor, fieldValues) {
  // Get the current token being typed
  const tokens = textBeforeCursor.split(/\s+/);
  const currentToken = tokens[tokens.length - 1] || '';

  if (!currentToken) return [];

  // Check if typing field:value
  if (currentToken.includes(':')) {
    const [field, partial] = currentToken.split(':');
    const fieldLower = field.toLowerCase();
    // Own keys only: "constructor:" must not resolve to Object.prototype
    const values = Object.hasOwn(fieldValues, fieldLower) ? fieldValues[fieldLower] : [];

    // Filter by partial match
    const partialLower = (partial || '').toLowerCase();
    return values
      .filter(v => v.toLowerCase().includes(partialLower))
      .slice(0, 8)
      .map(v => ({
        type: 'value',
        text: kqlClause(field, v),
        display: v,
        field: field
      }));
  }

  // Suggest fields or operators
  const tokenLower = currentToken.toLowerCase();

  // Core field suggestions
  const fieldSuggestions = FIELDS
    .filter(f => f.toLowerCase().startsWith(tokenLower))
    .map(f => ({
      type: 'field',
      text: `${f}:`,
      display: f,
      hint: 'field'
    }));

  // Metadata field suggestions
  const metaSuggestions = META_FIELDS
    .filter(m => m.field.toLowerCase().startsWith(tokenLower) || m.label.toLowerCase().startsWith(tokenLower))
    .map(m => ({
      type: 'field',
      text: `${m.field}:`,
      display: m.field,
      hint: 'metadata',
      group: m.group
    }));

  // Operator suggestions (only after space)
  const opSuggestions = tokens.length > 1 ? OPERATORS
    .filter(op => op.toLowerCase().startsWith(tokenLower))
    .map(op => ({
      type: 'operator',
      text: op,
      display: op,
      hint: 'operator'
    })) : [];

  return [...fieldSuggestions, ...metaSuggestions, ...opSuggestions].slice(0, 12);
}

/**
 * Replace the token ending at `cursorPos` with the suggestion's text. Fields
 * keep the caret right after `field:`; values and operators get a trailing
 * space.
 * @param {string} query
 * @param {number} cursorPos
 * @param {{ type: string, text: string }} suggestion
 * @returns {string} the new query
 */
export function applySuggestionToQuery(query, cursorPos, suggestion) {
  const textBeforeCursor = query.substring(0, cursorPos);
  const textAfterCursor = query.substring(cursorPos);

  // Find the start of current token
  const lastSpace = textBeforeCursor.lastIndexOf(' ');
  const beforeToken = textBeforeCursor.substring(0, lastSpace + 1);

  return beforeToken + suggestion.text + (suggestion.type === 'field' ? '' : ' ') + textAfterCursor.trimStart();
}
