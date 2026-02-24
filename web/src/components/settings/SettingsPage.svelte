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
    { id: 'backup', label: 'Backups', icon: 'backup', locked: !isAdmin },
    { id: 'api-keys', label: 'API Keys', icon: 'api-key', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'sources', label: 'Sources', icon: 'sources' },
    ...(!$k8sMode ? [{ id: 'agents', label: 'Agents', icon: 'agent', locked: !isAdmin }] : []),
    { id: 'audit', label: 'Audit Logs', icon: 'audit', requiresPlan: 'pro', locked: !$isPaidPlan },
    { id: 'pipelines', label: 'Pipelines', icon: 'pipeline', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'license', label: 'License', icon: 'key', locked: !isAdmin },
    { id: 'users', label: 'Users', icon: 'users', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'ldap', label: 'LDAP / AD', icon: 'ldap', requiresPlan: 'enterprise', locked: !$isEnterprise || !isAdmin },
    { id: 'sso', label: 'SSO / SAML', icon: 'sso', requiresPlan: 'enterprise', locked: !$isEnterprise || !isAdmin },
    { id: 'ai', label: 'AI', icon: 'ai', requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'integrations', label: 'Integrations', icon: 'integrations' },
    { id: 'redis', label: 'Redis', icon: 'redis', locked: !isAdmin },
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
          {#if section.icon === 'server'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="2" width="20" height="8" rx="2"/><rect x="2" y="14" width="20" height="8" rx="2"/><line x1="6" y1="6" x2="6.01" y2="6"/><line x1="6" y1="18" x2="6.01" y2="18"/>
            </svg>
          {:else if section.icon === 'bell'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>
            </svg>
          {:else if section.icon === 'monitor'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/>
            </svg>
          {:else if section.icon === 'database'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>
            </svg>
          {:else if section.icon === 'key'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>
            </svg>
          {:else if section.icon === 'users'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>
            </svg>
          {:else if section.icon === 'ldap'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v4c0 1.66 4 3 9 3s9-1.34 9-3V5"/><path d="M3 9v4c0 1.66 4 3 9 3s9-1.34 9-3V9"/><path d="M3 13v4c0 1.66 4 3 9 3s9-1.34 9-3v-4"/>
            </svg>
          {:else if section.icon === 'sso'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0110 0v4"/>
            </svg>
          {:else if section.icon === 'audit'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/><polyline points="10 9 9 9 8 9"/>
            </svg>
          {:else if section.icon === 'pipeline'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M4 6h16M4 12h16M4 18h10"/><circle cx="20" cy="18" r="2"/>
            </svg>
          {:else if section.icon === 'backup'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/>
            </svg>
          {:else if section.icon === 'api-key'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4"/>
            </svg>
          {:else if section.icon === 'sources'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M22 12h-4l-3 9L9 3l-3 9H2"/>
            </svg>
          {:else if section.icon === 'agent'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8"/><path d="M12 17v4"/><path d="M7 10l3-3 2 2 3-4"/>
            </svg>
          {:else if section.icon === 'integrations'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M16 16v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h3"/><path d="M8 16h8a2 2 0 0 0 2-2V3a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2z"/>
            </svg>
          {:else if section.icon === 'ai'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M12 2a10 10 0 0 1 10 10 10 10 0 0 1-10 10A10 10 0 0 1 2 12 10 10 0 0 1 12 2z"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/>
            </svg>
          {:else if section.icon === 'redis'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v4c0 1.66 4 3 9 3s9-1.34 9-3V5"/><path d="M3 9v4c0 1.66 4 3 9 3s9-1.34 9-3V9"/>
            </svg>
          {:else if section.icon === 'info'}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>
            </svg>
          {/if}
          {section.label}
          {#if section.locked}
            <svg class="lock-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>
            </svg>
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

  .lock-icon {
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
