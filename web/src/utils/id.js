/**
 * Client-side ids for records the server sent without one.
 *
 * Used as {#each} keys, and Svelte throws each_key_duplicate (in production
 * builds too) when two keys collide, so these must be unique per page load.
 * The time + random parts also keep an id unique after it is persisted (a
 * dashboard widget) and read back in a later session, where the counter has
 * restarted.
 *
 * Deliberately not crypto.randomUUID(): that only exists in secure contexts,
 * and Purl is commonly served over plain HTTP on an internal address.
 */
let counter = 0;

/**
 * @param {string} prefix - readable namespace, e.g. 'live' or 'widget'
 * @returns {string}
 */
export function uniqueId(prefix) {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter.toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}
