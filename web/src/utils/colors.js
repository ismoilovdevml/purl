/**
 * Purl - Color Utilities
 * Log level colors and color-related helpers
 */

/**
 * Log level color mapping (internal).
 *
 * This map is the single source of truth for level colours. They are applied
 * from JS (inline styles via getLevelColor), never by a CSS rule, so they
 * deliberately do NOT exist as --level-* tokens in styles/variables.css --
 * duplicating them there produced two sources of truth that drifted apart.
 *
 * Contrast floor: levels render at 11-12px on backgrounds as light as #21262d,
 * so every colour here must be >= 4.5:1 against #21262d.
 * TRACE #848d97 = 4.52:1 (passes); the previous #6e7681 was 3.31:1 (failed).
 */
const LEVEL_COLORS = {
  TRACE: '#848d97',
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
 * Badge variant for a log level (Badge.svelte's `variant` prop).
 * @param {string} level - Log level
 * @returns {'error' | 'warning' | 'primary' | 'default'}
 */
export function getLevelVariant(level) {
  const l = (level || '').toLowerCase();
  if (l === 'error' || l === 'fatal' || l === 'critical') return 'error';
  if (l === 'warn' || l === 'warning') return 'warning';
  if (l === 'info') return 'primary';
  return 'default';
}

/** Palette cycled through when services need distinguishable colours. */
const SERVICE_COLORS = [
  '#58a6ff', '#3fb950', '#d29922', '#f78166', '#a371f7',
  '#79c0ff', '#7ee787', '#e3b341', '#ffa657', '#d2a8ff',
  '#56d4dd', '#f0883e', '#bc8cff', '#39d353', '#db6d28',
];

/**
 * Build a colour picker that hands each new service the next palette colour
 * and returns the same colour for it on every later call.
 *
 * The memo is a plain object on purpose: the picker is called during render,
 * and a reactive ($state) map written from the template would throw
 * state_unsafe_mutation.
 * @returns {(service: string) => string}
 */
export function createServiceColorer() {
  const assigned = {};
  let next = 0;
  return (service) => {
    if (!assigned[service]) {
      assigned[service] = SERVICE_COLORS[next % SERVICE_COLORS.length];
      next += 1;
    }
    return assigned[service];
  };
}
