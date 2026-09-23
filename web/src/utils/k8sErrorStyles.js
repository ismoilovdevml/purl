/**
 * Colour styling for K8s pod error types on the K8s Pod Health page, shared
 * by its summary cards (PodHealthStats) and the pods table
 * (UnhealthyPodsTable).
 *
 * PodStatusPanel keeps its own, different palette (it also maps Badge
 * variants), so it does not use this map.
 */

const ERROR_STYLES = {
  'CrashLoopBackOff': { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
  'OOMKilled':        { color: '#f0883e', bg: 'rgba(240, 136, 62, 0.15)', border: 'rgba(240, 136, 62, 0.4)' },
  'ImagePullBackOff': { color: '#d29922', bg: 'rgba(210, 153, 34, 0.15)', border: 'rgba(210, 153, 34, 0.4)' },
  'ErrImagePull':     { color: '#d29922', bg: 'rgba(210, 153, 34, 0.15)', border: 'rgba(210, 153, 34, 0.4)' },
  'Evicted':          { color: '#f0883e', bg: 'rgba(240, 136, 62, 0.15)', border: 'rgba(240, 136, 62, 0.4)' },
  'NodeNotReady':     { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
  'Pending':          { color: '#d29922', bg: 'rgba(210, 153, 34, 0.15)', border: 'rgba(210, 153, 34, 0.4)' },
  'CreateContainerError': { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
  'RunContainerError': { color: '#f85149', bg: 'rgba(248, 81, 73, 0.15)', border: 'rgba(248, 81, 73, 0.4)' },
};

const DEFAULT_STYLE = { color: '#8b949e', bg: 'rgba(139, 148, 158, 0.15)', border: 'rgba(139, 148, 158, 0.4)' };

/**
 * @param {string} errorType - e.g. 'CrashLoopBackOff'
 * @returns {{ color: string, bg: string, border: string }} Style for the type (grey when unknown)
 */
export function getErrorStyle(errorType) {
  return ERROR_STYLES[errorType] || DEFAULT_STYLE;
}
