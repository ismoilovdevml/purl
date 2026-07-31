<!--
  SettingsPage Component
  Main settings page with navigation sidebar.

  Deep links: the section lives in the hash suffix (`#settings/agents`), so any
  page can link straight to a settings section. App.svelte routes on
  `hash.split('/')[0]`, which keeps `#settings` and `#settings/<id>` on the same
  page. Plain `#settings` leaves whatever section is already active.

  Usage:
  <SettingsPage />
-->
<script>
  import { onMount } from 'svelte';
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
  import {
    activity, agent, ai, bell, database, databaseThreeTier, databaseTwoTier,
    fileText, info, integrations, key, lock, monitor, pipeline, server, upload, users,
  } from '../ui/icons.js';

  let activeSection = 'database';

  /** Section id requested by the URL hash, or null for a plain `#settings`. */
  let requestedSection = null;

  $: userRole = $currentUser?.role || 'viewer';
  $: isAdmin = userRole === 'admin';

  // Non-admin users can't access admin-only sections; redirect to 'about'
  $: if (!isAdmin && activeSection === 'database') {
    activeSection = 'about';
  }

  $: sections = [
    { id: 'database', label: 'Database', icon: server, locked: !isAdmin },
    { id: 'notifications', label: 'Notifications', icon: bell, locked: !isAdmin },
    { id: 'display', label: 'Display', icon: monitor },
    { id: 'data', label: 'Data', icon: database, locked: !isAdmin },
    { id: 'backup', label: 'Backups', icon: upload, locked: !isAdmin },
    { id: 'api-keys', label: 'API Keys', icon: key, requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'sources', label: 'Sources', icon: activity },
    ...(!$k8sMode ? [{ id: 'agents', label: 'Agents', icon: agent, locked: !isAdmin }] : []),
    { id: 'audit', label: 'Audit Logs', icon: fileText, requiresPlan: 'pro', locked: !$isPaidPlan },
    { id: 'pipelines', label: 'Pipelines', icon: pipeline, requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'license', label: 'License', icon: key, locked: !isAdmin },
    { id: 'users', label: 'Users', icon: users, requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'ldap', label: 'LDAP / AD', icon: databaseThreeTier, requiresPlan: 'enterprise', locked: !$isEnterprise || !isAdmin },
    { id: 'sso', label: 'SSO / SAML', icon: lock, requiresPlan: 'enterprise', locked: !$isEnterprise || !isAdmin },
    { id: 'ai', label: 'AI', icon: ai, requiresPlan: 'pro', locked: !$isPaidPlan || !isAdmin },
    { id: 'integrations', label: 'Integrations', icon: integrations },
    { id: 'redis', label: 'Redis', icon: databaseTwoTier, locked: !isAdmin },
    { id: 'about', label: 'About', icon: info },
  ];

  /**
   * Re-run whenever the hash OR the section list changes. The second dependency
   * matters: on a cold load the license store has not resolved yet, so a Pro
   * section is momentarily `locked` and a deep link to it would be dropped.
   * Once the plan arrives `sections` is rebuilt and the link resolves.
   */
  $: applyRequestedSection(requestedSection, sections);

  function applyRequestedSection(id, list) {
    if (!id) return; // plain `#settings` — keep whatever is active
    const section = list.find((s) => s.id === id);
    if (section && !section.locked) {
      activeSection = id;
    }
  }

  /** `#settings/agents` -> 'agents'; `#settings` or anything else -> null. */
  function readHash() {
    const [page, section] = (window.location.hash.slice(1) || '').split('/');
    requestedSection = page === 'settings' && section ? section : null;
  }

  function selectSection(section) {
    if (section.locked) return;
    activeSection = section.id;
    // Keeps the section shareable/bookmarkable. App.svelte reads only the part
    // before the slash, so this never navigates away from Settings.
    window.location.hash = `settings/${section.id}`;
  }

  onMount(() => {
    readHash();
    window.addEventListener('hashchange', readHash);
    return () => window.removeEventListener('hashchange', readHash);
  });
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
          on:click={() => selectSection(section)}
          title={section.locked
            ? (section.requiresPlan && (section.requiresPlan === 'enterprise' ? !$isEnterprise : !$isPaidPlan)
              ? `Requires ${section.requiresPlan === 'enterprise' ? 'Enterprise' : 'Pro'} plan`
              : 'Admin access required')
            : ''}
        >
          <Icon icon={section.icon} size={16} />
          {section.label}
          {#if section.locked}
            <Icon icon={lock} size={12} strokeWidth={3} class="lock-icon" label="Locked" />
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
    background: var(--bg-primary);
    color: var(--text-primary);
    overflow: hidden;
  }

  .settings-nav {
    width: 220px;
    background: var(--bg-secondary);
    border-right: 1px solid var(--border-muted);
    padding: 20px 0;
    flex-shrink: 0;
    overflow-y: auto;
  }

  .settings-nav h2 {
    font-size: 1rem;
    font-weight: 600;
    padding: 0 16px 16px;
    margin: 0;
    border-bottom: 1px solid var(--border-muted);
    color: var(--text-bright);
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
    color: var(--text-secondary);
    font-size: 0.875rem;
    cursor: pointer;
    transition: all 0.15s;
    text-align: left;
  }

  .nav-item:hover {
    background: var(--bg-tertiary);
    color: var(--text-primary);
  }

  .nav-item.active {
    background: rgba(31, 111, 235, 0.15);
    color: var(--color-primary);
    border-left: 2px solid var(--color-primary);
  }

  .nav-item.locked {
    opacity: 0.6;
    cursor: default;
  }

  .nav-item.locked:hover {
    background: none;
    color: var(--text-secondary);
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
