import { writable } from 'svelte/store';
import { error as toastError } from './toast.js';

const API_BASE = '/api';

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
    const res = await fetch(`${API_BASE}/ai/providers`);
    if (res.ok) {
      const data = await res.json();
      aiProvider.set(data.current || 'openai');
      aiConfigured.set(data.configured === true);
      aiEnabled.set(data.configured === true);
      aiProviders.set(data.providers || []);
    }
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
    const res = await fetch(`${API_BASE}/ai/query`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ question: question.trim(), execute }),
    });

    const data = await res.json();

    if (!res.ok || data.error) {
      const msg = data.error || 'AI query failed';
      aiError.set(msg);
      toastError(msg);
      return null;
    }

    aiQuerySQL.set(data.sql || '');
    aiQueryResult.set(data);
    return data;
  } catch {
    const msg = 'Failed to connect to AI service';
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
    const res = await fetch(`${API_BASE}/ai/analyze`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ logs }),
    });

    const data = await res.json();

    if (!res.ok || data.error) {
      const msg = data.error || 'Analysis failed';
      toastError(msg);
      return null;
    }

    aiAnalysisResult.set(data);
    return data;
  } catch {
    toastError('Failed to connect to AI service');
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
    const res = await fetch(`${API_BASE}/ai/explain`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ log }),
    });

    const data = await res.json();

    if (!res.ok || data.error) {
      const msg = data.error || 'Explanation failed';
      toastError(msg);
      return null;
    }

    aiExplainResult.set(data);
    return data;
  } catch {
    toastError('Failed to connect to AI service');
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
    const res = await fetch(`${API_BASE}/ai/suggest`);
    if (res.ok) {
      const data = await res.json();
      aiSuggestions.set(data.suggestions || []);
    }
  } catch {
    // non-fatal
  }
}
