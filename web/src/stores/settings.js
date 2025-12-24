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

// Load settings from localStorage
function loadFromStorage() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) {
      return { ...defaultSettings, ...JSON.parse(saved) };
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
        const newSettings = { ...settings, [key]: value };
        localStorage.setItem(STORAGE_KEY, JSON.stringify(newSettings));
        return newSettings;
      });
    },

    // Update multiple settings at once
    setSettings(newSettings) {
      update(settings => {
        const merged = { ...settings, ...newSettings };
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
