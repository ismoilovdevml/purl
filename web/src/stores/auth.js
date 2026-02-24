import { writable, get } from 'svelte/store';

const API_BASE = '/api';

export const currentUser = writable(null);
export const authLoading = writable(true);
export const passwordChangeRequired = writable(false);

export async function checkAuth() {
  authLoading.set(true);
  try {
    const res = await fetch(`${API_BASE}/auth/me`);
    if (res.ok) {
      const data = await res.json();
      if (data.authenticated) {
        if (data.must_change_password) {
          passwordChangeRequired.set(true);
        }
        currentUser.set({ username: data.username, role: data.role || 'viewer' });
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
  // Set passwordChangeRequired BEFORE currentUser to avoid a brief render
  // of the main app (which would fire API calls that get 403'd)
  if (data.password_change_required) {
    passwordChangeRequired.set(true);
  }
  currentUser.set({ username: data.username, role: data.role || 'viewer' });
  return data;
}

export async function changePassword(currentPassword, newPassword) {
  const res = await fetch(`${API_BASE}/auth/change-password`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ current_password: currentPassword, new_password: newPassword })
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Password change failed');
  passwordChangeRequired.set(false);
  return data;
}

export async function logout() {
  await fetch(`${API_BASE}/auth/logout`, { method: 'POST' });
  currentUser.set(null);
}

export function isAuthenticated() {
  return get(currentUser) !== null;
}

export function isAdmin() {
  const user = get(currentUser);
  return user?.role === 'admin';
}

export function hasRole(...roles) {
  const user = get(currentUser);
  if (!user) return false;
  if (user.role === 'admin') return true;
  return roles.includes(user.role);
}
