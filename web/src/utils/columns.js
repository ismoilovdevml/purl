/**
 * Purl - Log table column defaults
 *
 * The log table's initial column layout, which is also what "Reset to
 * Default" in the column picker restores. Kept in one place so the two can
 * never drift apart.
 */

/**
 * @typedef {object} ColumnDef
 * @property {string} id - Column key (log field, or meta key when `meta`)
 * @property {string} label - Header text
 * @property {boolean} visible - Shown by default
 * @property {number | null} width - Pixel width; null = take remaining space
 * @property {number} minWidth - Resize floor in pixels
 * @property {'core' | 'kubernetes'} group - Section in the column picker
 * @property {boolean} pinned - Pinned to the left edge
 * @property {boolean} [meta] - Value comes from log.meta[id]
 */

/** @type {ReadonlyArray<Readonly<ColumnDef>>} */
export const DEFAULT_COLUMNS = Object.freeze([
  { id: 'time', label: 'Time', visible: true, width: 90, minWidth: 60, group: 'core', pinned: false },
  { id: 'level', label: 'Level', visible: true, width: 100, minWidth: 60, group: 'core', pinned: false },
  { id: 'service', label: 'Service', visible: true, width: 150, minWidth: 80, group: 'core', pinned: false },
  { id: 'host', label: 'Host', visible: false, width: 120, minWidth: 80, group: 'core', pinned: false },
  { id: 'namespace', label: 'Namespace', visible: false, width: 120, minWidth: 80, meta: true, group: 'kubernetes', pinned: false },
  { id: 'pod', label: 'Pod', visible: false, width: 180, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
  { id: 'node', label: 'Node', visible: false, width: 150, minWidth: 100, meta: true, group: 'kubernetes', pinned: false },
  { id: 'message', label: 'Message', visible: true, width: null, minWidth: 200, group: 'core', pinned: false },
].map((c) => Object.freeze(c)));

/**
 * A fresh, mutable copy of the default layout. Callers must use this rather
 * than DEFAULT_COLUMNS directly: both the table and the picker edit their
 * column objects in place (visibility, width, order).
 * @returns {ColumnDef[]}
 */
export function defaultColumns() {
  return DEFAULT_COLUMNS.map((c) => ({ ...c }));
}
