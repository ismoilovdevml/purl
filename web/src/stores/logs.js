import { writable, get } from 'svelte/store';
import { escapeHtml } from '../utils/dom.js';
import { api } from '../utils/api.js';
import { uniqueId } from '../utils/id.js';
import { settings, clampMaxResults } from './settings.js';
import { passwordChangeRequired, endRevokedSession, WS_SESSION_REVOKED } from './auth.js';
import { error as toastError } from './toast.js';
import { kqlClause } from '../utils/kql.js';
import { selectedCluster } from './cluster.js';

// State stores
export const logs = writable([]);
export const loading = writable(false);
export const error = writable(null);
// What the failure state needs besides the message (#107): the support
// reference (the server log has the detail under it) and, for an outage, how
// long the server asked us to wait before retrying.
export const errorDetail = writable({ requestId: null, retryAfter: null });
export const query = writable('');
export const timeRange = writable('15m');
export const customTimeRange = writable({ from: null, to: null });
export const total = writable(0);

// Field statistics
export const levelStats = writable([]);
export const serviceStats = writable([]);
export const hostStats = writable([]);

// K8s field statistics. namespace/pod/container are first-class columns the
// chart's Vector DaemonSet fills (#104); node/deployment/team still live in
// the `meta` JSON.
export const namespaceStats = writable([]);
export const podStats = writable([]);
export const containerStats = writable([]);
export const nodeStats = writable([]);
export const deploymentStats = writable([]);
export const teamStats = writable([]);

// `/api/stats/fields/<field>` name → the store its values land in. One entry
// per facet the fields sidebar can show; fetchAllStats() asks for every one.
const FIELD_STATS_STORES = {
  level: levelStats,
  service: serviceStats,
  host: hostStats,
  namespace: namespaceStats,
  pod: podStats,
  container: containerStats,
  'meta.node': nodeStats,
  'meta.deployment': deploymentStats,
  'meta.team': teamStats,
};

// Histogram data
export const histogram = writable([]);
export const previousHistogram = writable([]);

// Live mode state
export const isLive = writable(false);

// AbortController for request cancellation
let searchController = null;
let statsController = null;

/**
 * The query the server should run: the search bar's text plus the cluster
 * picker's filter. Shared by the search and the field facets, so a facet's
 * counts always describe the result set on screen (#104).
 * @returns {string} empty when there is nothing to filter on
 */
function effectiveQuery() {
  const currentQuery = get(query);
  const cluster = get(selectedCluster);
  if (!cluster || cluster === 'all') return currentQuery;
  const clusterFilter = kqlClause('meta.cluster', cluster);
  return currentQuery ? `${currentQuery} ${clusterFilter}` : clusterFilter;
}

// Search logs with proper request cancellation
export async function searchLogs() {
  // Skip if password change is required (all API calls would return 403)
  if (get(passwordChangeRequired)) return;

  // Abort previous request properly
  if (searchController) {
    searchController.abort();
  }

  searchController = new AbortController();
  const signal = searchController.signal;

  loading.set(true);
  error.set(null);
  errorDetail.set({ requestId: null, retryAfter: null });

  try {
    const currentRange = get(timeRange);
    const currentCustom = get(customTimeRange);

    const currentSettings = settings.get();
    // Clamped again at the request boundary: `limit` lands in the backend's
    // `LIMIT n` unchecked, so it must be in range no matter how it got here.
    const params = new URLSearchParams({ limit: clampMaxResults(currentSettings.maxResults) });

    // Use custom range if set, otherwise use preset range
    if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
      params.set('from', currentCustom.from);
      params.set('to', currentCustom.to);
    } else {
      params.set('range', currentRange);
    }

    const finalQuery = effectiveQuery();
    if (finalQuery) {
      params.set('q', finalQuery);
    }

    const data = await api.get('/logs', { query: params, signal });

    // Add unique IDs to logs and pre-parse meta for performance
    const logsWithIds = (data.hits || []).map((log, index) => {
      let parsedMeta = null;
      if (log.meta) {
        try {
          parsedMeta = typeof log.meta === 'string' ? JSON.parse(log.meta) : log.meta;
        } catch {
          parsedMeta = {};
        }
      }
      return {
        ...log,
        id: log.id || `${log.timestamp}-${index}`,
        parsedMeta
      };
    });
    logs.set(logsWithIds);
    total.set(data.total || 0);

    // Fetch stats in parallel (non-blocking) with separate controller
    fetchAllStats();
    // Recovering from an outage: the patterns panel failed with it and has
    // no reason of its own to refetch, so bring it back with the search.
    if (get(patternsError)) fetchPatterns();

  } catch (err) {
    // Ignore abort errors - they are expected when cancelling
    if (err.name === 'AbortError') return;
    // 401 -> session cleared centrally by the api client (with one toast).
    // 403 -> permission / pending password change; stay quiet, as before.
    if (err.isAuthError) return;

    // The previous result set does NOT describe this query. Leaving it on
    // screen (a rejected KQL query 400s) makes the table read as the answer to
    // the broken query in the search box — with the banner gone 10s later,
    // there is nothing left saying otherwise. Clear it and let `error` drive an
    // explicit failure state instead.
    logs.set([]);
    total.set(0);

    // err.message is already user-safe (utils/apiErrors.js). No toast: the
    // table's failure state (with Retry) and the banner say it (#107).
    error.set(err.message);
    errorDetail.set({ requestId: err.requestId ?? null, retryAfter: err.retryAfter ?? null });
    console.error('Search error:', err);
  } finally {
    loading.set(false);
  }
}

