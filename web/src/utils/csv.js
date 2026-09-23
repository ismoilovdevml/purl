/**
 * Purl - CSV export
 * The one RFC 4180 CSV builder every log export goes through, so "Export CSV"
 * (toolbar) and "Export selected" (log table) produce the same file for the
 * same rows.
 */

import { downloadBlob } from './dom.js';

/** Fixed leading columns of a log export; meta.* columns follow, sorted. */
export const LOG_CSV_COLUMNS = ['timestamp', 'level', 'service', 'host', 'message'];

/**
 * First characters a spreadsheet reads as the start of a formula. Log lines
 * are attacker-controlled, so a cell starting with one of these would run as
 * a formula (=HYPERLINK(...), =cmd|...) when the export is opened.
 */
const FORMULA_START = /^[=+\-@\t\r]/;

/**
 * Encode one CSV field (RFC 4180): a value containing a double quote, comma,
 * CR or LF is wrapped in double quotes with inner quotes doubled; anything
 * else is written as-is. null/undefined become an empty field and objects are
 * written as JSON.
 *
 * A value starting with = + - @ TAB or CR gets a leading single quote (OWASP
 * CSV injection guidance) so spreadsheets show it as text; the value is not
 * otherwise changed.
 * @param {unknown} value - Field value
 * @returns {string} Encoded field
 */
export function csvField(value) {
  if (value === null || value === undefined) return '';
  let text = typeof value === 'object' ? JSON.stringify(value) : String(value);
  if (FORMULA_START.test(text)) text = `'${text}`;
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

/**
 * Build a CSV document: a header record then one record per row, records
 * separated by CRLF (RFC 4180).
 * @param {string[]} headers - Header names
 * @param {unknown[][]} rows - Records, each the same length as headers
 * @returns {string} CSV text
 */
export function buildCsv(headers, rows) {
  return [headers, ...rows].map((record) => record.map(csvField).join(',')).join('\r\n');
}

/**
 * The meta object of a log row. searchLogs() pre-parses it into `parsedMeta`;
 * rows from elsewhere may still carry `meta` as a JSON string.
 * @param {Record<string, any>} log - Log row
 * @returns {Record<string, any>} Meta fields ({} when none or unparsable)
 */
function logMeta(log) {
  if (log.parsedMeta && typeof log.parsedMeta === 'object') return log.parsedMeta;
  if (log.meta && typeof log.meta === 'object') return log.meta;
  if (typeof log.meta === 'string' && log.meta) {
    try {
      const parsed = JSON.parse(log.meta);
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }
  return {};
}

/**
 * CSV for a set of log rows: the fixed LOG_CSV_COLUMNS, then one `meta.<key>`
 * column per meta key found in any row (sorted).
 * @param {Array<Record<string, any>>} logs - Log rows
 * @returns {string} CSV text
 */
export function logsToCsv(logs) {
  const metas = logs.map(logMeta);
  const metaKeys = [...new Set(metas.flatMap((m) => Object.keys(m)))].sort();
  const headers = [...LOG_CSV_COLUMNS, ...metaKeys.map((k) => `meta.${k}`)];
  const rows = logs.map((log, i) => [
    ...LOG_CSV_COLUMNS.map((col) => log[col]),
    ...metaKeys.map((k) => metas[i][k]),
  ]);
  return buildCsv(headers, rows);
}

/**
 * Save log rows as a CSV download named `<prefix>-<epoch ms>.csv`.
 * @param {Array<Record<string, any>>} logs - Log rows
 * @param {string} prefix - File name prefix
 */
export function downloadLogsCsv(logs, prefix) {
  const blob = new Blob([logsToCsv(logs)], { type: 'text/csv;charset=utf-8;' });
  downloadBlob(blob, `${prefix}-${Date.now()}.csv`);
}
