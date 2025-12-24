/**
 * Purl - Color Utilities
 * Log level colors and color-related helpers
 */

/**
 * Log level color mapping
 */
export const LEVEL_COLORS = {
  TRACE: '#6e7681',
  DEBUG: '#8b949e',
  INFO: '#3fb950',
  WARN: '#d29922',
  WARNING: '#d29922',
  ERROR: '#f85149',
  FATAL: '#ff7b72',
  CRITICAL: '#ff7b72',
  PANIC: '#ff7b72'
};

/**
 * Get color for log level
 * @param {string} level - Log level
 * @returns {string} Hex color
 */
export function getLevelColor(level) {
  if (!level) return LEVEL_COLORS.INFO;
  return LEVEL_COLORS[level.toUpperCase()] || LEVEL_COLORS.INFO;
}

/**
 * Get background color with alpha for log level
 * @param {string} level - Log level
 * @param {number} alpha - Alpha value (0-1)
 * @returns {string} RGBA color
 */
export function getLevelBgColor(level, alpha = 0.15) {
  const hex = getLevelColor(level);
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/**
 * Field colors for different data types
 */
export const FIELD_COLORS = {
  service: '#58a6ff',
  host: '#a371f7',
  namespace: '#f0883e',
  pod: '#3fb950',
  node: '#a371f7',
  timestamp: '#8b949e',
  level: 'inherit', // Uses level-specific color
  message: '#c9d1d9',
  trace_id: '#79c0ff',
  request_id: '#79c0ff'
};

/**
 * Get color for a field
 * @param {string} field - Field name
 * @returns {string} Color value
 */
export function getFieldColor(field) {
  return FIELD_COLORS[field] || '#c9d1d9';
}

/**
 * HTTP status code colors
 */
export const STATUS_COLORS = {
  '2xx': '#3fb950',
  '3xx': '#58a6ff',
  '4xx': '#d29922',
  '5xx': '#f85149'
};

/**
 * Get color for HTTP status code
 * @param {number|string} status - HTTP status code
 * @returns {string} Hex color
 */
export function getStatusColor(status) {
  const code = parseInt(status, 10);
  if (code >= 200 && code < 300) return STATUS_COLORS['2xx'];
  if (code >= 300 && code < 400) return STATUS_COLORS['3xx'];
  if (code >= 400 && code < 500) return STATUS_COLORS['4xx'];
  if (code >= 500) return STATUS_COLORS['5xx'];
  return '#8b949e';
}

/**
 * Chart colors for graphs and visualizations
 */
export const CHART_COLORS = [
  '#58a6ff', // primary blue
  '#3fb950', // green
  '#a371f7', // purple
  '#f0883e', // orange
  '#d29922', // yellow
  '#79c0ff', // light blue
  '#f85149', // red
  '#8b949e'  // gray
];

/**
 * Get chart color by index (cycles through palette)
 * @param {number} index - Color index
 * @returns {string} Hex color
 */
export function getChartColor(index) {
  return CHART_COLORS[index % CHART_COLORS.length];
}

/**
 * Convert hex to RGBA
 * @param {string} hex - Hex color
 * @param {number} alpha - Alpha value
 * @returns {string} RGBA color
 */
export function hexToRgba(hex, alpha = 1) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}
