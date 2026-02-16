<!--
  LicenseSettings Component
  License plan info and key management

  Usage:
  <LicenseSettings />
-->
<script>
  import { onMount } from 'svelte';
  import Card from '../ui/Card.svelte';
  import Badge from '../ui/Badge.svelte';
  import Button from '../ui/Button.svelte';
  import Input from '../ui/Input.svelte';
  import { licenseInfo, licenseLoading, licenseError, currentPlan, isFreePlan, fetchLicense, saveLicenseKey } from '../../stores/license.js';

  let licenseKey = '';
  let saving = false;
  let saveError = '';
  let saveSuccess = '';

  const FEATURE_LABELS = {
    log_search: 'Log Search',
    live_tail: 'Live Tail',
    basic_alerts: 'Basic Alerts',
    pattern_analysis: 'Log Patterns',
    custom_dashboards: 'Custom Dashboards',
    telegram_alerts: 'Telegram Alerts',
    slack_alerts: 'Slack Alerts',
    webhook_alerts: 'Webhook Alerts',
    saved_searches_unlimited: 'Saved Searches',
    self_hosted: 'Self-Hosted',
    sso: 'SSO',
    audit_logs: 'Audit Logs',
    priority_support: 'Priority Support',
    dedicated_support: 'Dedicated Support',
  };

  const PLAN_COLORS = {
    free: 'default',
    pro: 'primary',
    enterprise: 'info',
  };

  onMount(() => {
    fetchLicense();
  });

  async function handleSave() {
    if (!licenseKey.trim()) return;
    saving = true;
    saveError = '';
    saveSuccess = '';
    try {
      await saveLicenseKey(licenseKey.trim());
      saveSuccess = 'License key saved successfully.';
      licenseKey = '';
    } catch (err) {
      saveError = err.message;
    } finally {
      saving = false;
    }
  }

  function formatDate(ts) {
    if (!ts) return '—';
    const d = new Date(ts * 1000);
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
  }
</script>

