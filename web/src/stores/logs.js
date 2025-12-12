import { writable } from 'svelte/store';

// State stores
export const logs = writable([]);
export const loading = writable(false);
export const error = writable(null);
export const query = writable('');
export const timeRange = writable('15m');
export const total = writable(0);

// Field statistics
export const levelStats = writable([]);
export const serviceStats = writable([]);
export const hostStats = writable([]);

// Histogram data
export const histogram = writable([]);

// Performance metrics
export const metrics = writable(null);

// API base URL
const API_BASE = '/api';

// Debounce utility
let debounceTimer = null;
export function debounce(fn, delay = 300) {
  return (...args) => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => fn(...args), delay);
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
    let currentQuery;
    let currentRange;

    query.subscribe(v => currentQuery = v)();
    timeRange.subscribe(v => currentRange = v)();

    const params = new URLSearchParams({
      range: currentRange,
      limit: 500,
    });

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
    timeRange.subscribe(v => currentRange = v)();

    const params = new URLSearchParams({
      range: currentRange,
      limit: 10,
    });

    const response = await fetch(`${API_BASE}/stats/fields/${field}?${params}`, { signal });
    const data = await response.json();

    if (field === 'level') levelStats.set(data.values || []);
    if (field === 'service') serviceStats.set(data.values || []);
    if (field === 'host') hostStats.set(data.values || []);
  } catch (err) {
    if (err.name !== 'AbortError') {
      console.error(`Failed to fetch ${field} stats:`, err);
    }
  }
}

// Fetch histogram with abort signal
export async function fetchHistogram(signal = null) {
  try {
    let currentRange;
    timeRange.subscribe(v => currentRange = v)();

    // Choose interval based on range
    let interval = '1 minute';
    if (currentRange === '1h' || currentRange === '3h' || currentRange === '6h') interval = '1 minute';
    if (currentRange === '12h' || currentRange === '24h') interval = '1 hour';
    if (currentRange === '7d') interval = '1 hour';
    if (currentRange === '30d') interval = '1 day';

    const params = new URLSearchParams({
      range: currentRange,
      interval,
    });

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
    timeRange.subscribe(v => currentRange = v)();

    const params = new URLSearchParams({
      range: currentRange,
      limit: '30',
    });

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

// Highlight placeholders in pattern text
export function highlightPattern(pattern) {
  if (!pattern) return '';
  return pattern
    .replace(/<UUID>/g, '<span class="placeholder uuid">&lt;UUID&gt;</span>')
    .replace(/<IP>/g, '<span class="placeholder ip">&lt;IP&gt;</span>')
    .replace(/<NUM>/g, '<span class="placeholder num">&lt;NUM&gt;</span>')
    .replace(/<DATETIME>/g, '<span class="placeholder datetime">&lt;DATETIME&gt;</span>')
    .replace(/<HEX>/g, '<span class="placeholder hex">&lt;HEX&gt;</span>');
}
