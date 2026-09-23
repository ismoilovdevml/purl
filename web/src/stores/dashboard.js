import { writable } from 'svelte/store';
import { api } from '../utils/api.js';
import { error as toastError, success as toastSuccess } from './toast.js';

export const dashboards = writable([]);
export const currentDashboard = writable(null);
export const dashboardLoading = writable(false);

export async function fetchDashboards() {
  dashboardLoading.set(true);
  try {
    const data = await api.get('/dashboards');
    dashboards.set(data.dashboards || []);
  } catch (err) {
    // 401 -> session cleared centrally by the api client (with one toast).
    if (err.isUnauthorized) return;
    toastError('Failed to fetch dashboards');
  } finally {
    dashboardLoading.set(false);
  }
}

export async function fetchDashboard(id) {
  dashboardLoading.set(true);
  try {
    const data = await api.get(`/dashboards/${id}`);
    currentDashboard.set(data);
    return data;
  } catch (err) {
    if (!err.isUnauthorized) toastError('Failed to fetch dashboard');
    return null;
  } finally {
    dashboardLoading.set(false);
  }
}

export async function createDashboard(dashboard) {
  try {
    await api.post('/dashboards', dashboard);
    toastSuccess('Dashboard created');
    await fetchDashboards();
    return true;
  } catch (err) {
    if (err.isUnauthorized) return false;
    toastError(err.body?.error || 'Failed to create dashboard');
    return false;
  }
}

export async function updateDashboard(id, data) {
  try {
    await api.put(`/dashboards/${id}`, data);
    toastSuccess('Dashboard saved');
    await fetchDashboards();
    return true;
  } catch (err) {
    if (err.isUnauthorized) return false;
    toastError('Failed to update dashboard');
    return false;
  }
}

export async function deleteDashboard(id) {
  try {
    await api.del(`/dashboards/${id}`);
    toastSuccess('Dashboard deleted');
    currentDashboard.set(null);
    await fetchDashboards();
    return true;
  } catch (err) {
    if (err.isUnauthorized) return false;
    toastError('Failed to delete dashboard');
    return false;
  }
}

export const templates = writable([]);

export async function fetchTemplates() {
  try {
    const data = await api.get('/dashboards/templates');
    templates.set(data.templates || []);
  } catch (err) {
    if (err.isUnauthorized) return;
    toastError('Failed to fetch templates');
  }
}

export async function createFromTemplate(templateId, name) {
  try {
    await api.post('/dashboards/from-template', { template_id: templateId, name });
    toastSuccess('Dashboard created from template');
    await fetchDashboards();
    return true;
  } catch (err) {
    if (err.isUnauthorized) return false;
    toastError(err.body?.error || 'Failed to create from template');
    return false;
  }
}

export async function executeWidget(widget) {
  try {
    return await api.post('/dashboards/widget', widget);
  } catch (err) {
    return { error: err.message };
  }
}
