import { writable, get } from 'svelte/store';

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

// API base URL
const API_BASE = '/api';

// CSRF token cache
let csrfToken = null;

// XSS sanitization - escape HTML entities
export function escapeHtml(str) {
  if (!str) return '';
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// Safe HTML with specific allowed tags only
export function sanitizeHtml(html) {
  if (!html) return '';
  // First escape everything
  let safe = escapeHtml(html);
  // Then allow only specific safe patterns back
  safe = safe
    .replace(/&lt;span class=&quot;([a-z-]+)&quot;&gt;/g, '<span class="$1">')
    .replace(/&lt;\/span&gt;/g, '</span>');
  return safe;
}

// Fetch CSRF token
export async function fetchCsrfToken() {
  if (csrfToken) return csrfToken;
  try {
    const response = await fetch(`${API_BASE}/csrf-token`);
    const data = await response.json();
    csrfToken = data.csrf_token;
    // Refresh token every 30 minutes
    setTimeout(() => { csrfToken = null; }, 30 * 60 * 1000);
    return csrfToken;
  } catch {
    return null;
  }
}

// Get headers with CSRF token for POST/PUT/DELETE
export async function getSecureHeaders() {
  const token = await fetchCsrfToken();
  return {
    'Content-Type': 'application/json',
    ...(token ? { 'X-CSRF-Token': token } : {})
  };
}

// Debounce utility
let debounceTimer = null;
export function debounce(fn, delay = 300) {
  return (...args) => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => fn(...args), delay);
  };
}

// Throttle utility - limit calls to once per interval
let throttleTimers = {};
export function throttle(fn, limit = 1000, key = 'default') {
  return (...args) => {
    if (!throttleTimers[key]) {
      fn(...args);
      throttleTimers[key] = setTimeout(() => {
        throttleTimers[key] = null;
      }, limit);
    }
  };
}

// Simple memoization cache
const memoCache = new Map();
const MEMO_MAX_SIZE = 100;
const MEMO_TTL = 60000; // 1 minute

export function memoize(fn, keyFn = (...args) => JSON.stringify(args)) {
  return (...args) => {
    const key = keyFn(...args);
    const cached = memoCache.get(key);

    if (cached && Date.now() - cached.time < MEMO_TTL) {
      return cached.value;
    }

    const value = fn(...args);

    // Evict oldest entries if cache is full
    if (memoCache.size >= MEMO_MAX_SIZE) {
      const oldest = memoCache.keys().next().value;
      memoCache.delete(oldest);
    }

    memoCache.set(key, { value, time: Date.now() });
    return value;
  };
}

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
    const currentQuery = get(query);
    const currentRange = get(timeRange);
    const currentCustom = get(customTimeRange);

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
    const currentRange = get(timeRange);
    const currentCustom = get(customTimeRange);

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

// WebSocket connection for live tail
export function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const ws = new WebSocket(`${protocol}//${window.location.host}/api/logs/stream`);

  ws.onopen = () => {
    console.log('WebSocket connected');
  };

  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      if (data.type === 'log') {
        const logWithId = {
          ...data.data,
          id: data.data.id || `${data.data.timestamp}-${Date.now()}`
        };
        logs.update(current => [logWithId, ...current.slice(0, 499)]);
      }
    } catch (err) {
      console.error('WebSocket message error:', err);
    }
  };

  ws.onerror = (err) => {
    console.error('WebSocket error:', err);
  };

  ws.onclose = () => {
    console.log('WebSocket disconnected');
  };

  return ws;
}

// Format timestamp for display
export function formatTimestamp(ts) {
  if (!ts) return '';
  const date = new Date(ts);
  return date.toLocaleTimeString('en-US', {
    hour12: false,
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
}

// Format full timestamp
export function formatFullTimestamp(ts) {
  if (!ts) return '';
  const date = new Date(ts);
  return date.toLocaleString('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  });
}

// Get level color class
export function getLevelColor(level) {
  const colors = {
    EMERGENCY: '#f85149',
    ALERT: '#f85149',
    CRITICAL: '#f85149',
    ERROR: '#f85149',
    WARNING: '#d29922',
    NOTICE: '#58a6ff',
    INFO: '#3fb950',
    DEBUG: '#8b949e',
    TRACE: '#6e7681',
  };
  return colors[level] || '#8b949e';
}

// Fetch log context (surrounding logs)
export async function fetchLogContext(logId, before = 50, after = 50) {
  try {
    const params = new URLSearchParams({
      before: before.toString(),
      after: after.toString(),
    });
    const response = await fetch(`${API_BASE}/logs/${logId}/context?${params}`);

    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch context');
    }

    return await response.json();
  } catch (err) {
    console.error('Failed to fetch log context:', err);
    return null;
  }
}

// ============================================
// Trace Correlation
// ============================================

// Trace data store
export const traceData = writable(null);
export const traceLoading = writable(false);
export const traceError = writable(null);

// Fetch logs by trace ID
export async function fetchTrace(traceId) {
  if (!traceId) return null;

  traceLoading.set(true);
  traceError.set(null);

  try {
    const response = await fetch(`${API_BASE}/traces/${traceId}`);

    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch trace');
    }

    const data = await response.json();
    traceData.set(data);
    return data;
  } catch (err) {
    traceError.set(err.message);
    console.error('Failed to fetch trace:', err);
    return null;
  } finally {
    traceLoading.set(false);
  }
}

// Fetch trace timeline (service spans)
export async function fetchTraceTimeline(traceId) {
  if (!traceId) return null;

  try {
    const response = await fetch(`${API_BASE}/traces/${traceId}/timeline`);

    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch timeline');
    }

    return await response.json();
  } catch (err) {
    console.error('Failed to fetch trace timeline:', err);
    return null;
  }
}

// Fetch logs by request ID
export async function fetchRequest(requestId) {
  if (!requestId) return null;

  try {
    const response = await fetch(`${API_BASE}/requests/${requestId}`);

    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch request');
    }

    return await response.json();
  } catch (err) {
    console.error('Failed to fetch request:', err);
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
