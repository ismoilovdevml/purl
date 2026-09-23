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
 * panel) inside the viewport. The popup keeps its CSS anchoring (e.g.
 * `right: 0` under its trigger); when that would push it past either edge —
 * a trigger that wrapped to the left of a narrow header, or one flush with the
 * right edge — it is shifted back in with a translateX, and it is never wider
 * than the viewport. Re-measured on window resize and whenever the popup's own
 * size changes (e.g. the time picker swapping to its wider custom-range form).
 *
 * With `{ vertical: true }` it also keeps a popup that drops down from its
 * trigger (the popup's parent) from running off the bottom. The popup is then
 * positioned `fixed` against the trigger — so a clipping ancestor
 * (`overflow: hidden`) cannot cut it off — opens upward when there is more
 * room above than below, and gets a max-height from the room it has. It must
 * scroll internally (a scrollable child with `min-height: 0`, or
 * `overflow-y: auto` on itself). It follows the trigger on scroll.
 *
 * Use on an element that exists only while open (`{#if open}`), so the first
 * measurement sees its real box.
 * Usage: <div class="dropdown" use:fitToViewport>
 *        <div class="panel" use:fitToViewport={{ vertical: true }}>
 * @param {HTMLElement} node - The popup element
 * @param {{ vertical?: boolean }} [options]
 * @returns {object} Svelte action object
 */
export function fitToViewport(node, options = {}) {
  const GUTTER = 8;
  const vertical = options.vertical === true;
  node.style.maxWidth = `calc(100vw - ${GUTTER * 2}px)`;

  // Read once, before this action overrides them: the popup's own CSS cap and
  // its gap from the trigger.
  const cssStyle = getComputedStyle(node);
  const cssMaxHeight = parseFloat(cssStyle.maxHeight); // NaN for 'none'
  const gap = parseFloat(cssStyle.marginTop) || 0;

  function placeVertically() {
    const trigger = node.parentElement.getBoundingClientRect();
    const viewport = document.documentElement.clientHeight;
    node.style.position = 'fixed';
    node.style.margin = '0';
    node.style.left = `${Math.round(trigger.left)}px`;
    node.style.right = 'auto';
    node.style.maxHeight = Number.isNaN(cssMaxHeight) ? '' : `${cssMaxHeight}px`;

    const height = node.getBoundingClientRect().height;
    const below = viewport - GUTTER - (trigger.bottom + gap);
    const above = trigger.top - gap - GUTTER;
    const up = height > below && above > below;
    if (up) {
      node.style.top = 'auto';
      node.style.bottom = `${Math.round(viewport - trigger.top + gap)}px`;
    } else {
      node.style.top = `${Math.round(trigger.bottom + gap)}px`;
      node.style.bottom = 'auto';
    }
    const room = Math.max(0, Math.floor(up ? above : below));
    if (height > room) {
      node.style.maxHeight = `${Number.isNaN(cssMaxHeight) ? room : Math.min(cssMaxHeight, room)}px`;
    }
  }

  function placeHorizontally() {
    node.style.translate = '';
    const rect = node.getBoundingClientRect();
    if (rect.width === 0) return;
    const viewport = document.documentElement.clientWidth;
    let shift = 0;
    if (rect.right > viewport - GUTTER) shift = viewport - GUTTER - rect.right;
    if (rect.left + shift < GUTTER) shift = GUTTER - rect.left;
    if (shift !== 0) node.style.translate = `${Math.round(shift)}px 0`;
  }

  function place() {
    if (vertical) placeVertically();
    placeHorizontally();
  }

  place();
  window.addEventListener('resize', place);
  // A fixed popup does not move with its trigger; any scrolling ancestor does.
  // Scrolling inside the popup itself must not re-place it: re-measuring
  // resets its max-height, which would clamp the list's own scroll position.
  // At most one re-place per frame: scroll events fire far more often.
  let frame = 0;
  const onScroll = (event) => {
    if (event.target instanceof Node && node.contains(event.target)) return;
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      place();
    });
  };
  if (vertical) window.addEventListener('scroll', onScroll, true);
  // `translate` does not change the observed box size, and max-height only
  // settles towards the room available, so this cannot loop.
  const observer = typeof ResizeObserver === 'function' ? new ResizeObserver(place) : null;
  observer?.observe(node);

  return {
    destroy() {
      window.removeEventListener('resize', place);
      if (vertical) window.removeEventListener('scroll', onScroll, true);
      if (frame) cancelAnimationFrame(frame);
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
