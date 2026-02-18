import { writable } from 'svelte/store';
import { error as toastError } from './toast.js';

const API_BASE = '/api';

export const selectedCluster = writable('all');
export const clusters = writable([]);
export const clustersLoading = writable(false);

export async function fetchClusters() {
  clustersLoading.set(true);
  try {
    const response = await fetch(`${API_BASE}/clusters`);
    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch clusters');
    }
    const data = await response.json();
    clusters.set(data.clusters || []);
  } catch (err) {
    console.error('Failed to fetch clusters:', err);
    toastError('Failed to load clusters: ' + (err.message || 'Unknown error'));
  } finally {
    clustersLoading.set(false);
  }
}

export function setCluster(name) {
  selectedCluster.set(name);
}
