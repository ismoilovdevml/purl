/**
 * Purl - Centralized API Module
 * All API calls should go through this module
 */

export const API_BASE = '/api';

// CSRF token cache
let csrfToken = null;

/**
 * Fetch CSRF token from server
 * @returns {Promise<string|null>} CSRF token
 */
export async function fetchCsrfToken() {
  if (csrfToken) return csrfToken;
  try {
    const response = await fetch(`${API_BASE}/csrf-token`);
    const data = await response.json();
    csrfToken = data.csrf_token;
    // Refresh token every 30 minutes
    setTimeout(() => { csrfToken = null; }, 30 * 60 * 1000);
    return csrfToken;
  } catch {
    return null;
  }
}

/**
 * Get headers for API requests
 * @returns {Object} Headers object
 */
export function getHeaders() {
  return { 'Content-Type': 'application/json' };
}

/**
 * Get headers with CSRF token for POST/PUT/DELETE
 * @returns {Promise<Object>} Headers object with CSRF token
 */
export async function getSecureHeaders() {
  const token = await fetchCsrfToken();
  return {
    'Content-Type': 'application/json',
    ...(token ? { 'X-CSRF-Token': token } : {})
  };
}

// ============================================
// Generic API Methods
// ============================================

/**
 * Make a GET request
 * @param {string} endpoint - API endpoint
 * @param {Object} options - Fetch options
 * @returns {Promise<Object>} Response data
 */
export async function apiGet(endpoint, options = {}) {
  const response = await fetch(`${API_BASE}${endpoint}`, {
    ...options,
    headers: getHeaders(),
  });
  return response.json();
}

/**
 * Make a POST request
 * @param {string} endpoint - API endpoint
 * @param {Object} body - Request body
 * @param {Object} options - Fetch options
 * @returns {Promise<Object>} Response data
 */