// Fetch all stats with cancellation support
async function fetchAllStats() {
  // Abort previous stats requests
  if (statsController) {
    statsController.abort();
  }
  statsController = new AbortController();
  const signal = statsController.signal;

  // Each fetcher throws instead of toasting, so one outage failing all ten
  // requests reports once (#107), not once per facet.
  const results = await Promise.allSettled([
    ...Object.keys(FIELD_STATS_STORES).map((field) => fetchFieldStats(field, signal)),
    fetchHistogram(signal),
  ]);
  const failure = results.find(
    (r) => r.status === 'rejected' && r.reason?.name !== 'AbortError' && !r.reason?.isAuthError
  );
  if (failure) {
    console.error('Stats fetch error:', failure.reason);
    toastError(failure.reason?.isServerError ? failure.reason.message : 'Failed to load statistics');
  }
}

// Fetch field statistics with abort signal. Throws; fetchAllStats reports.
async function fetchFieldStats(field, signal = null) {
  const currentRange = get(timeRange);
  const currentCustom = get(customTimeRange);

  const params = new URLSearchParams({ limit: 10 });

  if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
    params.set('from', currentCustom.from);
    params.set('to', currentCustom.to);
  } else {
    params.set('range', currentRange);
  }

  // Narrow the facet to the current search (#104); the endpoint takes `q`
  // for every field.
  const finalQuery = effectiveQuery();
  if (finalQuery) params.set('q', finalQuery);

  const data = await api.get(`/stats/fields/${encodeURIComponent(field)}`, {
    query: params,
    signal,
  });

  FIELD_STATS_STORES[field].set(data.values || []);
}

// Calculate interval based on time range duration
function getIntervalForRange(range, customFrom, customTo) {
  if (range === 'custom' && customFrom && customTo) {
    const diffMs = new Date(customTo) - new Date(customFrom);
    const diffHours = diffMs / (1000 * 60 * 60);
    if (diffHours <= 1) return '1 minute';
    if (diffHours <= 6) return '1 minute';
    if (diffHours <= 48) return '1 hour';
    return '1 day';
  }

  if (range === '5m' || range === '15m' || range === '30m') return '1 minute';
  if (range === '1h' || range === '4h') return '1 minute';
  if (range === '12h' || range === '24h') return '1 hour';
  if (range === '7d') return '1 hour';
  if (range === '30d') return '1 day';
  return '1 hour';
}

// Fetch histogram with abort signal. Throws; fetchAllStats reports.
async function fetchHistogram(signal = null) {
  const currentRange = get(timeRange);
  const currentCustom = get(customTimeRange);

  const interval = getIntervalForRange(currentRange, currentCustom.from, currentCustom.to);
  const params = new URLSearchParams({ interval });

  if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
    params.set('from', currentCustom.from);
    params.set('to', currentCustom.to);
  } else {
    params.set('range', currentRange);
  }

  const data = await api.get('/stats/histogram', { query: params, signal });

  histogram.set(data.buckets || []);
}

