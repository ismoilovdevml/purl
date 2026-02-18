<script>
    import { copyToClipboard } from '../utils/dom.js';
    import { success, error as toastError } from '../stores/toast.js';

    let { onDismiss } = $props();

    let sendingLogs = $state(false);
    let copiedField = $state(null);
    let copiedTimeout = null;

    const curlCommand = `curl -X POST http://localhost:3000/api/v1/logs \\
  -H "Content-Type: application/json" \\
  -H "Authorization: Bearer YOUR_API_KEY" \\
  -d '{"level":"info","message":"Hello Purl!","service":"my-app"}'`;

    const vectorCommand = 'docker compose --profile vector up -d';

    function handleCopy(text, fieldId) {
        copyToClipboard(text);
        if (copiedTimeout) clearTimeout(copiedTimeout);
        copiedField = fieldId;
        copiedTimeout = setTimeout(() => {
            copiedField = null;
        }, 1500);
    }

    const sampleLogs = [
        {'level': 'info', 'message': 'Application started successfully', 'service': 'web-api', 'host': 'prod-1'},
        {'level': 'info', 'message': 'Connected to database', 'service': 'web-api', 'host': 'prod-1'},
        {'level': 'debug', 'message': 'Cache initialized with 256MB', 'service': 'web-api', 'host': 'prod-1'},
        {'level': 'info', 'message': 'HTTP server listening on :8080', 'service': 'web-api', 'host': 'prod-1'},
        {'level': 'warn', 'message': 'Slow query detected: SELECT * FROM users took 2.3s', 'service': 'web-api', 'host': 'prod-1'},
        {'level': 'error', 'message': 'Failed to connect to Redis: Connection refused', 'service': 'auth-service', 'host': 'prod-2'},
        {'level': 'info', 'message': 'Retry attempt 1/3 for Redis connection', 'service': 'auth-service', 'host': 'prod-2'},
        {'level': 'info', 'message': 'Redis connection established', 'service': 'auth-service', 'host': 'prod-2'},
        {'level': 'info', 'message': 'User login: user@example.com from 192.168.1.100', 'service': 'auth-service', 'host': 'prod-2'},
        {'level': 'warn', 'message': 'Rate limit approaching: 85% of 1000 req/min', 'service': 'gateway', 'host': 'prod-3'},
        {'level': 'error', 'message': 'Payment processing failed: timeout after 30s', 'service': 'payment-service', 'host': 'prod-2'},
        {'level': 'info', 'message': 'Order #12345 created successfully', 'service': 'order-service', 'host': 'prod-1'},
        {'level': 'debug', 'message': 'Sending email notification to user@example.com', 'service': 'notification-service', 'host': 'prod-3'},
        {'level': 'info', 'message': 'Health check passed: all services operational', 'service': 'monitoring', 'host': 'prod-1'},
        {'level': 'warn', 'message': 'Disk usage at 78% on /var/log', 'service': 'monitoring', 'host': 'prod-3'},
        {'level': 'error', 'message': 'TLS certificate expires in 7 days', 'service': 'gateway', 'host': 'prod-3'},
        {'level': 'info', 'message': 'Deploying version v2.4.1', 'service': 'deploy-bot', 'host': 'prod-1'},
        {'level': 'info', 'message': 'Rolling update: 3/5 pods updated', 'service': 'deploy-bot', 'host': 'prod-1'},
        {'level': 'info', 'message': 'Deployment complete: v2.4.1 is live', 'service': 'deploy-bot', 'host': 'prod-1'},
        {'level': 'fatal', 'message': 'Out of memory: process killed by OOM killer', 'service': 'worker', 'host': 'prod-2'}
    ];

    async function sendSampleLogs() {
        sendingLogs = true;
        try {
            const res = await fetch('/api/v1/logs', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(sampleLogs)
            });

            if (res.ok) {
                success('Sample logs sent successfully! Refreshing...');
                setTimeout(() => {
                    if (onDismiss) onDismiss();
                }, 1200);
            } else if (res.status === 401 || res.status === 403) {
                toastError('Authentication required. Configure PURL_API_KEYS in your .env file first.');
            } else {
                const data = await res.json().catch(() => ({}));
                toastError(data.error || `Failed to send sample logs (${res.status})`);
            }
        } catch {
            toastError('Could not reach the server. Make sure Purl is running.');
        } finally {
            sendingLogs = false;
        }
    }
</script>