export async function apiPost(endpoint, body, options = {}) {
  const headers = await getSecureHeaders();
  const response = await fetch(`${API_BASE}${endpoint}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    ...options,
  });
  return response.json();
}

/**
 * Make a PUT request
 * @param {string} endpoint - API endpoint
 * @param {Object} body - Request body
 * @param {Object} options - Fetch options
 * @returns {Promise<Object>} Response data
 */
export async function apiPut(endpoint, body, options = {}) {
  const headers = await getSecureHeaders();
  const response = await fetch(`${API_BASE}${endpoint}`, {
    method: 'PUT',
    headers,
    body: JSON.stringify(body),
    ...options,
  });
  return response.json();
}

/**
 * Make a DELETE request
 * @param {string} endpoint - API endpoint
 * @param {Object} options - Fetch options
 * @returns {Promise<Object>} Response data
 */
export async function apiDelete(endpoint, options = {}) {
  const headers = await getSecureHeaders();
  const response = await fetch(`${API_BASE}${endpoint}`, {
    method: 'DELETE',
    headers,
    ...options,
  });
  return response.json();
}

// ============================================
// Log APIs
// ============================================

/**
 * Search logs
 * @param {Object} params - Search parameters
 * @param {AbortSignal} signal - Abort signal
 * @returns {Promise<Object>} Search results
 */
export async function searchLogs(params, signal = null) {
  const queryParams = new URLSearchParams(params);
  const response = await fetch(`${API_BASE}/logs?${queryParams}`, { signal });
  return response.json();
}

/**
 * Fetch log context
 * @param {string} logId - Log ID
 * @param {number} before - Logs before
 * @param {number} after - Logs after
 * @returns {Promise<Object|null>} Context data
 */
export async function fetchLogContext(logId, before = 50, after = 50) {
  try {
    const params = new URLSearchParams({
      before: before.toString(),
      after: after.toString(),
    });
    const response = await fetch(`${API_BASE}/logs/${logId}/context?${params}`);
    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch context');
    }
    return response.json();
  } catch (err) {
    console.error('Failed to fetch log context:', err);
    return null;
  }
}

// ============================================
// Statistics APIs
// ============================================

/**
 * Fetch field statistics
 * @param {string} field - Field name
 * @param {Object} params - Query parameters
 * @param {AbortSignal} signal - Abort signal
 * @returns {Promise<Object>} Field stats
 */
export async function fetchFieldStats(field, params, signal = null) {
  const queryParams = new URLSearchParams(params);
  const response = await fetch(`${API_BASE}/stats/fields/${field}?${queryParams}`, { signal });
  return response.json();
}

/**
 * Fetch histogram data
 * @param {Object} params - Query parameters
 * @param {AbortSignal} signal - Abort signal
 * @returns {Promise<Object>} Histogram data
 */
export async function fetchHistogram(params, signal = null) {
  const queryParams = new URLSearchParams(params);
  const response = await fetch(`${API_BASE}/stats/histogram?${queryParams}`, { signal });
  return response.json();
}

/**
 * Fetch server metrics
 * @param {AbortSignal} signal - Abort signal
 * @returns {Promise<Object>} Metrics data
 */
export async function fetchMetrics(signal = null) {
  const response = await fetch(`${API_BASE}/metrics/json`, { signal });
  return response.json();
}

/**
 * Fetch database stats
 * @returns {Promise<Object>} Stats data
 */
export async function fetchStats() {
  const response = await fetch(`${API_BASE}/stats`);
  return response.json();
}

// ============================================
// Trace APIs
// ============================================

/**
 * Fetch trace by ID
 * @param {string} traceId - Trace ID
 * @returns {Promise<Object|null>} Trace data
 */
export async function fetchTrace(traceId) {
  if (!traceId) return null;
  try {
    const response = await fetch(`${API_BASE}/traces/${traceId}`);
    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch trace');
    }
    return response.json();
  } catch (err) {
    console.error('Failed to fetch trace:', err);
    return null;
  }
}

/**
 * Fetch trace timeline
 * @param {string} traceId - Trace ID
 * @returns {Promise<Object|null>} Timeline data
 */
export async function fetchTraceTimeline(traceId) {
  if (!traceId) return null;
  try {
    const response = await fetch(`${API_BASE}/traces/${traceId}/timeline`);
    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch timeline');
    }
    return response.json();
  } catch (err) {
    console.error('Failed to fetch trace timeline:', err);
    return null;
  }
}

/**
 * Fetch request by ID
 * @param {string} requestId - Request ID
 * @returns {Promise<Object|null>} Request data
 */
export async function fetchRequest(requestId) {
  if (!requestId) return null;
  try {
    const response = await fetch(`${API_BASE}/requests/${requestId}`);
    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch request');
    }
    return response.json();
  } catch (err) {
    console.error('Failed to fetch request:', err);
    return null;
  }
}

// ============================================
// Pattern APIs
// ============================================

/**
 * Fetch patterns
 * @param {Object} params - Query parameters
 * @param {AbortSignal} signal - Abort signal
 * @returns {Promise<Object>} Patterns data
 */
export async function fetchPatterns(params, signal = null) {
  const queryParams = new URLSearchParams(params);
  const response = await fetch(`${API_BASE}/patterns?${queryParams}`, { signal });
  if (!response.ok) {
    const err = await response.json();
    throw new Error(err.error || 'Failed to fetch patterns');
  }
  return response.json();
}

/**
 * Fetch logs for a pattern
 * @param {string} patternHash - Pattern hash
 * @param {Object} params - Query parameters
 * @returns {Promise<Object|null>} Pattern logs
 */
export async function fetchPatternLogs(patternHash, params) {
  if (!patternHash) return null;
  try {
    const queryParams = new URLSearchParams(params);
    const response = await fetch(`${API_BASE}/patterns/${patternHash}/logs?${queryParams}`);
    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || 'Failed to fetch pattern logs');
    }
    return response.json();
  } catch (err) {
    console.error('Failed to fetch pattern logs:', err);
    return null;
  }
}

// ============================================
// Settings APIs
// ============================================

/**
 * Fetch server settings
 * @returns {Promise<Object>} Settings data
 */
export async function fetchSettings() {
  const response = await fetch(`${API_BASE}/settings`, { headers: getHeaders() });
  return response.json();
}

/**
 * Save ClickHouse settings
 * @param {Object} settings - Settings to save
 * @returns {Promise<Object>} Response
 */
export async function saveClickHouseSettings(settings) {
  return apiPut('/settings/clickhouse', settings);
}

/**
 * Test ClickHouse connection
 * @param {Object} settings - Connection settings
 * @returns {Promise<Object>} Test result
 */
export async function testClickHouseConnection(settings) {
  return apiPost('/config/test-clickhouse', settings);
}

/**
 * Save retention settings
 * @param {number} days - Retention days
 * @returns {Promise<Object>} Response
 */
export async function saveRetention(days) {
  return apiPut('/settings/retention', { days });
}

/**
 * Fetch retention stats
 * @returns {Promise<Object>} Stats data
 */
export async function fetchRetentionStats() {
  const response = await fetch(`${API_BASE}/config/retention`, { headers: getHeaders() });
  return response.json();
}

/**
 * Save notification settings
 * @param {string} type - Notification type (telegram, slack, webhook)
 * @param {Object} settings - Settings to save
 * @returns {Promise<Object>} Response
 */
export async function saveNotification(type, settings) {
  return apiPut(`/settings/notifications/${type}`, settings);
}

/**
 * Test notification
 * @param {string} type - Notification type
 * @returns {Promise<Object>} Test result
 */
export async function testNotification(type) {
  return apiPost(`/settings/notifications/${type}/test`, {});
}

// ============================================
// System APIs
// ============================================

/**
 * Fetch system health
 * @returns {Promise<Object>} Health data
 */
export async function fetchHealth() {
  const response = await fetch(`${API_BASE}/health`);
  return response.json();
}

/**
 * Clear query cache
 * @returns {Promise<Object>} Response
 */
export async function clearCache() {
  return apiDelete('/cache');
}

/**
 * Fetch table analytics
 * @returns {Promise<Object>} Tables data
 */
export async function fetchTableAnalytics() {
  const response = await fetch(`${API_BASE}/analytics/tables`);
  return response.json();
}

// ============================================
// Saved Searches APIs
// ============================================

/**
 * Fetch saved searches
 * @returns {Promise<Object>} Searches data
 */
export async function fetchSavedSearches() {
  return apiGet('/saved-searches');
}

/**
 * Create a saved search
 * @param {Object} search - Search data {name, query, time_range}
 * @returns {Promise<Object>} Response
 */
export async function createSavedSearch(search) {
  return apiPost('/saved-searches', search);
}

/**
 * Delete a saved search
 * @param {string} id - Search ID
 * @returns {Promise<Object>} Response
 */
export async function deleteSavedSearch(id) {
  return apiDelete(`/saved-searches/${id}`);
}

// ============================================
// Alerts APIs
// ============================================

/**
 * Fetch alerts
 * @returns {Promise<Object>} Alerts data
 */
export async function fetchAlerts() {
  return apiGet('/alerts');
}

/**
 * Create an alert
 * @param {Object} alert - Alert data
 * @returns {Promise<Object>} Response
 */
export async function createAlert(alert) {
  return apiPost('/alerts', alert);
}

/**
 * Update an alert
 * @param {string} id - Alert ID
 * @param {Object} alert - Alert data
 * @returns {Promise<Object>} Response
 */
export async function updateAlert(id, alert) {
  return apiPut(`/alerts/${id}`, alert);
}

/**
 * Delete an alert
 * @param {string} id - Alert ID
 * @returns {Promise<Object>} Response
 */
export async function deleteAlert(id) {
  return apiDelete(`/alerts/${id}`);
}

/**
 * Toggle alert enabled state
 * @param {string} id - Alert ID
 * @param {boolean} enabled - Enable/disable
 * @returns {Promise<Object>} Response
 */
export async function toggleAlertEnabled(id, enabled) {
  return apiPut(`/alerts/${id}`, { enabled });
}

/**
 * Check alerts and trigger notifications
 * @returns {Promise<Object>} Check result with triggered alerts
 */
export async function checkAlerts() {
  return apiPost('/alerts/check', {});
}

// ============================================
// WebSocket
// ============================================

/**
 * Connect to WebSocket for live tail
 * @returns {WebSocket} WebSocket connection
 */
export function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return new WebSocket(`${protocol}//${window.location.host}/api/logs/stream`);
}
