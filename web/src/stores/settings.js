import { writable, get } from 'svelte/store';

// Default settings
const defaultSettings = {
  // Display settings
  defaultTimeRange: '15m',
  refreshInterval: 30,
  maxResults: 500,
  compactMode: false,
  lineWrap: true,

  // Log viewer settings
  showHost: true,
  showRaw: false,
  highlightErrors: true,
  autoScroll: true,
  timestampFormat: 'relative', // 'relative', 'absolute', 'iso'
};

// Storage key
const STORAGE_KEY = 'purl_settings';

// Bounds for the numeric settings. Every reader downstream treats these as
// trusted: `maxResults` is passed straight through as the /logs `limit`, which
// the backend interpolates into `LIMIT n` with no range check of its own — a
// stored `-1` is a ClickHouse syntax error (HTTP 500) on every search, and the
// log table renders "Showing max -1 logs". The number inputs' min/max
// attributes are a native hint only; nothing re-read them. Clamping happens
// here, at the single point where a value enters the store, so it also covers
// a hand-edited or corrupted localStorage blob — not just the settings form.
const NUMERIC_BOUNDS = {
  maxResults: { min: 50, max: 5000, fallback: defaultSettings.maxResults },
  refreshInterval: { min: 0, max: 300, fallback: defaultSettings.refreshInterval },
};

function clampSetting(key, value) {
  const bounds = NUMERIC_BOUNDS[key];
  if (!bounds) return value;
  const n = typeof value === 'number' ? Math.trunc(value) : parseInt(value, 10);
  // Covers NaN (empty field, "abc", null) and ±Infinity.
  if (!Number.isFinite(n)) return bounds.fallback;
  return Math.min(bounds.max, Math.max(bounds.min, n));
}

function sanitize(settings) {
  const out = { ...settings };
  for (const key of Object.keys(NUMERIC_BOUNDS)) {
    out[key] = clampSetting(key, out[key]);
  }
  return out;
}

/**
 * Clamp a log-result limit to the range the store would accept. Exported for
 * the request boundary in stores/logs.js, so the value that reaches the API is
 * bounded even if it never came through the settings form.
 */
export function clampMaxResults(value) {
  return clampSetting('maxResults', value);
}

// Load settings from localStorage
function loadFromStorage() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) {
      const parsed = { ...defaultSettings, ...JSON.parse(saved) };
      const clean = sanitize(parsed);
      // Persist the repair rather than re-doing it on every boot: an
      // out-of-range value left on disk would otherwise survive forever and
      // still be there for anything that reads the key directly.
      const changed = Object.keys(NUMERIC_BOUNDS).some((k) => clean[k] !== parsed[k]);
      if (changed) localStorage.setItem(STORAGE_KEY, JSON.stringify(clean));
      return clean;
    }
  } catch (err) {
    console.error('Failed to load settings:', err);
  }
  return { ...defaultSettings };
}

// Create the settings store
function createSettingsStore() {
  const { subscribe, set, update } = writable(loadFromStorage());

  return {
    subscribe,

    // Update a single setting
    setSetting(key, value) {
      update(settings => {
        const newSettings = { ...settings, [key]: clampSetting(key, value) };
        localStorage.setItem(STORAGE_KEY, JSON.stringify(newSettings));
        return newSettings;
      });
    },

    // Update multiple settings at once
    setSettings(newSettings) {
      update(settings => {
        const merged = sanitize({ ...settings, ...newSettings });
        localStorage.setItem(STORAGE_KEY, JSON.stringify(merged));
        return merged;
      });
    },

    // Reset to defaults
    reset() {
      localStorage.removeItem(STORAGE_KEY);
      set({ ...defaultSettings });
    },

    // Get current value (non-reactive)
    get() {
      return get({ subscribe });
    }
  };
}

// Export the store
export const settings = createSettingsStore();

// Export individual derived stores for convenience
export const compactMode = {
  subscribe: (fn) => settings.subscribe(s => fn(s.compactMode))
};

export const lineWrap = {
  subscribe: (fn) => settings.subscribe(s => fn(s.lineWrap))
};

export const showHost = {
  subscribe: (fn) => settings.subscribe(s => fn(s.showHost))
};

export const showRaw = {
  subscribe: (fn) => settings.subscribe(s => fn(s.showRaw))
};

export const highlightErrors = {
  subscribe: (fn) => settings.subscribe(s => fn(s.highlightErrors))
};

export const autoScroll = {
  subscribe: (fn) => settings.subscribe(s => fn(s.autoScroll))
};

export const timestampFormat = {
  subscribe: (fn) => settings.subscribe(s => fn(s.timestampFormat))
};

export const refreshInterval = {
  subscribe: (fn) => settings.subscribe(s => fn(s.refreshInterval))
};

export const maxResults = {
  subscribe: (fn) => settings.subscribe(s => fn(s.maxResults))
};

export const defaultTimeRange = {
  subscribe: (fn) => settings.subscribe(s => fn(s.defaultTimeRange))
};
