import { writable } from 'svelte/store';
import { api } from '../utils/api.js';
import { error as toastError } from './toast.js';

// ============================================
// AI state stores
// ============================================

export const aiEnabled = writable(false);
export const aiConfigured = writable(false);
export const aiProvider = writable('openai');
export const aiLoading = writable(false);
export const aiError = writable(null);

// NL query results
export const aiQueryResult = writable(null);
export const aiQuerySQL = writable('');

// Analysis results
export const aiAnalysisResult = writable(null);
export const aiAnalysisLoading = writable(false);

// Explanation results
export const aiExplainResult = writable(null);
export const aiExplainLoading = writable(false);

// Suggestions
export const aiSuggestions = writable([]);

// Available providers list
export const aiProviders = writable([]);

// ============================================
// Initialize — load config on startup
// ============================================

export async function initAI() {
  try {
    const data = await api.get('/ai/providers');
    aiProvider.set(data.current || 'openai');
    aiConfigured.set(data.configured === true);
    aiEnabled.set(data.configured === true);
    aiProviders.set(data.providers || []);
  } catch {
    // AI not available — non-fatal
  }
}

// ============================================
// NL to SQL query
// ============================================

export async function queryAI(question, execute = true) {
  if (!question || question.trim().length < 3) return null;

  aiLoading.set(true);
  aiError.set(null);
  aiQueryResult.set(null);
  aiQuerySQL.set('');

  try {
    const data = await api.post('/ai/query', { question: question.trim(), execute });

    // A 2xx response can still carry an application-level error field.
    if (data?.error) {
      const msg = data.error || 'AI query failed';
      aiError.set(msg);
      toastError(msg);
      return null;
    }

    aiQuerySQL.set(data.sql || '');
    aiQueryResult.set(data);
    return data;
  } catch (err) {
    // 401 -> session cleared centrally by the api client (with one toast).
    if (err.isUnauthorized) return null;
    const msg = err.isNetworkError
      ? 'Failed to connect to AI service'
      : (err.body?.error || 'AI query failed');
    aiError.set(msg);
    toastError(msg);
    return null;
  } finally {
    aiLoading.set(false);
  }
}

// ============================================
// Batch log analysis
// ============================================

export async function analyzeSelectedLogs(logs) {
  if (!logs || logs.length === 0) return null;

  aiAnalysisLoading.set(true);
  aiAnalysisResult.set(null);

  try {
    const data = await api.post('/ai/analyze', { logs });

    if (data?.error) {
      const msg = data.error || 'Analysis failed';
      toastError(msg);
      return null;
    }

    aiAnalysisResult.set(data);
    return data;
  } catch (err) {
    if (err.isUnauthorized) return null;
    const msg = err.isNetworkError
      ? 'Failed to connect to AI service'
      : (err.body?.error || 'Analysis failed');
    toastError(msg);
    return null;
  } finally {
    aiAnalysisLoading.set(false);
  }
}

// ============================================
// Single log explanation
// ============================================

export async function explainLog(log) {
  if (!log) return null;

  aiExplainLoading.set(true);
  aiExplainResult.set(null);

  try {
    const data = await api.post('/ai/explain', { log });

    if (data?.error) {
      const msg = data.error || 'Explanation failed';
      toastError(msg);
      return null;
    }

    aiExplainResult.set(data);
    return data;
  } catch (err) {
    if (err.isUnauthorized) return null;
    const msg = err.isNetworkError
      ? 'Failed to connect to AI service'
      : (err.body?.error || 'Explanation failed');
    toastError(msg);
    return null;
  } finally {
    aiExplainLoading.set(false);
  }
}

// ============================================
// Fetch suggestions
// ============================================

export async function fetchSuggestions() {
  try {
    const data = await api.get('/ai/suggest');
    aiSuggestions.set(data.suggestions || []);
  } catch {
    // non-fatal
  }
}