// Fetch previous period histogram for comparison
export async function fetchPreviousHistogram(signal = null) {
  try {
    const currentRange = get(timeRange);
    const currentCustom = get(customTimeRange);

    const interval = getIntervalForRange(currentRange, currentCustom.from, currentCustom.to);
    const params = new URLSearchParams({ interval });

    // Calculate previous period based on current range
    const now = new Date();
    let prevFrom, prevTo;

    if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
      // Custom range: shift back by the same duration
      const from = new Date(currentCustom.from);
      const to = new Date(currentCustom.to);
      const duration = to.getTime() - from.getTime();
      prevFrom = new Date(from.getTime() - duration);
      prevTo = new Date(to.getTime() - duration);
    } else {
      // Preset range: calculate previous period
      // e.g., 15m means "last 15 minutes", previous is "30 min ago to 15 min ago"
      const rangeMs = {
        '5m': 5 * 60 * 1000,
        '15m': 15 * 60 * 1000,
        '30m': 30 * 60 * 1000,
        '1h': 60 * 60 * 1000,
        '4h': 4 * 60 * 60 * 1000,
        '12h': 12 * 60 * 60 * 1000,
        '24h': 24 * 60 * 60 * 1000,
        '7d': 7 * 24 * 60 * 60 * 1000,
        '30d': 30 * 24 * 60 * 60 * 1000
      };
      const duration = rangeMs[currentRange] || 60 * 60 * 1000;
      // Previous period: from (now - 2*duration) to (now - duration)
      prevTo = new Date(now.getTime() - duration);
      prevFrom = new Date(now.getTime() - 2 * duration);
    }

    params.set('from', prevFrom.toISOString());
    params.set('to', prevTo.toISOString());

    const data = await api.get('/stats/histogram', { query: params, signal });

    previousHistogram.set(data.buckets || []);
  } catch (err) {
    if (err.name !== 'AbortError' && !err.isAuthError) {
      console.error('Failed to fetch previous histogram:', err);
      toastError('Failed to load comparison histogram');
    }
  }
}

// ============================================
// Live tail WebSocket
// ============================================

/**
 * Connection status for the live-tail socket.
 * 'disconnected' | 'connecting' | 'connected' | 'reconnecting'
 */
export const liveStatus = writable('disconnected');

// --- Reconnect tuning -------------------------------------------------------
// Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s, 30s, ... (capped).
// Rationale: the first retry is fast enough that a brief network blip or a
// container restart is invisible to the user, while the 30s cap means a
// genuinely dead server is polled twice a minute instead of being hammered.
const RECONNECT_BASE_DELAY_MS = 1000;
const RECONNECT_MAX_DELAY_MS = 30000;
const RECONNECT_FACTOR = 2;

// Bounded so a permanently dead backend does not retry forever in a
// background tab. ~12 attempts spans roughly 5 minutes, which comfortably
// covers a deploy/restart; past that we surface it and let the user re-arm.
const RECONNECT_MAX_ATTEMPTS = 12;

// A socket that stayed up this long counts as "healthy", so its close resets
// the backoff. Without this, a server that accepts and immediately drops
// connections (crash loop) would be retried every 1s forever.
const STABLE_CONNECTION_MS = 10000;

// Heartbeat. See the note on `pongSupported` below - the liveness timeout is
// only enforced once we have proof the server answers pings.
const HEARTBEAT_INTERVAL_MS = 25000;
const HEARTBEAT_TIMEOUT_MS = 60000;

const MAX_LIVE_LOGS = 500;

/**
 * Equal jitter: half the delay is fixed, half is random.
 * Prevents every open dashboard from reconnecting in lockstep and
 * re-DDoSing the server the instant it comes back up.
 */
function backoffDelay(attempt) {
  const capped = Math.min(
    RECONNECT_MAX_DELAY_MS,
    RECONNECT_BASE_DELAY_MS * Math.pow(RECONNECT_FACTOR, attempt)
  );
  return capped / 2 + Math.random() * (capped / 2);
}

/**
 * Open the live-tail stream, keeping it open across network blips and server
 * restarts.
 *
 * Returns a handle with `.close()`. Calling `.close()` is an explicit,
 * user-initiated disconnect: it tears down timers and listeners and
 * guarantees no further reconnect attempts.
 *
 * The returned object intentionally keeps a `.close()` method so existing
 * call sites (SearchBar.svelte) work unchanged.
 */
