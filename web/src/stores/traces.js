import { writable } from 'svelte/store';

const API_BASE = '/api';

// ============================================
// Trace Stores
// ============================================

export const traceData = writable(null);
export const traceLoading = writable(false);
export const traceError = writable(null);
export const traceTimeline = writable(null);

// ============================================
// Trace API Functions
// ============================================

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

    const data = await response.json();
    traceTimeline.set(data);
    return data;
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

// ============================================
// Trace Utilities
// ============================================

// Service colors for visualization
const serviceColors = {};
const colorPalette = [
  '#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6',
  '#ec4899', '#06b6d4', '#84cc16', '#f97316', '#6366f1'
];
let colorIndex = 0;

export function getServiceColor(service) {
  if (!serviceColors[service]) {
    serviceColors[service] = colorPalette[colorIndex % colorPalette.length];
    colorIndex++;
  }
  return serviceColors[service];
}

export function resetServiceColors() {
  Object.keys(serviceColors).forEach(key => delete serviceColors[key]);
  colorIndex = 0;
}

// Format duration
export function formatDuration(ms) {
  if (ms == null || ms === undefined) return 'N/A';
  if (ms < 1) return '<1ms';
  if (ms < 1000) return `${Math.round(ms)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`;
  return `${(ms / 60000).toFixed(2)}m`;
}

// Format timestamp
export function formatTimestamp(ts) {
  if (!ts) return '';
  const date = new Date(ts);
  return date.toLocaleTimeString('en-US', {
    hour12: false,
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    fractionalSecondDigits: 3
  });
}

// Process timeline data for visualization
export function processTimelineData(data) {
  if (!data || !data.services || data.services.length === 0) {
    return { spans: [], minTime: 0, maxTime: 0, totalDuration: 0 };
  }

  const spans = data.services;

  // Find min and max times
  let minTime = Infinity;
  let maxTime = -Infinity;

  spans.forEach(span => {
    const start = new Date(span.start_time).getTime();
    const end = span.end_time ? new Date(span.end_time).getTime() : start + (span.duration_ms || 0);
    if (start < minTime) minTime = start;
    if (end > maxTime) maxTime = end;
  });

  const totalDuration = maxTime - minTime;

  // Sort by start time
  const sortedSpans = spans.sort((a, b) => {
    const aTime = new Date(a.start_time).getTime();
    const bTime = new Date(b.start_time).getTime();
    return aTime - bTime;
  });

  return {
    spans: sortedSpans,
    minTime,
    maxTime,
    totalDuration
  };
}

// Calculate bar position and width for waterfall visualization
export function getBarPosition(span, minTime, totalDuration) {
  if (!span.start_time || totalDuration === 0) {
    return { left: 0, width: 100 };
  }

  const startMs = new Date(span.start_time).getTime();
  const endMs = span.end_time ? new Date(span.end_time).getTime() : startMs + (span.duration_ms || 0);

  const left = ((startMs - minTime) / totalDuration) * 100;
  const width = Math.max(((endMs - startMs) / totalDuration) * 100, 0.5);

  return {
    left: Math.max(0, left),
    width: Math.min(width, 100 - left)
  };
}

// Check if span is an error
export function isErrorSpan(span) {
  return span.level === 'ERROR' || span.level === 'FATAL';
}

// Get span statistics
export function getTraceStats(spans) {
  if (!spans || spans.length === 0) {
    return {
      totalSpans: 0,
      uniqueServices: 0,
      errorCount: 0,
      totalDuration: 0
    };
  }

  const services = new Set(spans.map(s => s.service));
  const errorCount = spans.filter(isErrorSpan).length;

  return {
    totalSpans: spans.length,
    uniqueServices: services.size,
    errorCount,
    services: Array.from(services)
  };
}

// Build trace tree from spans (parent-child relationships)
export function buildTraceTree(spans) {
  if (!spans || spans.length === 0) return [];

  // Create a map of span_id to span
  const spanMap = new Map();
  spans.forEach(span => {
    if (span.span_id) {
      spanMap.set(span.span_id, { ...span, children: [] });
    }
  });

  const roots = [];

  // Build tree structure
  spanMap.forEach(span => {
    if (span.parent_span_id && spanMap.has(span.parent_span_id)) {
      const parent = spanMap.get(span.parent_span_id);
      parent.children.push(span);
    } else {
      roots.push(span);
    }
  });

  return roots;
}

// Flatten tree to array with depth info
export function flattenTraceTree(roots, depth = 0) {
  const result = [];

  roots.forEach(node => {
    result.push({ ...node, depth });
    if (node.children && node.children.length > 0) {
      result.push(...flattenTraceTree(node.children, depth + 1));
    }
  });

  return result;
}
