import { writable } from 'svelte/store';
import { error as toastError } from './toast.js';
import { api } from '../utils/api.js';

export const podHealth = writable({ pods: [], total: 0 });
export const healthSummary = writable({ summary: {}, total_unhealthy: 0 });
export const healthLoading = writable(false);
export const healthError = writable(null);

let refreshTimer = null;

export async function fetchPodHealth(hours = 1) {
  healthLoading.set(true);
  healthError.set(null);

  try {
    const query = { hours: String(hours) };

    // allSettled, not all: unlike raw fetch, api.get rejects on any non-2xx,
    // so with Promise.all the sibling's rejection is never observed and
    // surfaces as an unhandled rejection (both endpoints fail together).
    const [podsResult, summaryResult] = await Promise.allSettled([
      api.get('/k8s/health/pods', { query }),
      api.get('/k8s/health', { query }),
    ]);

    if (podsResult.status === 'rejected') throw podsResult.reason;
    if (summaryResult.status === 'rejected') throw summaryResult.reason;

    podHealth.set(podsResult.value);
    healthSummary.set(summaryResult.value);
  } catch (err) {
    // Keep this page's own wording for HTTP failures; a network-level
    // failure (status 0) has nothing better to say than its own message.
    const message = err.status ? 'Failed to fetch pod health data' : (err.message || 'Failed to fetch pod health data');
    healthError.set(message);
    toastError('Failed to load pod health: ' + message);
  } finally {
    healthLoading.set(false);
  }
}

export function startAutoRefresh(intervalSec = 30, hours = 1) {
  stopAutoRefresh();
  fetchPodHealth(hours);
  refreshTimer = setInterval(() => fetchPodHealth(hours), intervalSec * 1000);
}

export function stopAutoRefresh() {
  if (refreshTimer) {
    clearInterval(refreshTimer);
    refreshTimer = null;
  }
}