export function connectWebSocket() {
  let ws = null;
  let attempt = 0;
  let openedAt = 0;

  let reconnectTimer = null;
  let heartbeatTimer = null;

  let lastMessageAt = 0;
  // The server does not answer app-level pings yet. Until we actually observe
  // a pong we must NOT enforce the liveness timeout, otherwise an idle-but-
  // healthy stream (no logs arriving) would look "dead" and be killed every
  // 60s in a pointless reconnect loop. Once the backend replies
  // {"type":"pong"}, this flips to true and dead-socket detection turns on.
  let pongSupported = false;

  // Set by close(). The single source of truth for "never reconnect again".
  let closedByUser = false;

  const clearTimers = () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
  };

  /** Detach handlers before dropping a socket so a dying socket's late
   *  onclose can never schedule a reconnect for a connection we replaced. */
  const detach = (socket) => {
    if (!socket) return;
    socket.onopen = null;
    socket.onmessage = null;
    socket.onerror = null;
    socket.onclose = null;
  };

  const startHeartbeat = () => {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = setInterval(() => {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;

      // Dead-but-open socket: the TCP connection was silently dropped
      // (laptop slept, NAT timeout, LB reaped it) so no close event ever
      // fires. Force one. Only trusted when we know pongs come back.
      if (pongSupported && Date.now() - lastMessageAt > HEARTBEAT_TIMEOUT_MS) {
        console.warn('Live tail: no response from server, recycling socket');
        ws.close(4000, 'heartbeat timeout'); // -> onclose -> reconnect
        return;
      }

      try {
        ws.send(JSON.stringify({ type: 'ping' }));
      } catch (err) {
        console.error('Live tail: ping failed', err);
      }
    }, HEARTBEAT_INTERVAL_MS);
  };

  const scheduleReconnect = () => {
    if (closedByUser) return;
    if (reconnectTimer) return; // never stack timers

    if (attempt >= RECONNECT_MAX_ATTEMPTS) {
      console.error('Live tail: giving up after', attempt, 'attempts');
      liveStatus.set('disconnected');
      isLive.set(false); // UI must not keep claiming we are live
      toastError('Live tail disconnected. Click Live to reconnect.');
      return;
    }

    const delay = backoffDelay(attempt);
    attempt += 1;
    liveStatus.set('reconnecting');
    console.log(`Live tail: reconnecting in ${Math.round(delay)}ms (attempt ${attempt})`);

    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      open();
    }, delay);
  };

  const open = () => {
    if (closedByUser) return;

    liveStatus.set(attempt === 0 ? 'connecting' : 'reconnecting');

    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    let socket;
    try {
      socket = new WebSocket(`${protocol}//${window.location.host}/api/logs/stream`);
    } catch (err) {
      // Constructor can throw synchronously (bad URL, blocked by CSP).
      console.error('Live tail: failed to open socket', err);
      scheduleReconnect();
      return;
    }
    ws = socket;

    socket.onopen = () => {
      openedAt = Date.now();
      lastMessageAt = Date.now();
      liveStatus.set('connected');
      console.log('Live tail: connected');
      startHeartbeat();
    };

    socket.onmessage = (event) => {
      lastMessageAt = Date.now();
      try {
        const data = JSON.parse(event.data);

        if (data.type === 'pong') {
          pongSupported = true; // server speaks heartbeat - enable liveness check
          return;
        }

        if (data.type === 'log') {
          const logWithId = {
            ...data.data,
            // Always a client id, never the frame's own `id`: ClickHouse has
            // not assigned one yet, and an `id` here is just a field the
            // sender put in its log, which two lines can share. Rows are keyed
            // on id, so a duplicate breaks the table's reconcile (#117) --
            // as did the old timestamp+Date.now() in a same-timestamp burst.
            id: uniqueId('live')
          };
          logs.update(current => [logWithId, ...current.slice(0, MAX_LIVE_LOGS - 1)]);
        }
      } catch (err) {
        // A single malformed frame must not tear down the stream.
        console.error('Live tail: bad message', err);
      }
    };

    socket.onerror = (err) => {
      // Do NOT toast here: an error is always followed by a close, and the
      // close handler owns the recovery. Toasting on every blip during a
      // 12-attempt backoff would spam the user.
      console.error('Live tail: socket error', err);
    };

    socket.onclose = (event) => {
      detach(socket);
      if (heartbeatTimer) {
        clearInterval(heartbeatTimer);
        heartbeatTimer = null;
      }

      if (closedByUser) {
        liveStatus.set('disconnected');
        return;
      }

      // 4401 = the server revoked this session (logout elsewhere, password
      // reset, max age). Reconnecting would only be refused again, so stop
      // for good and send the user to the sign-in form.
      if (event.code === WS_SESSION_REVOKED) {
        console.log('Live tail: session revoked by the server');
        stop();
        isLive.set(false);
        endRevokedSession();
        return;
      }

      // A connection that survived a while was healthy - a fresh problem
      // deserves a fresh (fast) backoff rather than inheriting old attempts.
      if (openedAt && Date.now() - openedAt >= STABLE_CONNECTION_MS) {
        attempt = 0;
      }

      console.log(`Live tail: disconnected (code ${event.code})`);
      scheduleReconnect();
    };
  };

  // Coming back from offline: retry immediately instead of waiting out a
  // backoff that may still have 30s left on it.
  const onOnline = () => {
    if (closedByUser) return;
    if (ws && ws.readyState === WebSocket.OPEN) return;
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    attempt = 0;
    open();
  };
  window.addEventListener('online', onOnline);

  open();

  /** Permanent teardown: tears down timers and listeners, never reconnects. */
  function stop() {
    closedByUser = true;
    clearTimers();
    window.removeEventListener('online', onOnline);
    detach(ws);
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
      ws.close(1000, 'client disconnect');
    }
    ws = null;
    liveStatus.set('disconnected');
  }

  return {
    /** Explicit user-initiated disconnect. Never reconnects. */
    close: stop,

    get readyState() {
      return ws ? ws.readyState : WebSocket.CLOSED;
    },
  };
}

