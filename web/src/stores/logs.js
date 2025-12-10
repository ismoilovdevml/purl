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

// Request deduplication
let currentRequest = null;

// Search logs with request deduplication
export async function searchLogs() {
  // Cancel previous request
  if (currentRequest) {
    currentRequest.cancelled = true;
  }

  const thisRequest = { cancelled: false };
  currentRequest = thisRequest;

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

    const response = await fetch(`${API_BASE}/logs?${params}`);

    // Check if request was cancelled
    if (thisRequest.cancelled) return;

    const data = await response.json();

    logs.set(data.hits || []);
    total.set(data.total || 0);

    // Fetch stats in parallel (non-blocking)
    Promise.all([
      fetchFieldStats('level'),
      fetchFieldStats('service'),
      fetchFieldStats('host'),
      fetchHistogram(),
      fetchMetrics(),
    ]).catch(console.error);

  } catch (err) {
    if (!thisRequest.cancelled) {
      error.set(err.message);
      console.error('Search error:', err);
    }
  } finally {
    if (!thisRequest.cancelled) {
      loading.set(false);
    }
  }
}

// Debounced search for typing
export const debouncedSearch = debounce(searchLogs, 300);

// Fetch field statistics
export async function fetchFieldStats(field) {
  try {
    let currentRange;
    timeRange.subscribe(v => currentRange = v)();

    const params = new URLSearchParams({
      range: currentRange,
      limit: 10,
    });

    const response = await fetch(`${API_BASE}/stats/fields/${field}?${params}`);
    const data = await response.json();

    if (field === 'level') levelStats.set(data.values || []);
    if (field === 'service') serviceStats.set(data.values || []);
    if (field === 'host') hostStats.set(data.values || []);
  } catch (err) {
    console.error(`Failed to fetch ${field} stats:`, err);
  }
}

// Fetch histogram
export async function fetchHistogram() {
  try {
    let currentRange;
    timeRange.subscribe(v => currentRange = v)();

    // Choose interval based on range
    let interval = '1 minute';
    if (currentRange === '24h' || currentRange === '7d') interval = '1 hour';
    if (currentRange === '30d') interval = '1 day';

    const params = new URLSearchParams({
      range: currentRange,
      interval,
    });

    const response = await fetch(`${API_BASE}/stats/histogram?${params}`);
    const data = await response.json();

    histogram.set(data.buckets || []);
  } catch (err) {
    console.error('Failed to fetch histogram:', err);
  }
}

// Fetch metrics for dashboard
export async function fetchMetrics() {
  try {
    const response = await fetch(`${API_BASE}/metrics/json`);
    const data = await response.json();
    metrics.set(data);
  } catch (err) {
    console.error('Failed to fetch metrics:', err);
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
        logs.update(current => [data.data, ...current.slice(0, 499)]);
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
