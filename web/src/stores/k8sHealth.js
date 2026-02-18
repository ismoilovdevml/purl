import { writable } from 'svelte/store';
import { error as toastError } from './toast.js';

export const podHealth = writable({ pods: [], total: 0 });
export const healthSummary = writable({ summary: {}, total_unhealthy: 0 });
export const healthLoading = writable(false);
export const healthError = writable(null);

const API_BASE = '/api';

let refreshTimer = null;

export async function fetchPodHealth(hours = 1) {
  healthLoading.set(true);
  healthError.set(null);

  try {
    const params = new URLSearchParams({ hours: hours.toString() });

    const [podsRes, summaryRes] = await Promise.all([
      fetch(`${API_BASE}/k8s/health/pods?${params}`),
      fetch(`${API_BASE}/k8s/health?${params}`),
    ]);

    if (podsRes.status === 403) {
      // Feature not available on current plan
      healthError.set('K8s monitoring requires a Pro or Enterprise license');
      return;
    }

    if (!podsRes.ok || !summaryRes.ok) {
      throw new Error('Failed to fetch pod health data');
    }

    const podsData = await podsRes.json();
    const summaryData = await summaryRes.json();

    podHealth.set(podsData);
    healthSummary.set(summaryData);
  } catch (err) {
    healthError.set(err.message);
    toastError('Failed to load pod health: ' + (err.message || 'Unknown error'));
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
