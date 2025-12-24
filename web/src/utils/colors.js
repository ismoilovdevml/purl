/**
 * Purl - Color Utilities
 * Log level colors and color-related helpers
 */

/**
 * Log level color mapping (internal)
 */
const LEVEL_COLORS = {
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