<div class="onboarding">
    <div class="onboarding-card">
        <div class="onboarding-header">
            <h2>Welcome to Purl</h2>
            <p>Lightweight log aggregation -- get started in 60 seconds</p>
        </div>

        <div class="steps">
            <div class="step">
                <div class="step-number">1</div>
                <div class="step-content">
                    <h3>Send your first log</h3>
                    <p>Use curl or any HTTP client to send a JSON log entry to the Purl ingest API.</p>
                    <div class="code-wrapper">
                        <code class="code-block">{curlCommand}</code>
                        <button
                            class="copy-btn"
                            class:copied={copiedField === 'curl'}
                            onclick={() => handleCopy(curlCommand, 'curl')}
                            title="Copy to clipboard"
                        >
                            {#if copiedField === 'curl'}
                                <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
                                    <path d="M3 8l3 3 7-7" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                                </svg>
                                <span>Copied!</span>
                            {:else}
                                <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
                                    <rect x="5" y="5" width="9" height="9" rx="1.5" stroke="currentColor" stroke-width="1.5"/>
                                    <path d="M11 5V3.5A1.5 1.5 0 009.5 2h-6A1.5 1.5 0 002 3.5v6A1.5 1.5 0 003.5 11H5" stroke="currentColor" stroke-width="1.5"/>
                                </svg>
                                <span>Copy</span>
                            {/if}
                        </button>
                    </div>
                </div>
            </div>

            <div class="step">
                <div class="step-number">2</div>
                <div class="step-content">
                    <h3>Collect logs automatically</h3>
                    <p>Enable the Vector sidecar to automatically collect and forward Docker container logs to Purl.</p>
                    <div class="code-wrapper">
                        <code class="code-block">{vectorCommand}</code>
                        <button
                            class="copy-btn"
                            class:copied={copiedField === 'vector'}
                            onclick={() => handleCopy(vectorCommand, 'vector')}
                            title="Copy to clipboard"
                        >
                            {#if copiedField === 'vector'}
                                <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
                                    <path d="M3 8l3 3 7-7" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
                                </svg>
                                <span>Copied!</span>
                            {:else}
                                <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
                                    <rect x="5" y="5" width="9" height="9" rx="1.5" stroke="currentColor" stroke-width="1.5"/>
                                    <path d="M11 5V3.5A1.5 1.5 0 009.5 2h-6A1.5 1.5 0 002 3.5v6A1.5 1.5 0 003.5 11H5" stroke="currentColor" stroke-width="1.5"/>
                                </svg>
                                <span>Copy</span>
                            {/if}
                        </button>
                    </div>
                </div>
            </div>

            <div class="step">
                <div class="step-number">3</div>
                <div class="step-content">
                    <h3>Set up alerts</h3>
                    <p>Get notified when things go wrong. Configure Telegram, Slack, or webhook alerts in Settings.</p>
                </div>
            </div>
        </div>

        <div class="onboarding-footer">
            <button class="btn btn-sample" onclick={sendSampleLogs} disabled={sendingLogs}>
                {#if sendingLogs}
                    <span class="spinner"></span>
                    Sending...
                {:else}
                    <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                        <path d="M2 3l12 5-12 5V9l8-1-8-1V3z" fill="currentColor"/>
                    </svg>
                    Send Sample Logs
                {/if}
            </button>
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
        margin-bottom: 0.5rem;
        line-height: 1.4;
    }

    .code-wrapper {
        position: relative;
    }

    .code-block {
        display: block;
        background: #0d0d14;
        padding: 12px;
        padding-right: 80px;
        border-radius: 6px;
        font-family: monospace;
        font-size: 0.85rem;
        color: #a5d6ff;
        overflow-x: auto;
        white-space: pre-wrap;
        word-break: break-all;
        margin-top: 4px;
    }

    .copy-btn {
        position: absolute;
        top: 8px;
        right: 8px;
        display: flex;
        align-items: center;
        gap: 4px;
        padding: 4px 8px;
        background: rgba(255, 255, 255, 0.08);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 4px;
        color: #8b949e;
        font-size: 11px;
        cursor: pointer;
        transition: all 0.15s ease;
    }

    .copy-btn:hover {
        background: rgba(255, 255, 255, 0.15);
        color: #c9d1d9;
    }

    .copy-btn.copied {
        color: #3fb950;
        border-color: rgba(63, 185, 80, 0.3);
        background: rgba(63, 185, 80, 0.1);
    }

    .btn {
        padding: 8px 16px;
        border-radius: 6px;
        cursor: pointer;
        font-size: 0.9rem;
        border: none;
        display: inline-flex;
        align-items: center;
        gap: 6px;
        transition: all 0.15s ease;
    }

    .btn:disabled {
        opacity: 0.6;
        cursor: not-allowed;
    }

    .btn-primary {
        background: #7c3aed;
        color: white;
    }

    .btn-primary:hover:not(:disabled) {
        background: #6d28d9;
    }

    .btn-secondary {
        background: transparent;
        color: #7c3aed;
        border: 1px solid #7c3aed;
        text-decoration: none;
    }

    .btn-secondary:hover {
        background: rgba(124, 58, 237, 0.1);
    }

    .btn-sample {
        background: #238636;
        color: white;
    }

    .btn-sample:hover:not(:disabled) {
        background: #2ea043;
    }

    .spinner {
        width: 14px;
        height: 14px;
        border: 2px solid rgba(255, 255, 255, 0.3);
        border-top-color: white;
        border-radius: 50%;
        animation: spin 0.8s linear infinite;
        flex-shrink: 0;
    }

    @keyframes spin {
        to {
            transform: rotate(360deg);
        }
    }

    .onboarding-footer {
        display: flex;
        gap: 1rem;
        justify-content: center;
        margin-top: 1rem;
        flex-wrap: wrap;
    }
</style>
