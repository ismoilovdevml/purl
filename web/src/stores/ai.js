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

// Analysis results.
// `aiAnalysisError` is what a failed run leaves behind. It exists because these
// calls resolve with `null` on failure instead of rejecting: without a sticky
// failure marker the panels' `!result && !loading` guards go true again the
// moment the request settles and re-POST forever — including for an upstream
// LLM call that succeeded and was already billed (a 200 carrying `{error}`).
export const aiAnalysisResult = writable(null);
export const aiAnalysisLoading = writable(false);
export const aiAnalysisError = writable(null);

// Explanation results (see the note above for aiExplainError).
export const aiExplainResult = writable(null);
export const aiExplainLoading = writable(false);
export const aiExplainError = writable(null);

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
    if (err.isUnauthorized) {
      // Session cleared centrally by the api client, which already toasted.
      // The store is still set, for the same reason as the other two below:
      // every failure path must leave a marker, or a caller that guards on
      // `!result && !loading && !error` re-fires the moment this settles.
      aiError.set('Session expired. Sign in again.');
      return null;
    }
    const msg = err.isNetworkError
      ? 'Failed to connect to AI service'
      : (err.userMessage || 'AI query failed');
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
  aiAnalysisError.set(null);

  try {
    const data = await api.post('/ai/analyze', { logs });

    if (data?.error) {
      const msg = data.error || 'Analysis failed';
      aiAnalysisError.set(msg);
      toastError(msg);
      return null;
    }

    aiAnalysisResult.set(data);
    return data;
  } catch (err) {
    // Every failure path must leave `aiAnalysisError` set — it is the only
    // thing that stops the caller's reactive guard from firing again.
    if (err.isUnauthorized) {
      // Session cleared centrally by the api client, which already toasted.
      aiAnalysisError.set('Session expired. Sign in again.');
      return null;
    }
    const msg = err.isNetworkError
      ? 'Failed to connect to AI service'
      : (err.userMessage || 'Analysis failed');
    aiAnalysisError.set(msg);
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
  aiExplainError.set(null);

  try {
    const data = await api.post('/ai/explain', { log });

    if (data?.error) {
      const msg = data.error || 'Explanation failed';
      aiExplainError.set(msg);
      toastError(msg);
      return null;
    }

    aiExplainResult.set(data);
    return data;
  } catch (err) {
    // Every failure path must leave `aiExplainError` set — it is the only
    // thing that stops the caller's reactive guard from firing again.
    if (err.isUnauthorized) {
      // Session cleared centrally by the api client, which already toasted.
      aiExplainError.set('Session expired. Sign in again.');
      return null;
    }
    const msg = err.isNetworkError
      ? 'Failed to connect to AI service'
      : (err.userMessage || 'Explanation failed');
    aiExplainError.set(msg);
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
