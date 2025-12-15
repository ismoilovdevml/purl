<script>
  export let variant = 'default'; // default, primary, danger
  export let size = 'medium'; // small, medium
  export let disabled = false;
  export let type = 'button';
</script>

<button
  {type}
  {disabled}
  class="btn {variant} {size}"
  on:click
>
  <slot />
</button>

<style>
  .btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    background: #21262d;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #c9d1d9;
    cursor: pointer;
    font-size: 14px;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s;
  }

  .btn:hover:not(:disabled) {
    background: #30363d;
  }

  .btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  /* Sizes */
  .btn.small {
    padding: 4px 10px;
    font-size: 12px;
  }

  .btn.medium {
    padding: 8px 16px;
  }

  /* Variants */
  .btn.primary {
    background: #238636;
    border-color: #238636;
    color: #fff;
  }

  .btn.primary:hover:not(:disabled) {
    background: #2ea043;
    border-color: #2ea043;
  }

  .btn.danger {
    background: #b62324;
    border-color: #b62324;
    color: #fff;
  }

  .btn.danger:hover:not(:disabled) {
    background: #da3633;
    border-color: #da3633;
  }
</style>
