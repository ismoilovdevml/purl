/**
 * Purl - Formatting Utilities
 * Common formatting functions used across components
 */

/**
 * Format timestamp for display in log table based on format setting
 * @param {string} ts - ISO timestamp
 * @param {string} format - Format type: 'relative', 'absolute', 'iso'
 * @returns {string} Formatted time
 */
export function formatTimestamp(ts, format = 'absolute') {
  if (!ts) return '';
  try {
    const date = new Date(ts);

    if (format === 'relative') {
      return formatRelativeTime(date);
    } else if (format === 'iso') {
      return date.toISOString();
    }

    // Default: absolute (HH:MM:SS)
    return date.toLocaleTimeString('en-US', {
      hour12: false,
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit'
    });
  } catch {
    return ts;
  }
}

/**
 * Format full timestamp with date for tooltips
 * @param {string} ts - ISO timestamp
 * @returns {string} Full formatted datetime
 */
export function formatFullTimestamp(ts) {
  if (!ts) return '';
  try {
    const date = new Date(ts);
    return date.toLocaleString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false
    });
  } catch {
    return ts;
  }
}

/**
 * Format a timestamp as a short local date-time (e.g. "Sep 23, 08:15:02"),
 * in the viewer's locale. Returns '-' for an empty value.
 * @param {string} ts - ISO timestamp
 * @returns {string} Formatted datetime
 */
export function formatShortDateTime(ts) {
  if (!ts) return '-';
  try {
    const d = new Date(ts);
    return d.toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
  } catch {
    return ts;
  }
}

/**
 * Compact a count with a K/M/B suffix and always one decimal:
 * 999 -> '999', 1000 -> '1.0K', 1234 -> '1.2K', 2500000 -> '2.5M'.
 * The one compact-count format of the UI (histogram, patterns, fields,
 * sources, dashboard widgets).
 * @param {number | null | undefined} num - Count
 * @returns {string} Compact count ('0' when unknown)
 */
export function formatCount(num) {
  if (num === null || num === undefined) return '0';
  if (num >= 1000000000) return (num / 1000000000).toFixed(1) + 'B';
  if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
  if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
  return num.toString();
}

/**
 * Format bytes to human readable size
 * @param {number} bytes - Size in bytes
 * @param {number} decimals - Decimal places
 * @returns {string} Formatted size
 */
export function formatBytes(bytes, decimals = 1) {
  if (bytes === 0) return '0 B';
  if (!bytes) return '-';

  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));

  return parseFloat((bytes / Math.pow(k, i)).toFixed(decimals)) + ' ' + sizes[i];
}

/**
 * Format relative time (e.g., "2 minutes ago")
 * @param {string|Date} date - Date to format
 * @returns {string} Relative time string
 */
export function formatRelativeTime(date) {
  const now = new Date();
  const then = new Date(date);
  const diff = now - then;

  const seconds = Math.floor(diff / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (seconds < 60) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  if (hours < 24) return `${hours}h ago`;
  if (days < 7) return `${days}d ago`;

  return formatFullTimestamp(date);
}

/**
 * Format number with locale-specific separators
 * @param {number} num - Number to format
 * @returns {string} Formatted number
 */
export function formatNumber(num) {
  if (num === null || num === undefined) return '0';
  return num.toLocaleString();
}

/**
 * Format a duration in milliseconds with a unit that fits its size
 * (us / ms / s / min).
 * @param {number | null | undefined} ms - Duration in milliseconds
 * @returns {string} Formatted duration, or '-' when unknown
 */
export function formatDuration(ms) {
  if (ms === null || ms === undefined) return '-';
  if (ms < 1) return `${(ms * 1000).toFixed(0)}us`;
  if (ms < 1000) return `${ms.toFixed(1)}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`;
  return `${(ms / 60000).toFixed(1)}min`;
}
