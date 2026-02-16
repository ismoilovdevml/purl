import { writable, get } from 'svelte/store';

const API_BASE = '/api';

// Core license state
export const licenseInfo = writable(null);
export const licenseLoading = writable(true);
export const licenseError = writable(null);

// Derived convenience stores
export const currentPlan = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.plan || 'free'))
};

export const isFreePlan = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(!info || info.plan === 'free'))
};

export const isPaidPlan = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.plan === 'pro' || info?.plan === 'enterprise'))
};

export const licenseFeatures = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.features || []))
};

export const licenseLimits = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.limits || {}))
};

// Check if a specific feature is available
export function hasFeature(feature) {
  const info = get(licenseInfo);
  return (info?.features || []).includes(feature);
}

// Fetch license info from API
export async function fetchLicense() {
  licenseLoading.set(true);
  licenseError.set(null);
  try {
    const res = await fetch(`${API_BASE}/license`);
    if (res.ok) {
      const data = await res.json();
      licenseInfo.set(data);
    } else if (res.status === 401) {
      licenseInfo.set({ plan: 'unknown', features: [], limits: {}, valid: false });
    } else {
      throw new Error('Failed to fetch license info');
    }
  } catch (err) {
    licenseError.set(err.message);
    licenseInfo.set({ plan: 'free', features: [], limits: {}, valid: true });
  } finally {
    licenseLoading.set(false);
  }
}

// Save a license key via settings API
export async function saveLicenseKey(key) {
  const res = await fetch(`${API_BASE}/settings/license`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key })
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(data.error || 'Failed to save license key');
  }
  await fetchLicense();
  return data;
}
