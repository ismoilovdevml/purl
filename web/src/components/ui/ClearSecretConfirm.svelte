<!--
  ClearSecretConfirm Component
  The second half of the two-step guard around erasing a stored secret:
  <ClearSecretToggle> arms it, this asks before the save actually runs, naming
  every secret that is about to go. Deleting a credential is not undoable and
  Save is a button people click by reflex, so a ticked checkbox alone is not
  enough.

  Renders nothing while `request` is null, i.e. every save with no removal
  armed goes straight through — the dialog only appears for the destructive
  case.

  Usage:
  <ClearSecretConfirm bind:request={clearRequest} />
  ...
  clearRequest = { keys: ['telegram.bot_token'], run: () => saveNotification('telegram') };
-->
<script>
  import ConfirmDialog from './ConfirmDialog.svelte';
  import { clearConfirmTitle, clearConfirmMessage } from '../../utils/clearSecret.js';

  /**
   * Pending destructive save, or null.
   * @type {{ keys: string[], run: () => void } | null}
   */
  export let request = null;

  function handleConfirm() {
    const run = request?.run;
    // Cleared BEFORE running: `run` is async and re-entrant clicks on a still
    // open dialog would fire the same save twice.
    request = null;
    run?.();
  }

  function handleCancel() {
    request = null;
  }
</script>

<ConfirmDialog
  show={!!request}
  title={clearConfirmTitle(request?.keys)}
  message={clearConfirmMessage(request?.keys)}
  confirmText="Remove and save"
  cancelText="Keep it"
  variant="danger"
  onConfirm={handleConfirm}
  onCancel={handleCancel}
/>
