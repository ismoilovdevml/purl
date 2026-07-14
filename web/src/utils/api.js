/**
 * Purl - API Client
 *
 * Single entry point for every HTTP call to the Purl backend.
 * Replaces the ad-hoc `fetch()` + `res.ok` + `.json()` + `catch/toast`
 * boilerplate that was duplicated across every store.
 *
 * Responsibilities (and nothing else):
 *   - build the URL (base + path + query params)
 *   - JSON encode the request body, JSON decode the response
 *   - turn a non-2xx response into a thrown `ApiError`
 *   - attach the CSRF header to mutating requests
 *   - handle session expiry (401) in ONE place
 *
 * Deliberately NOT handled here: user-facing toasts. Call sites own their
 * own wording ("Failed to load patterns", ...), so they keep the catch+toast.
 * The single exception is the session-expiry toast, which must not be
 * duplicated by every store racing on the same 401.
 */

import { get } from 'svelte/store';
import { currentUser } from '../stores/auth.js';
import { error as toastError } from '../stores/toast.js';

const API_BASE = '/api';

const MUTATING_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

/**
 * Normalized error for every failed API call.
 *
 * `status` is 0 for network-level failures (server unreachable, DNS, CORS),
 * which lets call sites distinguish "server said no" from "never reached the
 * server" without string matching.
 *
 * AbortError is NEVER wrapped in an ApiError - it is rethrown as-is, because
 * existing call sites branch on `err.name !== 'AbortError'` to ignore
 * cancelled in-flight requests.
 */
export class ApiError extends Error {
  constructor(message, { status = 0, body = null, cause = null } = {}) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.body = body;
    this.cause = cause;
  }

  /** True when the server was never reached. */
  get isNetworkError() {
    return this.status === 0;
  }

  /** Session expired / not authenticated. */
  get isUnauthorized() {
    return this.status === 401;
  }

  /** Authenticated but not allowed (permission, license, pending password change). */
  get isForbidden() {
    return this.status === 403;
  }

  /**
   * Either flavour of auth failure. Call sites that used to silently `return`
   * on 401/403 can now do `if (err.isAuthError) return;`.
   */
  get isAuthError() {
    return this.status === 401 || this.status === 403;
  }
}

/* ------------------------------------------------------------------ *
 * CSRF
 *
 * Backend contract (already live, lib/Purl/API/Middleware/Auth.pm):
 *   GET /api/csrf-token -> { "csrf_token": "<session>:<hour>:<hmac>" }
 *   Mutating requests must send it back as the `X-CSRF-Token` header.
 *   Tokens are session-bound and valid for ~2 hours.
 *
 * The token is fetched lazily on the first mutating request and cached.
 * Failure to obtain one is non-fatal: we send the request without the header
 * and let the backend decide. That keeps login working (no session yet =>
 * no token to mint) and keeps us compatible with CSRF being disabled
 * (PURL_CSRF_ENABLED=0).
 * ------------------------------------------------------------------ */

let csrfToken = null;
let csrfInflight = null;

/** Raw fetch on purpose: must not recurse through request()'s 401 handling. */
async function fetchCsrfToken() {
  if (!csrfInflight) {
    csrfInflight = (async () => {
      try {
        const res = await fetch(`${API_BASE}/csrf-token`, { credentials: 'same-origin' });
        if (!res.ok) return null;
        const data = await res.json();
        return data?.csrf_token ?? null;
      } catch {
        return null; // offline / not logged in yet - proceed header-less
      } finally {
        csrfInflight = null;
      }
    })();
  }
  return csrfInflight;
}

async function ensureCsrfToken(forceRefresh = false) {
  if (csrfToken && !forceRefresh) return csrfToken;
  csrfToken = await fetchCsrfToken();
  return csrfToken;
}

/** Drop the cached token (called on logout - it is bound to the old session). */
export function resetCsrfToken() {
  csrfToken = null;
}

/** A 403 that is about CSRF specifically, not about permissions. */
function isCsrfRejection(status, body) {
  if (status !== 403) return false;
  const msg = `${body?.error ?? ''} ${body?.message ?? ''}`;
  return /csrf/i.test(msg);
}

/* ------------------------------------------------------------------ *
 * Session expiry - the whole point of centralizing this
 * ------------------------------------------------------------------ */

