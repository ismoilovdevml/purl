/**
 * Purl - Common Utility Functions
 * Centralized utilities to avoid duplication across components
 */

// ============================================
// HTML/XSS Safety
// ============================================

/**
 * Escape HTML to prevent XSS attacks
 * @param {string} str - String to escape
 * @returns {string} Escaped string
 */
export function escapeHtml(str) {
  if (!str) return '';
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

/**
 * Safe HTML with specific allowed tags only
 * @param {string} html - HTML string to sanitize
 * @returns {string} Sanitized HTML
 */
export function sanitizeHtml(html) {
  if (!html) return '';
  let safe = escapeHtml(html);
  safe = safe
    .replace(/&lt;span class=&quot;([a-z-]+)&quot;&gt;/g, '<span class="$1">')
    .replace(/&lt;\/span&gt;/g, '</span>');
  return safe;
}

// ============================================
// Number Formatting
// ============================================

/**
 * Format large numbers with K/M suffixes
 * @param {number} num - Number to format
 * @returns {string} Formatted number
 */
export function formatNumber(num) {
  if (!num) return '0';
  if (num >= 1000000) return (num / 1000000).toFixed(1) + 'M';
  if (num >= 1000) return (num / 1000).toFixed(1) + 'K';
  return num.toLocaleString();
}

/**
 * Format bytes to human readable format
 * @param {number} bytes - Bytes to format
 * @returns {string} Formatted size (e.g., "1.5 MB")
 */
export function formatBytes(bytes) {
  if (!bytes) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return (bytes / Math.pow(k, i)).toFixed(1) + ' ' + sizes[i];
}

// ============================================
// Time Formatting
// ============================================

/**
 * Format timestamp for display (time only)
 * @param {string|Date} ts - Timestamp to format
 * @returns {string} Formatted time (e.g., "14:30:45")
 */
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

/**
 * Format full timestamp with date
 * @param {string|Date} ts - Timestamp to format
 * @returns {string} Formatted date and time
 */
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

/**
 * Format time from Date object
 * @param {Date} date - Date to format
 * @returns {string} Formatted time
 */
export function formatTime(date) {
  if (!date) return '-';
  return date.toLocaleTimeString();
}

/**
 * Format uptime in human readable format
 * @param {number} seconds - Uptime in seconds
 * @returns {string} Formatted uptime (e.g., "2d 5h 30m")
 */
export function formatUptime(seconds) {
  if (!seconds) return '0s';
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const parts = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (mins > 0) parts.push(`${mins}m`);
  return parts.join(' ') || '< 1m';
}

// ============================================
// Log Level Helpers
// ============================================

/**
 * Get color for log level
 * @param {string} level - Log level (ERROR, WARNING, INFO, etc.)
 * @returns {string} CSS color value
 */
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

// ============================================
// Function Utilities
// ============================================

/**
 * Debounce a function
 * @param {Function} fn - Function to debounce
 * @param {number} delay - Delay in milliseconds
 * @returns {Function} Debounced function
 */
let debounceTimer = null;
export function debounce(fn, delay = 300) {
  return (...args) => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => fn(...args), delay);
  };
}

/**
 * Throttle a function
 * @param {Function} fn - Function to throttle
 * @param {number} limit - Limit in milliseconds
 * @param {string} key - Key for multiple throttled functions
 * @returns {Function} Throttled function
 */
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

/**
 * Simple memoization cache
 * @param {Function} fn - Function to memoize
 * @param {Function} keyFn - Key generator function
 * @returns {Function} Memoized function
 */
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

    if (memoCache.size >= MEMO_MAX_SIZE) {
      const oldest = memoCache.keys().next().value;
      memoCache.delete(oldest);
    }

    memoCache.set(key, { value, time: Date.now() });
    return value;
  };
}

// ============================================
// Pattern Highlighting
// ============================================

/**
 * Highlight placeholders in pattern text (XSS-safe)
 * @param {string} pattern - Pattern string
 * @returns {string} HTML with highlighted placeholders
 */
export function highlightPattern(pattern) {
  if (!pattern) return '';
  let safe = escapeHtml(pattern);
  return safe
    .replace(/&lt;UUID&gt;/g, '<span class="placeholder uuid">&lt;UUID&gt;</span>')
    .replace(/&lt;IP&gt;/g, '<span class="placeholder ip">&lt;IP&gt;</span>')
    .replace(/&lt;NUM&gt;/g, '<span class="placeholder num">&lt;NUM&gt;</span>')
    .replace(/&lt;DATETIME&gt;/g, '<span class="placeholder datetime">&lt;DATETIME&gt;</span>')
    .replace(/&lt;HEX&gt;/g, '<span class="placeholder hex">&lt;HEX&gt;</span>');
}

/**
 * Highlight matching text in a string (XSS-safe)
 * @param {string} text - Text to search in
 * @param {string} query - Query to highlight
 * @returns {string} HTML with highlighted matches
 */
export function highlightText(text, query) {
  if (!text) return '';
  let safeText = escapeHtml(text);

  if (query) {
    const safeQuery = escapeHtml(query);
    const escaped = safeQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const regex = new RegExp(`(${escaped})`, 'gi');
    safeText = safeText.replace(regex, '<mark class="search-highlight">$1</mark>');
  }

  return safeText;
}

// ============================================
// Download Helpers
// ============================================

/**
 * Download data as a file
 * @param {Blob} blob - Data blob
 * @param {string} filename - Filename for download
 */
export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
