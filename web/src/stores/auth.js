import { writable, get } from 'svelte/store';
import { api, resetCsrfToken } from '../utils/api.js';

/**
 * Dashboard session state.
 *
 * Boot is modelled as an explicit state machine rather than a pair of
 * booleans, because the questions the shell must answer before it can paint
 * anything are genuinely ordered:
 *
 *   'checking'      GET /auth/me is in flight — paint neither the dashboard
 *                   nor the login form yet
 *   'authenticated' a valid dashboard session exists
 *   'anonymous'     no session: either signed out, or auth is off entirely
 *
 * Whether "anonymous" should show the login form is a SEPARATE question,
 * answered by `serverRequiresAuth` below. Conflating the two is what left
 * users stranded in a dashboard shell that 401'd on every request.
 */
export const AUTH_CHECKING = 'checking';
export const AUTH_AUTHENTICATED = 'authenticated';
export const AUTH_ANONYMOUS = 'anonymous';

export const authState = writable(AUTH_CHECKING);
export const currentUser = writable(null);
export const passwordChangeRequired = writable(false);

/**
 * Does this deployment demand a dashboard session at all?
 *
 *   null   not established yet — the caller must assume credentials are needed
 *   true   the server rejected an unauthenticated request, or we have held a
 *          session, so credentials are definitely required
 *   false  the server explicitly reported that auth is off
 */
export const serverRequiresAuth = writable(null);

/**
 * Is this Purl instance running inside Kubernetes? Reported by the public
 * GET /auth/me as `k8s_mode`; drives the K8s page and the K8s-only alert and
 * settings UI. Defaults to false until the server says otherwise.
 */
export const k8sMode = writable(false);

export async function checkAuth() {
  authState.set(AUTH_CHECKING);
  try {
    const data = await api.get('/auth/me');

    if (data?.auth_required !== undefined && data?.auth_required !== null) {
      serverRequiresAuth.set(Boolean(data.auth_required));
    }
    k8sMode.set(Boolean(data?.k8s_mode));

    if (data?.authenticated) {
      if (data.must_change_password) {
        passwordChangeRequired.set(true);
      }
      currentUser.set({ username: data.username, role: data.role || 'viewer' });
      // We are holding a session, so this instance definitely has auth on.
      serverRequiresAuth.set(true);
      authState.set(AUTH_AUTHENTICATED);
    } else {
      currentUser.set(null);
      authState.set(AUTH_ANONYMOUS);
    }
  } catch {
    // Any failure here (network error, malformed body) means "not signed in".
    currentUser.set(null);
    authState.set(AUTH_ANONYMOUS);
  }
}

export async function login(username, password) {
  // Throws ApiError with the server's message on failure - same contract as
  // the old `throw new Error(data.error || 'Login failed')`.
  const data = await api.post('/auth/login', { username, password });

  // A new session invalidates any CSRF token minted for the previous one.
  resetCsrfToken();

  // Credentials were accepted, so this instance has auth on. Remember it for
  // the rest of the tab's life, including across a later sign-out.
  serverRequiresAuth.set(true);

  // Set passwordChangeRequired BEFORE currentUser to avoid a brief render
  // of the main app (which would fire API calls that get 403'd)
  if (data.password_change_required) {
    passwordChangeRequired.set(true);
  }
  currentUser.set({ username: data.username, role: data.role || 'viewer' });
  authState.set(AUTH_AUTHENTICATED);
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
    clearSession();
  }
}

/**
 * Drop every trace of the local session and land in the 'anonymous' state.
 *
 * Deliberately unconditional: it runs even when `currentUser` is already null.
 * That is exactly the reload-after-sign-out case — the store starts null there,
 * so a guarded version does nothing and the shell never routes back to the
 * login form.
 *
 * @returns {boolean} whether a live session was actually torn down, so the
 *   caller can raise exactly one "session expired" toast and stay silent for
 *   the pre-auth requests the login page itself makes.
 */
export function clearSession() {
  const hadSession = get(currentUser) !== null;
  currentUser.set(null);
  passwordChangeRequired.set(false);
  authState.set(AUTH_ANONYMOUS);
  return hadSession;
}

/** The server refused an unauthenticated request: credentials are required. */
export function markAuthRequired() {
  serverRequiresAuth.set(true);
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
