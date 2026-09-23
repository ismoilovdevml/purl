/**
 * Purl - DOM Utilities
 * HTML escaping, click outside, and other DOM helpers
 */

/**
 * Escape HTML to prevent XSS
 * @param {string} text - Text to escape
 * @returns {string} Escaped text
 */
export function escapeHtml(text) {
  if (!text) return '';
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

/**
 * Highlight search matches in text (XSS-safe)
 * @param {string} text - Text to search in
 * @param {string} query - Search query
 * @returns {string} HTML with highlighted matches
 */
export function highlightText(text, query) {
  if (!text) return '';
  // First escape HTML in the text
  let safeText = escapeHtml(text);

  // Then highlight search query if present
  if (query) {
    const safeQuery = escapeHtml(query);
    const escaped = safeQuery.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const regex = new RegExp(`(${escaped})`, 'gi');
    safeText = safeText.replace(regex, '<mark class="search-highlight">$1</mark>');
  }

  return safeText;
}

/**
 * Svelte action for click outside detection
 * Usage: <div use:clickOutside={handleClose}>
 * @param {HTMLElement} node - DOM node
 * @param {Function} callback - Function to call when clicked outside
 * @returns {object} Svelte action object
 */
export function clickOutside(node, callback) {
  const handleClick = (event) => {
    if (!node.contains(event.target)) {
      if (typeof callback === 'function') {
        callback();
      }
    }
  };

  document.addEventListener('click', handleClick, true);

  return {
    update(newCallback) {
      callback = newCallback;
    },
    destroy() {
      document.removeEventListener('click', handleClick, true);
    }
  };
}

/**
 * Copy text to clipboard
 * @param {string} text - Text to copy
 * @returns {Promise<boolean>} Success status
 */
export async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Fallback for older browsers
    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.style.position = 'fixed';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();
    try {
      document.execCommand('copy');
      return true;
    } catch {
      return false;
    } finally {
      document.body.removeChild(textarea);
    }
  }
}

/**
 * Debounce function
 * @param {Function} fn - Function to debounce
 * @param {number} delay - Delay in ms
 * @returns {Function} Debounced function
 */
export function debounce(fn, delay = 300) {
  let timeoutId;
  return (...args) => {
    clearTimeout(timeoutId);
    timeoutId = setTimeout(() => fn(...args), delay);
  };
}

/**
 * Event-handler wrapper that calls preventDefault() first — the Svelte 5
 * replacement for the removed `on:event|preventDefault` modifier.
 * @param {Function} [fn] - Handler to run after preventDefault
 * @returns {(event: Event) => void}
 */
export function preventDefault(fn) {
  return function (event) {
    event.preventDefault();
    fn?.call(this, event);
  };
}

/**
 * Event-handler wrapper that calls stopPropagation() first — the Svelte 5
 * replacement for the removed `on:event|stopPropagation` modifier.
 * @param {Function} [fn] - Handler to run after stopPropagation
 * @returns {(event: Event) => void}
 */
export function stopPropagation(fn) {
  return function (event) {
    event.stopPropagation();
    fn?.call(this, event);
  };
}

/**
 * Save a Blob to the user's disk under `filename` via a temporary <a download>.
 * @param {Blob} blob - Content to save
 * @param {string} filename - Suggested file name
 */
export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

/**
 * Svelte action: portal — moves element to document.body (or custom target).
 * Fixes modals rendered inside overflow containers where event handling breaks.
 * @param {HTMLElement} node - DOM node to teleport
 * @param {HTMLElement} [target=document.body] - Target container
 * @returns {object} Svelte action object
 */
export function portal(node, target = document.body) {
  target.appendChild(node);
  return {
    destroy() {
      if (node.parentNode) {
        node.parentNode.removeChild(node);
      }
    }
  };
}

/**
 * Svelte action: keep an absolutely positioned popup (dropdown menu, picker
 * panel) horizontally inside the viewport. The popup keeps its CSS anchoring
 * (e.g. `right: 0` under its trigger); when that would push it past either
 * edge — a trigger that wrapped to the left of a narrow header, or one flush
 * with the right edge — it is shifted back in with a translateX, and it is
 * never wider than the viewport. Re-measured on window resize and whenever
 * the popup's own size changes (e.g. the time picker swapping to its wider
 * custom-range form).
 *
 * Use on an element that exists only while open (`{#if open}`), so the first
 * measurement sees its real box.
 * Usage: <div class="dropdown" use:fitToViewport>
 * @param {HTMLElement} node - The popup element
 * @returns {object} Svelte action object
 */
export function fitToViewport(node) {
  const GUTTER = 8;
  node.style.maxWidth = `calc(100vw - ${GUTTER * 2}px)`;

  function place() {
    node.style.translate = '';
    const rect = node.getBoundingClientRect();
    if (rect.width === 0) return;
    const viewport = document.documentElement.clientWidth;
    let shift = 0;
    if (rect.right > viewport - GUTTER) shift = viewport - GUTTER - rect.right;
    if (rect.left + shift < GUTTER) shift = GUTTER - rect.left;
    if (shift !== 0) node.style.translate = `${Math.round(shift)}px 0`;
  }

  place();
  window.addEventListener('resize', place);
  // `translate` does not change the observed box size, so this cannot loop.
  const observer = typeof ResizeObserver === 'function' ? new ResizeObserver(place) : null;
  observer?.observe(node);

  return {
    destroy() {
      window.removeEventListener('resize', place);
      observer?.disconnect();
    },
  };
}

/** Selector for all focusable elements (excludes disabled) */
export const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/**
 * Trap focus within a container (for modals/dialogs).
 * Queries focusable elements dynamically on each Tab press so
 * dynamically added/removed content is handled correctly.
 * @param {HTMLElement} container - Container element
 * @returns {Function} Cleanup function
 */
/**
 * Reference-counted scroll lock for modals/dialogs.
 * Multiple modals can lock simultaneously; body overflow is
 * only restored when ALL locks are released.
 */
let scrollLockCount = 0;

export function lockScroll() {
  scrollLockCount++;
  if (scrollLockCount === 1) {
    document.body.style.overflow = 'hidden';
  }
}

export function unlockScroll() {
  scrollLockCount = Math.max(0, scrollLockCount - 1);
  if (scrollLockCount === 0) {
    document.body.style.overflow = '';
  }
}

export function trapFocus(container) {
  const getFocusable = () =>
    [...container.querySelectorAll(FOCUSABLE_SELECTOR)].filter(
      (el) => el.offsetParent !== null      // skip hidden elements
    );

  const handleKeydown = (e) => {
    if (e.key !== 'Tab') return;

    const focusable = getFocusable();
    if (focusable.length === 0) return;

    const first = focusable[0];
    const last = focusable[focusable.length - 1];

    if (e.shiftKey) {
      if (document.activeElement === first) {
        e.preventDefault();
        last.focus();
      }
    } else {
      if (document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    }
  };

  container.addEventListener('keydown', handleKeydown);

  return () => {
    container.removeEventListener('keydown', handleKeydown);
  };
}
