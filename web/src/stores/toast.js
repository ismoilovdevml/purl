import { writable, get } from 'svelte/store';

const toasts = writable([]);
let nextId = 0;
/** id -> pending auto-dismiss timeout */
const timers = new Map();

function scheduleRemoval(id, duration) {
  clearTimeout(timers.get(id));
  timers.delete(id);
  if (duration > 0) {
    timers.set(id, setTimeout(() => removeToast(id), duration));
  }
}

/**
 * Show a toast. The same message of the same type while it is still on screen
 * is not stacked again (#107: one outage used to stack "Failed to load
 * patterns" three times): the visible toast's `count` goes up and its
 * dismiss timer restarts.
 * @returns {number} the id of the toast now showing the message
 */
export function addToast(message, type = 'info', duration = 4000) {
  const existing = get(toasts).find((t) => t.message === message && t.type === type);
  if (existing) {
    toasts.update((list) => list.map((t) => (t.id === existing.id ? { ...t, count: t.count + 1 } : t)));
    scheduleRemoval(existing.id, duration);
    return existing.id;
  }

  const id = nextId++;
  toasts.update((list) => [...list, { id, message, type, duration, count: 1 }]);
  scheduleRemoval(id, duration);
  return id;
}

export function removeToast(id) {
  clearTimeout(timers.get(id));
  timers.delete(id);
  toasts.update(t => t.filter(toast => toast.id !== id));
}

export function success(message, duration = 4000) { return addToast(message, 'success', duration); }
export function error(message, duration = 6000) { return addToast(message, 'error', duration); }
export function warning(message, duration = 5000) { return addToast(message, 'warning', duration); }
export function info(message, duration = 4000) { return addToast(message, 'info', duration); }

export default toasts;
