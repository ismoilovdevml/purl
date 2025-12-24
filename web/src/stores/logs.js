import { writable, get } from 'svelte/store';
import { escapeHtml } from '../utils/dom.js';

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
export const previousHistogram = writable([]);

// Live mode state
export const isLive = writable(false);

// API base URL
const API_BASE = '/api';

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
    ]);
  } catch (err) {
    if (err.name !== 'AbortError') {
      console.error('Stats fetch error:', err);
    }
  }
}

// Fetch field statistics with abort signal
async function fetchFieldStats(field, signal = null) {
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
async function fetchHistogram(signal = null) {
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

    const response = await fetch(`${API_BASE}/stats/histogram?${params}`, { signal });
    const data = await response.json();

    previousHistogram.set(data.buckets || []);
  } catch (err) {
    if (err.name !== 'AbortError') {
      console.error('Failed to fetch previous histogram:', err);
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
