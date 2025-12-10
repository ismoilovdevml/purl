<script>
  import { createEventDispatcher } from 'svelte';

  export let value = '';

  const dispatch = createEventDispatcher();

  function handleKeydown(event) {
    if (event.key === 'Enter') {
      dispatch('search');
    }
  }

  function handleClear() {
    value = '';
    dispatch('search');
  }
</script>

<div class="search-bar">
  <svg class="search-icon" width="16" height="16" viewBox="0 0 16 16">
    <path fill="currentColor" d="M11.5 7a4.5 4.5 0 1 1-9 0 4.5 4.5 0 0 1 9 0Zm-.82 4.74a6 6 0 1 1 1.06-1.06l3.04 3.04a.75.75 0 1 1-1.06 1.06l-3.04-3.04Z"/>
  </svg>

  <input
    type="text"
    bind:value
    on:keydown={handleKeydown}
    placeholder="Search logs... level:ERROR AND service:api*"
  />

  {#if value}
    <button class="clear-btn" on:click={handleClear}>
      <svg width="14" height="14" viewBox="0 0 14 14">
        <path fill="currentColor" d="M7 5.586 3.707 2.293a1 1 0 0 0-1.414 1.414L5.586 7 2.293 10.293a1 1 0 1 0 1.414 1.414L7 8.414l3.293 3.293a1 1 0 0 0 1.414-1.414L8.414 7l3.293-3.293a1 1 0 0 0-1.414-1.414L7 5.586Z"/>
      </svg>
    </button>
  {/if}
</div>

<style>
  .search-bar {
    flex: 1;
    max-width: 600px;
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 12px;
    color: #8b949e;
    pointer-events: none;
  }

  input {
    width: 100%;
    padding: 10px 36px;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    font-size: 14px;
    font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
  }

  input:focus {
    outline: none;
    border-color: #58a6ff;
    box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.15);
  }

  input::placeholder {
    color: #6e7681;
  }

  .clear-btn {
    position: absolute;
    right: 8px;
    padding: 4px;
    background: none;
    border: none;
    color: #8b949e;
    cursor: pointer;
    border-radius: 4px;
  }

  .clear-btn:hover {
    color: #c9d1d9;
    background: #30363d;
  }
</style>
