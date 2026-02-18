import { writable } from 'svelte/store';
import { error as toastError, success as toastSuccess } from './toast.js';

export const dashboards = writable([]);
export const currentDashboard = writable(null);
export const dashboardLoading = writable(false);

export async function fetchDashboards() {
  dashboardLoading.set(true);
  try {
    const res = await fetch('/api/dashboards');
    if (!res.ok) throw new Error('Failed to fetch dashboards');
    const data = await res.json();
    dashboards.set(data.dashboards || []);
  } catch (err) {
    toastError(err.message);
  } finally {
    dashboardLoading.set(false);
  }
}

export async function fetchDashboard(id) {
  dashboardLoading.set(true);
  try {
    const res = await fetch(`/api/dashboards/${id}`);
    if (!res.ok) throw new Error('Failed to fetch dashboard');
    const data = await res.json();
    currentDashboard.set(data);
    return data;
  } catch (err) {
    toastError(err.message);
    return null;
  } finally {
    dashboardLoading.set(false);
  }
}

export async function createDashboard(dashboard) {
  try {
    const res = await fetch('/api/dashboards', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(dashboard),
    });
    if (!res.ok) {
      const data = await res.json();
      throw new Error(data.error || 'Failed to create dashboard');
    }
    toastSuccess('Dashboard created');
    await fetchDashboards();
    return true;
  } catch (err) {
    toastError(err.message);
    return false;
  }
}

export async function updateDashboard(id, data) {
  try {
    const res = await fetch(`/api/dashboards/${id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    if (!res.ok) throw new Error('Failed to update dashboard');
    toastSuccess('Dashboard saved');
    await fetchDashboards();
    return true;
  } catch (err) {
    toastError(err.message);
    return false;
  }
}

export async function deleteDashboard(id) {
  try {
    const res = await fetch(`/api/dashboards/${id}`, { method: 'DELETE' });
    if (!res.ok) throw new Error('Failed to delete dashboard');
    toastSuccess('Dashboard deleted');
    currentDashboard.set(null);
    await fetchDashboards();
    return true;
  } catch (err) {
    toastError(err.message);
    return false;
  }
}

export const templates = writable([]);

export async function fetchTemplates() {
  try {
    const res = await fetch('/api/dashboards/templates');
    if (!res.ok) throw new Error('Failed to fetch templates');
    const data = await res.json();
    templates.set(data.templates || []);
  } catch (err) {
    toastError(err.message);
  }
}

export async function createFromTemplate(templateId, name) {
  try {
    const res = await fetch('/api/dashboards/from-template', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ template_id: templateId, name }),
    });
    if (!res.ok) {
      const data = await res.json();
      throw new Error(data.error || 'Failed to create from template');
    }
    toastSuccess('Dashboard created from template');
    await fetchDashboards();
    return true;
  } catch (err) {
    toastError(err.message);
    return false;
  }
}

export async function executeWidget(widget) {
  try {
    const res = await fetch('/api/dashboards/widget', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(widget),
    });
    if (!res.ok) throw new Error('Widget query failed');
    return await res.json();
  } catch (err) {
    return { error: err.message };
  }
}
