import { writable, get } from 'svelte/store';
import { api, resetCsrfToken } from '../utils/api.js';

export const currentUser = writable(null);
export const authLoading = writable(true);
export const passwordChangeRequired = writable(false);

export async function checkAuth() {
  authLoading.set(true);
  try {
    const data = await api.get('/auth/me');
    if (data?.authenticated) {
      if (data.must_change_password) {
        passwordChangeRequired.set(true);
      }
      currentUser.set({ username: data.username, role: data.role || 'viewer' });
    } else {
      currentUser.set(null);
    }
  } catch {
    // Any failure here (401, network error, malformed body) means "not signed in".
    currentUser.set(null);
  } finally {
    authLoading.set(false);
  }
}

export async function login(username, password) {
  // Throws ApiError with the server's message on failure - same contract as
  // the old `throw new Error(data.error || 'Login failed')`.
  const data = await api.post('/auth/login', { username, password });

  // A new session invalidates any CSRF token minted for the previous one.
  resetCsrfToken();

  // Set passwordChangeRequired BEFORE currentUser to avoid a brief render
  // of the main app (which would fire API calls that get 403'd)
  if (data.password_change_required) {
    passwordChangeRequired.set(true);
  }
  currentUser.set({ username: data.username, role: data.role || 'viewer' });
  return data;
}

export async function changePassword(currentPassword, newPassword) {
  const data = await api.post('/auth/change-password', {
    current_password: currentPassword,
    new_password: newPassword,
  });
  passwordChangeRequired.set(false);
  return data;
}

export async function logout() {
  try {
    await api.post('/auth/logout');
  } catch {
    // Already signed out server-side, or the server is unreachable. Either way
    // we still tear down the local session - never trap the user in a
    // logged-in-looking UI they cannot escape.
  } finally {
    resetCsrfToken();
    currentUser.set(null);
  }
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
