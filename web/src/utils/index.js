/**
 * Purl - Utilities Index
 * Re-export all utilities for convenient imports
 */

// Format utilities
export {
  formatTimestamp,
  formatFullTimestamp,
  formatCount,
  formatBytes,
  formatDuration,
  formatPercentage,
  formatRelativeTime,
  formatNumber,
  truncate
} from './format.js';

// Color utilities
export {
  LEVEL_COLORS,
  getLevelColor,
  getLevelBgColor,
  FIELD_COLORS,
  getFieldColor,
  STATUS_COLORS,
  getStatusColor,
  CHART_COLORS,
  getChartColor,
  hexToRgba
} from './colors.js';

// DOM utilities
export {
  escapeHtml,
  highlightText,
  clickOutside,
  copyToClipboard,
  debounce,
  throttle,
  uniqueId,
  isInViewport,
  scrollIntoView,
  focusFirstElement,
  trapFocus
} from './dom.js';
