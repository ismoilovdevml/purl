<script>
    import Icon from './ui/Icon.svelte';
    import { close } from './ui/icons.js';

    let { onClose } = $props();

    function handleKeydown(e) {
        if (e.key === 'Escape') onClose();
    }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="modal-backdrop" onclick={onClose} onkeydown={(e) => { if (e.key === 'Escape') onClose(); }} role="dialog" aria-modal="true" aria-label="Search syntax guide" tabindex="-1">
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="modal-content" onclick={(e) => e.stopPropagation()} onkeydown={(e) => e.stopPropagation()}>
        <div class="modal-header">
            <h2>Search Syntax Guide</h2>
            <button class="close-btn" onclick={onClose} aria-label="Close">
                <Icon icon={close} size={14} strokeWidth={3} />
            </button>
        </div>

        <div class="modal-body">
            <section>
                <h3>Basic Search</h3>
                <table class="syntax-table"><tbody>
                    <tr><td><code>error</code></td><td>Free text search across all fields</td></tr>
                    <tr><td><code>"exact phrase"</code></td><td>Match exact phrase</td></tr>
                </tbody></table>
            </section>

            <section>
                <h3>Field Queries</h3>
                <table class="syntax-table"><tbody>
                    <tr><td><code>level:error</code></td><td>Exact field match</td></tr>
                    <tr><td><code>service:api-*</code></td><td>Wildcard match</td></tr>
                    <tr><td><code>status:&gt;=400</code></td><td>Numeric comparison</td></tr>
                    <tr><td><code>message:"connection refused"</code></td><td>Field phrase match</td></tr>
                </tbody></table>
            </section>

            <section>
                <h3>Logical Operators</h3>
                <table class="syntax-table"><tbody>
                    <tr><td><code>error AND service:api</code></td><td>Both conditions must match</td></tr>
                    <tr><td><code>error OR warning</code></td><td>Either condition matches</td></tr>
                    <tr><td><code>NOT level:debug</code></td><td>Exclude matches</td></tr>
                    <tr><td><code>level:(error OR warning)</code></td><td>Field with multiple values</td></tr>
                </tbody></table>
            </section>

            <section>
                <h3>Time Ranges</h3>
                <table class="syntax-table"><tbody>
                    <tr><td><code>15m</code></td><td>Last 15 minutes</td></tr>
                    <tr><td><code>1h</code></td><td>Last hour</td></tr>
                    <tr><td><code>24h</code></td><td>Last 24 hours</td></tr>
                    <tr><td><code>7d</code></td><td>Last 7 days</td></tr>
                </tbody></table>
            </section>

            <section>
                <h3>Examples</h3>
                <table class="syntax-table"><tbody>
                    <tr><td><code>level:error AND service:payment</code></td><td>Payment service errors</td></tr>
                    <tr><td><code>status:&gt;=500 NOT path:/health</code></td><td>Server errors excluding health checks</td></tr>
                    <tr><td><code>"timeout" AND service:api-*</code></td><td>Timeout issues in API services</td></tr>
                </tbody></table>
            </section>
        </div>
    </div>
</div>

<style>
    .modal-backdrop {
        position: fixed;
        inset: 0;
        background: rgba(0, 0, 0, 0.7);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 1000;
    }

    .modal-content {
        background: #1e1e2e;
        border: 1px solid #333;
        border-radius: 12px;
        padding: 0;
        max-width: 650px;
        width: 90%;
        max-height: 80vh;
        overflow-y: auto;
    }

    .modal-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 1rem 1.5rem;
        border-bottom: 1px solid #333;
    }

    .modal-header h2 {
        color: #e0e0e0;
        font-size: 1.2rem;
        margin: 0;
    }

    .close-btn {
        display: flex;
        align-items: center;
        justify-content: center;
        background: none;
        border: none;
        color: #888;
        cursor: pointer;
        padding: 6px;
        border-radius: 4px;
    }

    .close-btn:hover {
        color: #e0e0e0;
    }

    .modal-body {
        padding: 1.5rem;
    }

    .modal-body section {
        margin-bottom: 1.5rem;
    }

    .modal-body h3 {
        color: #7c3aed;
        font-size: 0.95rem;
        margin-bottom: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.5px;
    }

    .syntax-table {
        width: 100%;
        border-collapse: collapse;
    }

    .syntax-table td {
        padding: 6px 12px;
        border-bottom: 1px solid #2a2a3a;
        color: #ccc;
        font-size: 0.85rem;
    }

    .syntax-table td:first-child {
        white-space: nowrap;
    }

    .syntax-table code {
        background: #0d0d14;
        padding: 2px 6px;
        border-radius: 3px;
        color: #a5d6ff;
        font-size: 0.85rem;
    }
</style>