// Fetch log context (surrounding logs)
export async function fetchLogContext(logId, before = 50, after = 50) {
  try {
    return await api.get(`/logs/${encodeURIComponent(logId)}/context`, {
      query: { before, after },
    });
  } catch (err) {
    if (err.isAuthError) return null;
    console.error('Failed to fetch log context:', err);
    toastError('Failed to load log context: ' + (err.message || 'Unknown error'));
    return null;
  }
}

// Filter logs by trace ID (sets query and searches)
export function filterByTrace(traceId) {
  if (!traceId) return;
  query.set(`trace_id:${traceId}`);
  searchLogs();
}

// Filter logs by request ID
export function filterByRequest(requestId) {
  if (!requestId) return;
  query.set(`request_id:${requestId}`);
  searchLogs();
}

// ============================================
// Log Patterns
// ============================================

// Patterns store
export const patterns = writable([]);
export const patternsLoading = writable(false);
export const patternsError = writable(null);

// AbortController for patterns
let patternsController = null;

// Fetch patterns with abort support
export async function fetchPatterns() {
  // Abort previous request
  if (patternsController) {
    patternsController.abort();
  }
  patternsController = new AbortController();
  const signal = patternsController.signal;

  patternsLoading.set(true);
  patternsError.set(null);

  try {
    const currentRange = get(timeRange);
    const currentCustom = get(customTimeRange);

    const params = new URLSearchParams({ limit: '30' });

    if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
      params.set('from', currentCustom.from);
      params.set('to', currentCustom.to);
    } else {
      params.set('range', currentRange);
    }

    const data = await api.get('/patterns', { query: params, signal });
    patterns.set(data.patterns || []);
  } catch (err) {
    if (err.name !== 'AbortError' && !err.isAuthError) {
      // The panel shows this inline with Retry; no toast on top (#107).
      patternsError.set(err.message);
      console.error('Failed to fetch patterns:', err);
    }
  } finally {
    patternsLoading.set(false);
  }
}

// Fetch logs for a specific pattern
export async function fetchPatternLogs(patternHash) {
  if (!patternHash) return null;

  try {
    return await api.get(`/patterns/${encodeURIComponent(patternHash)}/logs`, {
      query: { range: get(timeRange), limit: 100 },
    });
  } catch (err) {
    if (err.isAuthError) return null;
    console.error('Failed to fetch pattern logs:', err);
    toastError('Failed to load pattern logs: ' + (err.message || 'Unknown error'));
    return null;
  }
}

// Highlight placeholders in pattern text (XSS-safe)
export function highlightPattern(pattern) {
  if (!pattern) return '';
  // First escape HTML to prevent XSS
  let safe = escapeHtml(pattern);
  // Then restore our safe placeholder spans
  return safe
    .replace(/&lt;UUID&gt;/g, '<span class="placeholder uuid">&lt;UUID&gt;</span>')
    .replace(/&lt;IP&gt;/g, '<span class="placeholder ip">&lt;IP&gt;</span>')
    .replace(/&lt;NUM&gt;/g, '<span class="placeholder num">&lt;NUM&gt;</span>')
    .replace(/&lt;DATETIME&gt;/g, '<span class="placeholder datetime">&lt;DATETIME&gt;</span>')
    .replace(/&lt;HEX&gt;/g, '<span class="placeholder hex">&lt;HEX&gt;</span>');
}
