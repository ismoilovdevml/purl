/**
 * Purl - Top-level page routing policy
 *
 * The one list of hash routes the shell knows (`#logs`, `#traces`, ...) and
 * the rule for who may open each. The nav bar uses it to decide which tabs to
 * draw, and App uses the same rule when a URL hash or a click asks for a page,
 * so a hidden tab can never be reached by typing its hash.
 */

/**
 * @typedef {object} PageDef
 * @property {string} id - Hash route and page key
 * @property {string} label - Tab label / lazy-route display name
 * @property {boolean} [hiddenFromViewer] - Hidden from the `viewer` role
 * @property {boolean} [k8sOnly] - Only when the server runs in K8s mode
 */

/** @type {PageDef[]} Render order of the nav tabs. */
export const PAGES = [
  { id: 'logs', label: 'Logs' },
  { id: 'analytics', label: 'Analytics', hiddenFromViewer: true },
  { id: 'traces', label: 'Traces' },
  { id: 'k8s', label: 'K8s', k8sOnly: true },
  { id: 'query', label: 'Query' },
  { id: 'dashboards', label: 'Dashboards' },
  { id: 'settings', label: 'Settings', hiddenFromViewer: true },
];

/**
 * May the current user open this page?
 * @param {string} id - Page id
 * @param {{ role?: string } | null} user - Signed-in user (null when auth is off)
 * @param {boolean} k8sMode - Server K8s mode flag
 * @returns {boolean} false also for an unknown id
 */
export function canAccessPage(id, user, k8sMode) {
  const page = PAGES.find((p) => p.id === id);
  if (!page) return false;
  if (page.hiddenFromViewer && user?.role === 'viewer') return false;
  if (page.k8sOnly && !k8sMode) return false;
  return true;
}
