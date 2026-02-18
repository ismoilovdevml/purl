import { writable } from 'svelte/store';

const toasts = writable([]);
let nextId = 0;

export function addToast(message, type = 'info', duration = 4000) {
  const id = nextId++;
  toasts.update(t => [...t, { id, message, type, duration }]);
  if (duration > 0) {
    setTimeout(() => removeToast(id), duration);
  }
  return id;
}

export function removeToast(id) {
  toasts.update(t => t.filter(toast => toast.id !== id));
}

export function success(message, duration = 4000) { return addToast(message, 'success', duration); }
export function error(message, duration = 6000) { return addToast(message, 'error', duration); }
export function warning(message, duration = 5000) { return addToast(message, 'warning', duration); }
export function info(message, duration = 4000) { return addToast(message, 'info', duration); }

export default toasts;
