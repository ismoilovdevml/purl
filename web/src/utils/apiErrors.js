/**
 * Purl - what a failed API call may say to the user (#107).
 *
 * The server used to put raw ClickHouse exceptions (on-disk part paths, table
 * UUIDs), Perl die messages ("... at /app/lib/Purl/... line 45.") and
 * double-encoded text straight into `{error}`, and every screen rendered it.
 * The contract now is `{error, code, request_id}`, where `code` is stable and
 * `error` is meant to be short and user-facing. This module turns any error
 * body — new format, old `{error}`-only format, or a proxy's HTML page — into
 * one message that is safe to put on screen.
 *
 * Rules:
 *   - A known outage/overload/timeout/internal `code` → our own wording. The
 *     server's text is never shown for these, however clean it looks.
 *   - A code whose message helps the user act (invalid_query: fix the query)
 *     → the server's text, sanitized.
 *   - No code (older server, hand-written short messages such as "Failed to
 *     save settings") → the server's text only if it passes `isSafeMessage`;
 *     otherwise a generic line chosen by HTTP status.
 *
 * Pure functions, no imports: api.js calls this while building an ApiError.
 */

/** Our own wording per error code. */
export const CODE_MESSAGES = {
  storage_unavailable: 'Search is temporarily unavailable. Try again in a moment.',
  storage_overloaded: 'The log store is overloaded right now. Try again in a moment, or narrow the time range.',
  query_timeout: 'The query took too long. Narrow the time range or add filters, then try again.',
  internal: 'Something went wrong on the server. Try again in a moment.',
};

/**
 * Codes whose server message is shown (still sanitized): it tells the user
 * what to change. The value is the fallback when the text itself is unusable.
 */
const USER_FACING_CODES = {
  invalid_query: 'The query could not be understood. Check its syntax and try again.',
  bad_request: 'The request was not valid.',
  unauthorized: 'Please sign in again.',
  forbidden: 'You do not have permission to do that.',
  not_found: 'Not found.',
  conflict: 'That conflicts with the current state. Reload and try again.',
  payload_too_large: 'That is too large to send.',
  rate_limited: 'Too many requests. Wait a moment and try again.',
};

/** Longest wait we honour from `retry_after` / `Retry-After`, in seconds. */
const MAX_RETRY_AFTER = 300;

/**
 * @param {unknown} value - `retry_after` from the body or the Retry-After header
 * @returns {number|null} whole seconds, or null when absent/unusable
 */
export function parseRetryAfter(value) {
  const n = typeof value === 'number' ? value : Number.parseInt(String(value ?? ''), 10);
  if (!Number.isFinite(n) || n <= 0) return null;
  return Math.min(Math.ceil(n), MAX_RETRY_AFTER);
}

/** Longest server message we are willing to put on screen. */
const MAX_LENGTH = 200;

/*
 * Signatures of text that must never reach the screen: server file paths and
 * Perl "at FILE line N", ClickHouse exceptions, SQL, UUIDs, and UTF-8 that was
 * encoded twice (mojibake such as "\u00e2\u20ac" for an em dash).
 */
const UNSAFE_PATTERNS = [
  /(?:^|[\s"'(])\/(?:app|usr|var|opt|home|etc|tmp|srv|root)\//i,
  /\w\.(?:pm|pl)\b/,
  /\bline \d+\b/i,
  /DB::Exception|\bCode: \d+|\bClickHouse\b.*\bexception\b/i,
  /\b(?:SELECT|INSERT|ALTER)\b[\s\S]*\bFROM\b|\bFROM\s+\w+\.\w+/,
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i,
  /\u00e2\u20ac|\u00c3[\u0080-\u00bf]|\u00c2[\u0080-\u00bf]|\ufffd/,
];

/**
 * Clean a server-provided message for display, or return '' if it cannot be
 * made safe. Strips a trailing Perl "at FILE line N." and control characters.
 * @param {unknown} text
 * @returns {string}
 */
export function sanitizeServerMessage(text) {
  if (typeof text !== 'string') return '';
  const cleaned = text
    .replace(/\s+at\s+\S+\s+line\s+\d+\.?\s*$/, '')
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '')
    .trim();
  return isSafeMessage(cleaned) ? cleaned : '';
}

/**
 * @param {string} text - already trimmed
 * @returns {boolean} true when the text can be shown verbatim
 */
export function isSafeMessage(text) {
  if (!text || text.length > MAX_LENGTH) return false;
  if (/<[a-z!/]/i.test(text)) return false; // an HTML error page
  return !UNSAFE_PATTERNS.some((re) => re.test(text));
}

/** Generic wording when the server gave no usable text. */
function messageForStatus(status) {
  if (status === 503) return CODE_MESSAGES.storage_unavailable;
  if (status === 504) return CODE_MESSAGES.query_timeout;
  if (status >= 500) return CODE_MESSAGES.internal;
  return null;
}

/**
 * Describe a failed response for the user.
 * @param {number} status - HTTP status
 * @param {unknown} body - parsed response body (object, string or null)
 * @returns {{ message: string|null, code: string|null, requestId: string|null, retryAfter: number|null }}
 *   `message` is null when there is nothing better than "Request failed (HTTP n)";
 *   callers then use their own wording.
 */
export function describeApiError(status, body) {
  const obj = body && typeof body === 'object' ? body : null;
  const code = typeof obj?.code === 'string' ? obj.code : null;
  const requestId = typeof obj?.request_id === 'string' && /^[\w.:-]{1,80}$/.test(obj.request_id)
    ? obj.request_id
    : null;
  const serverText = obj ? (obj.error ?? obj.message) : body;

  let message;
  if (code && Object.hasOwn(CODE_MESSAGES, code)) {
    message = CODE_MESSAGES[code];
  } else if (code && Object.hasOwn(USER_FACING_CODES, code)) {
    message = sanitizeServerMessage(serverText) || USER_FACING_CODES[code];
  } else {
    message = sanitizeServerMessage(serverText) || messageForStatus(status);
  }

  return { message: message || null, code, requestId, retryAfter: parseRetryAfter(obj?.retry_after) };
}
