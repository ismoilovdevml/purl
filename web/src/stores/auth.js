import { writable, get } from 'svelte/store';

const API_BASE = '/api';

export const currentUser = writable(null);
export const authLoading = writable(true);

export async function checkAuth() {
  authLoading.set(true);
  try {
    const res = await fetch(`${API_BASE}/auth/me`);
    if (res.ok) {
      const data = await res.json();
      if (data.authenticated) {
        currentUser.set({ username: data.username });
      } else {
        currentUser.set(null);
      }
    } else {
      currentUser.set(null);
    }
  } catch {
    currentUser.set(null);
  } finally {
    authLoading.set(false);
  }
}

export async function login(username, password) {
  const res = await fetch(`${API_BASE}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password })
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Login failed');
  currentUser.set({ username: data.username });
  return data;
}

export async function logout() {
  await fetch(`${API_BASE}/auth/logout`, { method: 'POST' });
  currentUser.set(null);
}

export function isAuthenticated() {
  return get(currentUser) !== null;
}
