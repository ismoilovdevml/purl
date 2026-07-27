<!--
  SettingsPage Component
  Main settings page with navigation sidebar

  Usage:
  <SettingsPage />
-->
<script>
  import DatabaseSettings from './DatabaseSettings.svelte';
  import NotificationSettings from './NotificationSettings.svelte';
  import DisplaySettings from './DisplaySettings.svelte';
  import DataSettings from './DataSettings.svelte';
  import LicenseSettings from './LicenseSettings.svelte';
  import UsersSettings from './UsersSettings.svelte';
  import LDAPSettings from './LDAPSettings.svelte';
  import SSOSettings from './SSOSettings.svelte';
  import BackupSettings from './BackupSettings.svelte';
  import PipelineSettings from './PipelineSettings.svelte';
  import AboutSettings from './AboutSettings.svelte';
  import AISettings from './AISettings.svelte';
  import RedisSettings from './RedisSettings.svelte';
  import AuditSettings from './AuditSettings.svelte';
  import ApiKeysSettings from './ApiKeysSettings.svelte';
  import SourcesSettings from './SourcesSettings.svelte';
  import IntegrationsSettings from './IntegrationsSettings.svelte';
  import AgentsSettings from './AgentsSettings.svelte';
  import { isPaidPlan, isEnterprise, k8sMode } from '../../stores/license.js';
  import { currentUser } from '../../stores/auth.js';
  import Icon from '../ui/Icon.svelte';

  let activeSection = 'database';

  $: userRole = $currentUser?.role || 'viewer';
  $: isAdmin = userRole === 'admin';

  // Non-admin users can't access admin-only sections; redirect to 'about'
  $: if (!isAdmin && activeSection === 'database') {
    activeSection = 'about';
  }

  $: sections = [
    { id: 'database', label: 'Database', icon: 'server', locked: !isAdmin },
    { id: 'notifications', label: 'Notifications', icon: 'bell', locked: !isAdmin },
    { id: 'display', label: 'Display', icon: 'monitor' },
    { id: 'data', label: 'Data', icon: 'database', locked: !isAdmin },
    { id: 'backup', label: 'Backups', icon: 'upload', locked: !isAdmin },
    { id: 'api-keys', label: 'API Keys', icon: 'key', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'sources', label: 'Sources', icon: 'activity' },
    ...(!$k8sMode ? [{ id: 'agents', label: 'Agents', icon: 'agent', locked: !isAdmin }] : []),
    { id: 'audit', label: 'Audit Logs', icon: 'file-text', requiresPlan: 'pro', locked: !$isPaidPlan },
    { id: 'pipelines', label: 'Pipelines', icon: 'pipeline', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'license', label: 'License', icon: 'key', locked: !isAdmin },
    { id: 'users', label: 'Users', icon: 'users', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'ldap', label: 'LDAP / AD', icon: 'database-three-tier', requiresPlan: 'enterprise', locked: !$isEnterprise || !isAdmin },
    { id: 'sso', label: 'SSO / SAML', icon: 'lock', requiresPlan: 'enterprise', locked: !$isEnterprise || !isAdmin },
    { id: 'ai', label: 'AI', icon: 'ai', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'integrations', label: 'Integrations', icon: 'integrations' },
    { id: 'redis', label: 'Redis', icon: 'database-two-tier', locked: !isAdmin },
    { id: 'about', label: 'About', icon: 'info' },
  ];
</script>

<div class="settings-page">
  <aside class="settings-nav">
    <h2>Settings</h2>
    <nav>
      {#each sections as section}
        <button
          class="nav-item"
          class:active={activeSection === section.id}
          class:locked={section.locked}
          on:click={() => { if (!section.locked) activeSection = section.id; }}
          title={section.locked
            ? (section.requiresPlan && (section.requiresPlan === 'enterprise' ? !$isEnterprise : !$isPaidPlan)
              ? `Requires ${section.requiresPlan === 'enterprise' ? 'Enterprise' : 'Pro'} plan`
              : 'Admin access required')
            : ''}
        >
          <Icon name={section.icon} size={16} />
          {section.label}
          {#if section.locked}
            <Icon name="lock" size={12} class="lock-icon" label="Locked" />
          {/if}
        </button>
      {/each}
    </nav>
  </aside>

  <main class="settings-content">
    {#if activeSection === 'database'}
      <DatabaseSettings />
    {:else if activeSection === 'notifications'}
      <NotificationSettings />
    {:else if activeSection === 'display'}
      <DisplaySettings />
    {:else if activeSection === 'data'}
      <DataSettings />
    {:else if activeSection === 'license'}
      <LicenseSettings />
    {:else if activeSection === 'users'}
      <UsersSettings />
    {:else if activeSection === 'ldap'}
      <LDAPSettings />
    {:else if activeSection === 'sso'}
      <SSOSettings />
    {:else if activeSection === 'api-keys'}
      <ApiKeysSettings />
    {:else if activeSection === 'sources'}
      <SourcesSettings />
    {:else if activeSection === 'audit'}
      <AuditSettings />
    {:else if activeSection === 'pipelines'}
      <PipelineSettings />
    {:else if activeSection === 'backup'}
      <BackupSettings />
    {:else if activeSection === 'ai'}
      <AISettings />
    {:else if activeSection === 'agents'}
      <AgentsSettings />
    {:else if activeSection === 'integrations'}
      <IntegrationsSettings />
    {:else if activeSection === 'redis'}
      <RedisSettings />
    {:else if activeSection === 'about'}
      <AboutSettings />
    {/if}
  </main>
</div>

<style>
  .settings-page {
    display: flex;
    height: calc(100vh - 60px);
    background: var(--bg-primary, #0d1117);
    color: var(--text-primary, #c9d1d9);
    overflow: hidden;
  }

  .settings-nav {
    width: 220px;
    background: var(--bg-secondary, #161b22);
    border-right: 1px solid var(--border-color, #21262d);
    padding: 20px 0;
    flex-shrink: 0;
    overflow-y: auto;
  }

  .settings-nav h2 {
    font-size: 1rem;
    font-weight: 600;
    padding: 0 16px 16px;
    margin: 0;
    border-bottom: 1px solid var(--border-color, #21262d);
    color: var(--text-primary, #f0f6fc);
  }

  .settings-nav nav {
    padding: 8px 0;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    width: 100%;
    padding: 10px 16px;
    background: none;
    border: none;
    color: var(--text-secondary, #8b949e);
    font-size: 0.875rem;
    cursor: pointer;
    transition: all 0.15s;
    text-align: left;
  }

  .nav-item:hover {
    background: var(--bg-tertiary, #21262d);
    color: var(--text-primary, #c9d1d9);
  }

  .nav-item.active {
    background: rgba(31, 111, 235, 0.15);
    color: var(--color-primary, #58a6ff);
    border-left: 2px solid var(--color-primary, #58a6ff);
  }

  .nav-item.locked {
    opacity: 0.6;
    cursor: default;
  }

  .nav-item.locked:hover {
    background: none;
    color: var(--text-secondary, #8b949e);
  }

  .nav-item :global(.lock-icon) {
    margin-left: auto;
    opacity: 0.5;
    color: #8b949e;
    flex-shrink: 0;
  }

  .settings-content {
    flex: 1;
    padding: 24px 32px;
    overflow-y: auto;
    height: 100%;
  }
</style>
