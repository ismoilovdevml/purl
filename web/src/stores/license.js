import { writable, get } from 'svelte/store';
import { api } from '../utils/api.js';

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

export const isTrialPlan = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.plan === 'trial'))
};

export const trialDaysRemaining = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.trial ? info.trial_days_remaining : 0))
};

export const trialExpiresAt = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.trial ? info.trial_expires_at : null))
};

export const isPaidPlan = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(
    info?.plan === 'pro' || info?.plan === 'enterprise' || info?.plan === 'trial'
  ))
};

export const isEnterprise = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.plan === 'enterprise'))
};

export const licenseFeatures = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.features || []))
};

export const licenseLimits = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.limits || {}))
};

export const k8sMode = {
  subscribe: (fn) => licenseInfo.subscribe(info => fn(info?.k8s_mode || false))
};

// Feature aliases: a granted feature name that also satisfies another gate.
// Mirrors the backend (e.g. a Pro license granting `custom_dashboards` unlocks
// the `dashboards` UI). Keys are the gate name; values are names that satisfy it.
const FEATURE_ALIASES = {
  dashboards: ['custom_dashboards'],
};

// Check if a specific feature is available.
// Mirrors backend Purl::API::Controller::Base::has_feature:
//   1. Enterprise plan bypasses the features list (access to everything).
//   2. Otherwise the feature (or one of its aliases) must be in the list.
// An 'unknown' plan (not signed in) is NOT enterprise and has an empty features
// list, so this returns false — the "don't gate" safety lives in fetchLicense.
export function hasFeature(feature) {
  const info = get(licenseInfo);
  if (info?.plan === 'enterprise') return true;
  const features = info?.features || [];
  if (features.includes(feature)) return true;
  const aliases = FEATURE_ALIASES[feature] || [];
  return aliases.some(alias => features.includes(alias));
}

// Fetch license info from API
export async function fetchLicense() {
  licenseLoading.set(true);
  licenseError.set(null);
  try {
    const data = await api.get('/license');
    licenseInfo.set(data);
  } catch (err) {
    // Not signed in: we genuinely do not know the plan. Say so rather than
    // claiming "free", which would wrongly gate features in the UI.
    // (The 401 itself is handled centrally by the api client.)
    if (err.isUnauthorized) {
      licenseInfo.set({ plan: 'unknown', features: [], limits: {}, valid: false });
      return;
    }
    licenseError.set(err.message);
    licenseInfo.set({ plan: 'free', features: [], limits: {}, valid: true });
  } finally {
    licenseLoading.set(false);
  }
}

// Save a license key via settings API
export async function saveLicenseKey(key) {
  const data = await api.put('/settings/license', { key });
  await fetchLicense();
  return data;
}
