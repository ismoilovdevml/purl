/**
 * Audit log presentation helpers shared by the audit settings components.
 */

/**
 * CSS modifier class for an audit action: destructive actions are red,
 * creations/logins green, updates amber, everything else neutral ('').
 *
 * @param {string} action - Audit action name, e.g. 'delete_user'
 * @returns {'action-danger'|'action-success'|'action-warning'|''}
 */
export function actionColor(action) {
  if (!action) return '';
  if (action.startsWith('delete') || action === 'revoke') return 'action-danger';
  if (action.startsWith('create') || action === 'login') return 'action-success';
  if (action.startsWith('update') || action === 'change_password') return 'action-warning';
  return '';
}
