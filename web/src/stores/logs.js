import { writable } from 'svelte/store';

// Re-export utilities from centralized modules for backwards compatibility
export {
  escapeHtml,
  sanitizeHtml,
  formatTimestamp,
  formatFullTimestamp,
  getLevelColor,
  debounce,
  throttle,
  memoize,
  highlightPattern,
} from '../lib/utils.js';

export {
  API_BASE,
  fetchCsrfToken,
  getSecureHeaders,
  fetchLogContext,
  fetchTrace,
  fetchTraceTimeline,
  fetchRequest,
  connectWebSocket,
} from '../lib/api.js';

// State stores
export const logs = writable([]);
export const loading = writable(false);
export const error = writable(null);
export const query = writable('');
export const timeRange = writable('15m');
export const customTimeRange = writable({ from: null, to: null });
export const total = writable(0);

// Field statistics
export const levelStats = writable([]);
export const serviceStats = writable([]);
export const hostStats = writable([]);

// K8s field statistics
export const namespaceStats = writable([]);
export const podStats = writable([]);
export const nodeStats = writable([]);

// Histogram data
export const histogram = writable([]);

// Performance metrics
export const metrics = writable(null);
export const isLive = writable(false);

// Import API_BASE for local use
import { API_BASE } from '../lib/api.js';
import { debounce } from '../lib/utils.js';

// AbortController for request cancellation
let searchController = null;
let statsController = null;

// Search logs with proper request cancellation
export async function searchLogs() {
  // Abort previous request properly
  if (searchController) {
    searchController.abort();
  }

  searchController = new AbortController();
  const signal = searchController.signal;

  loading.set(true);
  error.set(null);

  try {
    let currentQuery;
    let currentRange;
    let currentCustom;

    query.subscribe(v => currentQuery = v)();
    timeRange.subscribe(v => currentRange = v)();
    customTimeRange.subscribe(v => currentCustom = v)();

    const params = new URLSearchParams({ limit: 500 });

    // Use custom range if set, otherwise use preset range
    if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
      params.set('from', currentCustom.from);
      params.set('to', currentCustom.to);
    } else {
      params.set('range', currentRange);
    }

    if (currentQuery) {
      params.set('q', currentQuery);
    }

    const response = await fetch(`${API_BASE}/logs?${params}`, { signal });
    const data = await response.json();

    // Add unique IDs to logs for selection tracking
    const logsWithIds = (data.hits || []).map((log, index) => ({
      ...log,
      id: log.id || `${log.timestamp}-${index}`
    }));
    logs.set(logsWithIds);
    total.set(data.total || 0);

    // Fetch stats in parallel (non-blocking) with separate controller
    fetchAllStats();

  } catch (err) {
    // Ignore abort errors - they are expected when cancelling
    if (err.name !== 'AbortError') {
      error.set(err.message);
      console.error('Search error:', err);
    }
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

  try {
    await Promise.all([
      fetchFieldStats('level', signal),
      fetchFieldStats('service', signal),
      fetchFieldStats('host', signal),
      fetchFieldStats('meta.namespace', signal),
      fetchFieldStats('meta.pod', signal),
      fetchFieldStats('meta.node', signal),
      fetchHistogram(signal),
      fetchMetrics(signal),
    ]);
  } catch (err) {
    if (err.name !== 'AbortError') {
      console.error('Stats fetch error:', err);
    }
  }
}

// Debounced search for typing
export const debouncedSearch = debounce(searchLogs, 300);

// Fetch field statistics with abort signal
export async function fetchFieldStats(field, signal = null) {
  try {
    let currentRange;
    let currentCustom;
    timeRange.subscribe(v => currentRange = v)();
    customTimeRange.subscribe(v => currentCustom = v)();

    const params = new URLSearchParams({ limit: 10 });

    if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
      params.set('from', currentCustom.from);
      params.set('to', currentCustom.to);
    } else {
      params.set('range', currentRange);
    }

    const response = await fetch(`${API_BASE}/stats/fields/${field}?${params}`, { signal });
    const data = await response.json();

    // Standard fields
    if (field === 'level') levelStats.set(data.values || []);
    if (field === 'service') serviceStats.set(data.values || []);
    if (field === 'host') hostStats.set(data.values || []);

    // K8s meta fields
    if (field === 'meta.namespace') namespaceStats.set(data.values || []);
    if (field === 'meta.pod') podStats.set(data.values || []);
    if (field === 'meta.node') nodeStats.set(data.values || []);
  } catch (err) {
    if (err.name !== 'AbortError') {
      console.error(`Failed to fetch ${field} stats:`, err);
    }
  }
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
  if (range === '1h' || range === '3h' || range === '4h' || range === '6h') return '1 minute';
  if (range === '12h' || range === '24h') return '1 hour';
  if (range === '7d') return '1 hour';
  if (range === '30d') return '1 day';
  return '1 hour';
}

// Fetch histogram with abort signal
export async function fetchHistogram(signal = null) {
  try {
    let currentRange;
    let currentCustom;
    timeRange.subscribe(v => currentRange = v)();
    customTimeRange.subscribe(v => currentCustom = v)();

    const interval = getIntervalForRange(currentRange, currentCustom.from, currentCustom.to);
    const params = new URLSearchParams({ interval });

    if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
      params.set('from', currentCustom.from);
      params.set('to', currentCustom.to);
    } else {
      params.set('range', currentRange);
    }

    const response = await fetch(`${API_BASE}/stats/histogram?${params}`, { signal });
    const data = await response.json();

    histogram.set(data.buckets || []);
  } catch (err) {
    if (err.name !== 'AbortError') {
      console.error('Failed to fetch histogram:', err);
    }
  }
}

// Fetch metrics for dashboard with abort signal
export async function fetchMetrics(signal = null) {
  try {
    const response = await fetch(`${API_BASE}/metrics/json`, { signal });
    const data = await response.json();
    metrics.set(data);
  } catch (err) {
    if (err.name !== 'AbortError') {
      console.error('Failed to fetch metrics:', err);
    }
  }
}

// Note: connectWebSocket is now in lib/api.js and re-exported above

// Note: formatTimestamp, formatFullTimestamp, getLevelColor, fetchLogContext
// are now imported from lib/utils.js and lib/api.js

// ============================================
// Trace Correlation
// ============================================

// Trace data store
export const traceData = writable(null);
export const traceLoading = writable(false);
export const traceError = writable(null);

// Note: fetchTrace, fetchTraceTimeline, fetchRequest are now in lib/api.js

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
    let currentRange;
    let currentCustom;
    timeRange.subscribe(v => currentRange = v)();
    customTimeRange.subscribe(v => currentCustom = v)();

    const params = new URLSearchParams({ limit: '30' });

    if (currentRange === 'custom' && currentCustom.from && currentCustom.to) {
      params.set('from', currentCustom.from);
      params.set('to', currentCustom.to);
    } else {
      params.set('range', currentRange);
    }

    const response = await fetch(`${API_BASE}/patterns?${params}`, { signal });

    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch patterns');
    }

    const data = await response.json();
    patterns.set(data.patterns || []);
  } catch (err) {
    if (err.name !== 'AbortError') {
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
    let currentRange;
    timeRange.subscribe(v => currentRange = v)();

    const params = new URLSearchParams({
      range: currentRange,
      limit: '100',
    });

    const response = await fetch(`${API_BASE}/patterns/${patternHash}/logs?${params}`);

    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch pattern logs');
    }

    return await response.json();
  } catch (err) {
    console.error('Failed to fetch pattern logs:', err);
    return null;
  }
}

// Note: highlightPattern is now in lib/utils.js
