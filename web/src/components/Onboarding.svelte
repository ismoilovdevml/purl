<script>
    let { onDismiss } = $props();
</script>

<div class="onboarding">
    <div class="onboarding-card">
        <div class="onboarding-header">
            <h2>Welcome to Purl</h2>
            <p>Lightweight log aggregation — get started in 60 seconds</p>
        </div>

        <div class="steps">
            <div class="step">
                <div class="step-number">1</div>
                <div class="step-content">
                    <h3>Send your first log</h3>
                    <code class="code-block">curl -X POST http://localhost:3000/api/v1/logs \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '&#123;"level":"info","message":"Hello Purl!","service":"my-app"&#125;'</code>
                </div>
            </div>

            <div class="step">
                <div class="step-number">2</div>
                <div class="step-content">
                    <h3>Use Vector for production</h3>
                    <p>Add the Vector sidecar for automatic Docker log collection:</p>
                    <code class="code-block">docker compose --profile vector up -d</code>
                </div>
            </div>

            <div class="step">
                <div class="step-number">3</div>
                <div class="step-content">
                    <h3>Set up alerts</h3>
                    <p>Configure Telegram, Slack, or webhook alerts in Settings → Alerts</p>
                </div>
            </div>
        </div>

        <div class="onboarding-footer">
            <a href="https://github.com/ismoilovdevml/purl" target="_blank" rel="noopener" class="btn btn-secondary">Documentation</a>
            {#if onDismiss}
                <button class="btn btn-primary" onclick={onDismiss}>Got it, let's go!</button>
            {/if}
        </div>
    </div>
</div>

<style>
    .onboarding {
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 2rem;
        flex: 1;
    }

    .onboarding-card {
        background: #1e1e2e;
        border: 1px solid #333;
        border-radius: 12px;
        padding: 2rem;
        max-width: 700px;
        margin: auto;
    }

    .onboarding-header h2 {
        color: #e0e0e0;
        font-size: 1.5rem;
    }

    .onboarding-header p {
        color: #888;
    }

    .steps {
        display: flex;
        flex-direction: column;
        gap: 1.5rem;
        margin: 2rem 0;
    }

    .step {
        display: flex;
        gap: 1rem;
        align-items: flex-start;
    }

    .step-number {
        width: 32px;
        height: 32px;
        border-radius: 50%;
        background: #7c3aed;
        color: white;
        display: flex;
        align-items: center;
        justify-content: center;
        font-weight: bold;
        flex-shrink: 0;
    }

    .step-content h3 {
        color: #e0e0e0;
        margin-bottom: 0.5rem;
    }

    .step-content p {
        color: #aaa;
        font-size: 0.9rem;
    }

    .code-block {
        display: block;
        background: #0d0d14;
        padding: 12px;
        border-radius: 6px;
        font-family: monospace;
        font-size: 0.85rem;
        color: #a5d6ff;
        overflow-x: auto;
        white-space: pre-wrap;
        word-break: break-all;
        margin-top: 8px;
    }

    .btn {
        padding: 8px 16px;
        border-radius: 6px;
        cursor: pointer;
        font-size: 0.9rem;
        border: none;
    }

    .btn-primary {
        background: #7c3aed;
        color: white;
    }

    .btn-secondary {
        background: transparent;
        color: #7c3aed;
        border: 1px solid #7c3aed;
        text-decoration: none;
    }

    .onboarding-footer {
        display: flex;
        gap: 1rem;
        justify-content: center;
        margin-top: 1rem;
    }
</style>