<section class="settings-section">
  <div class="section-header">
    <h3>License</h3>
    <p>Manage your Purl license and plan</p>
  </div>

  {#if $licenseLoading}
    <Card padding="lg">
      <div class="loading">Loading license info...</div>
    </Card>
  {:else}
    <div class="license-grid">
      <Card padding="lg">
        <div class="plan-header">
          <div class="plan-info">
            <span class="plan-label">Current Plan</span>
            <div class="plan-name">
              <Badge variant={PLAN_COLORS[$currentPlan] || 'default'} size="lg" pill>
                {$currentPlan.charAt(0).toUpperCase() + $currentPlan.slice(1)}
              </Badge>
              {#if $licenseInfo?.valid}
                <Badge variant="success" size="sm" dot>Active</Badge>
              {/if}
            </div>
          </div>
          {#if $licenseInfo?.expires_at}
            <div class="plan-expiry">
              <span class="expiry-label">Expires</span>
              <span class="expiry-value">{formatDate($licenseInfo.expires_at)}</span>
            </div>
          {/if}
        </div>
      </Card>

      <Card padding="md" title="Features">
        <div class="features-list">
          {#each Object.entries(FEATURE_LABELS) as [key, label]}
            <div class="feature-item">
              {#if ($licenseInfo?.features || []).includes(key)}
                <svg class="feature-icon check" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <polyline points="20 6 9 17 4 12"/>
                </svg>
              {:else}
                <svg class="feature-icon lock" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>
                  <path d="M7 11V7a5 5 0 0 1 10 0v4"/>
                </svg>
              {/if}
              <span class:disabled={!($licenseInfo?.features || []).includes(key)}>{label}</span>
            </div>
          {/each}
        </div>
      </Card>

      {#if $licenseInfo?.limits}
        <Card padding="md" title="Limits">
          <div class="limits-list">
            {#if $licenseInfo.limits.servers != null}
              <div class="limit-item">
                <span>Servers</span>
                <span class="limit-value">{$licenseInfo.limits.servers === -1 || $licenseInfo.limits.servers === 999 ? 'Unlimited' : $licenseInfo.limits.servers}</span>
              </div>
            {/if}
            {#if $licenseInfo.limits.retention_days != null}
              <div class="limit-item">
                <span>Retention</span>
                <span class="limit-value">{$licenseInfo.limits.retention_days === -1 || $licenseInfo.limits.retention_days === 999 ? 'Unlimited' : $licenseInfo.limits.retention_days + ' days'}</span>
              </div>
            {/if}
            {#if $licenseInfo.limits.users != null}
              <div class="limit-item">
                <span>Users</span>
                <span class="limit-value">{$licenseInfo.limits.users === -1 || $licenseInfo.limits.users === 999 ? 'Unlimited' : $licenseInfo.limits.users}</span>
              </div>
            {/if}
            {#if $licenseInfo.limits.alerts != null}
              <div class="limit-item">
                <span>Alerts</span>
                <span class="limit-value">{$licenseInfo.limits.alerts === -1 || $licenseInfo.limits.alerts === 999 ? 'Unlimited' : $licenseInfo.limits.alerts}</span>
              </div>
            {/if}
          </div>
        </Card>
      {/if}

      <Card padding="md" title="License Key">
        <div class="license-key-form">
          <Input
            bind:value={licenseKey}
            placeholder="PURL-XXXX-XXXX-XXXX-XXXX"
            label="Enter license key"
            fullWidth
            on:enter={handleSave}
          />
          <Button variant="primary" on:click={handleSave} loading={saving} disabled={!licenseKey.trim()}>
            Save Key
          </Button>
        </div>
        {#if saveError}
          <p class="form-error">{saveError}</p>
        {/if}
        {#if saveSuccess}
          <p class="form-success">{saveSuccess}</p>
        {/if}
        {#if $licenseError}
          <p class="form-error">{$licenseError}</p>
        {/if}
      </Card>

      {#if $isFreePlan}
        <Card padding="lg" transparent bordered={false}>
          <div class="upgrade-cta">
            <h4>Upgrade to Pro</h4>
            <p>Unlock log patterns, saved searches, multi-user access, and more.</p>
            <Button variant="primary" on:click={() => window.open('https://purlogs.com/pricing', '_blank')}>
              View Pricing
            </Button>
          </div>
        </Card>
      {/if}
    </div>
  {/if}
</section>

<style>
  .settings-section {
    max-width: 700px;
  }

  .section-header {
    margin-bottom: 24px;
  }

  .section-header h3 {
    font-size: 1.25rem;
    font-weight: 600;
    color: var(--text-primary, #f0f6fc);
    margin: 0 0 4px;
  }

  .section-header p {
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
    margin: 0;
  }

  .license-grid {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .loading {
    text-align: center;
    color: var(--text-secondary, #8b949e);
    padding: 20px;
  }

  .plan-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
  }

  .plan-info {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .plan-label {
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 600;
  }

  .plan-name {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .plan-expiry {
    text-align: right;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .expiry-label {
    font-size: 0.75rem;
    color: var(--text-secondary, #8b949e);
  }

  .expiry-value {
    font-size: 0.875rem;
    color: var(--text-primary, #f0f6fc);
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
  }

  .features-list {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
  }

  .feature-item {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 0.8125rem;
    color: var(--text-primary, #c9d1d9);
  }

  .feature-item .disabled {
    color: var(--text-muted, #6e7681);
  }

  .feature-icon.check {
    color: var(--color-success, #3fb950);
  }

  .feature-icon.lock {
    color: var(--text-muted, #6e7681);
  }

  .limits-list {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .limit-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 0.8125rem;
  }

  .limit-item span:first-child {
    color: var(--text-secondary, #8b949e);
  }

  .limit-value {
    color: var(--text-primary, #f0f6fc);
    font-family: var(--font-mono, 'SF Mono', Monaco, monospace);
  }

  .license-key-form {
    display: flex;
    gap: 12px;
    align-items: flex-end;
  }

  .form-error {
    margin-top: 8px;
    font-size: 0.75rem;
    color: var(--color-error, #f85149);
  }

  .form-success {
    margin-top: 8px;
    font-size: 0.75rem;
    color: var(--color-success, #3fb950);
  }

  .upgrade-cta {
    text-align: center;
    padding: 16px;
    background: linear-gradient(135deg, rgba(88, 166, 255, 0.08), rgba(163, 113, 247, 0.08));
    border: 1px solid var(--border-color, #30363d);
    border-radius: 8px;
  }

  .upgrade-cta h4 {
    margin: 0 0 8px;
    font-size: 1.125rem;
    color: var(--text-primary, #f0f6fc);
  }

  .upgrade-cta p {
    margin: 0 0 16px;
    font-size: 0.875rem;
    color: var(--text-secondary, #8b949e);
  }
</style>