function handleSessionExpiry() {
  // Guarded by the store's own value: when 9 parallel stats requests all get
  // a 401, only the first one finds a non-null user, so the user sees exactly
  // one toast instead of nine.
  if (get(currentUser) !== null) {
    currentUser.set(null);
    toastError('Your session has expired. Please sign in again.');
  }
}

/* ------------------------------------------------------------------ *
 * Core request
 * ------------------------------------------------------------------ */

function buildUrl(path, query) {
  const url = path.startsWith('/api') || path.startsWith('http')
    ? path
    : `${API_BASE}${path.startsWith('/') ? '' : '/'}${path}`;

  if (!query) return url;

  const params = query instanceof URLSearchParams
    ? query
    : new URLSearchParams(
      // Drop null/undefined so callers can pass optional filters inline.
      Object.entries(query)
        .filter(([, v]) => v !== null && v !== undefined && v !== '')
        .map(([k, v]) => [k, String(v)])
    );

  const qs = params.toString();
  return qs ? `${url}?${qs}` : url;
}

/** Parse the body defensively: empty, JSON, or plain text all have to work. */
async function parseBody(res) {
  if (res.status === 204 || res.status === 205) return null;

  const text = await res.text();
  if (!text) return null;

  const type = res.headers.get('content-type') || '';
  if (type.includes('application/json')) {
    try {
      return JSON.parse(text);
    } catch {
      // Server claimed JSON and lied (e.g. an HTML error page from a proxy).
      return text;
    }
  }
  return text;
}

function errorMessageFrom(body, status) {
  if (body && typeof body === 'object') {
    if (body.error) return body.error;
    if (body.message) return body.message;
  }
  if (typeof body === 'string' && body.trim() && body.length < 200) {
    return body.trim();
  }
  return `Request failed (HTTP ${status})`;
}

/**
 * @param {string} path            e.g. '/logs' ('/api' prefix added automatically)
 * @param {object} [options]
 * @param {string} [options.method='GET']
 * @param {any}    [options.body]           JSON-encoded unless it is FormData
 * @param {object|URLSearchParams} [options.query]
 * @param {AbortSignal} [options.signal]
 * @param {object} [options.headers]
 * @returns {Promise<any>} the parsed response body
 * @throws {ApiError} on any non-2xx or network failure
 * @throws {DOMException} AbortError, rethrown untouched
 */
async function request(path, options = {}, _isCsrfRetry = false) {
  const { method = 'GET', body, query, signal, headers = {} } = options;
  const upperMethod = method.toUpperCase();

  const requestHeaders = { ...headers };
  let payload;

  if (body !== undefined && body !== null) {
    if (body instanceof FormData) {
      payload = body; // let the browser set the multipart boundary
    } else {
      payload = JSON.stringify(body);
      requestHeaders['Content-Type'] = 'application/json';
    }
  }

  if (MUTATING_METHODS.has(upperMethod)) {
    const token = await ensureCsrfToken(_isCsrfRetry);
    if (token) requestHeaders['X-CSRF-Token'] = token;
  }

  let res;
  try {
    res = await fetch(buildUrl(path, query), {
      method: upperMethod,
      credentials: 'same-origin',
      headers: requestHeaders,
      body: payload,
      signal,
    });
  } catch (err) {
    // Cancellation is not an error condition - preserve it verbatim so that
    // `err.name !== 'AbortError'` checks in the stores keep working.
    if (err?.name === 'AbortError') throw err;
    throw new ApiError('Network error - could not reach the server', { cause: err });
  }

  const parsed = await parseBody(res);

  if (res.ok) return parsed;

  // A stale/missing CSRF token is recoverable: mint a fresh one, retry once.
  if (isCsrfRejection(res.status, parsed) && !_isCsrfRetry) {
    return request(path, options, true);
  }

  if (res.status === 401) {
    handleSessionExpiry();
  }

  throw new ApiError(errorMessageFrom(parsed, res.status), {
    status: res.status,
    body: parsed,
  });
}

/* ------------------------------------------------------------------ *
 * Public surface
 * ------------------------------------------------------------------ */

export const api = {
  request,
  get: (path, options = {}) => request(path, { ...options, method: 'GET' }),
  post: (path, body, options = {}) => request(path, { ...options, method: 'POST', body }),
  put: (path, body, options = {}) => request(path, { ...options, method: 'PUT', body }),
  patch: (path, body, options = {}) => request(path, { ...options, method: 'PATCH', body }),
  del: (path, options = {}) => request(path, { ...options, method: 'DELETE' }),
};

export default api;
