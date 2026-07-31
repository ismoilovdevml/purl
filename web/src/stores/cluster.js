import { writable } from 'svelte/store';
import { error as toastError } from './toast.js';
import { api } from '../utils/api.js';

export const selectedCluster = writable('all');
export const clusters = writable([]);
export const clustersLoading = writable(false);

export async function fetchClusters() {
  clustersLoading.set(true);
  try {
    const data = await api.get('/clusters');
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
