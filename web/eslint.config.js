import js from '@eslint/js';
import svelte from 'eslint-plugin-svelte';
import globals from 'globals';

export default [
  js.configs.recommended,
  ...svelte.configs.recommended,
  {
    languageOptions: {
      globals: {
        ...globals.browser,
        ...globals.node,
      },
      ecmaVersion: 'latest',
      sourceType: 'module',
    },
    rules: {
      'no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
      'no-console': 'off',
      'semi': ['error', 'always'],
      'quotes': ['warn', 'single', { avoidEscape: true }],
      // New in eslint-plugin-svelte 3's recommended set. Adding keys to the
      // ~66 existing {#each} blocks is a behavior change, not a lint fix: a
      // key that is not unique makes Svelte 5 throw each_key_duplicate at
      // runtime. Keys get added deliberately, per list, in their own change.
      'svelte/require-each-key': 'off',
    },
  },
  {
    ignores: ['public/', 'node_modules/'],
  },
];
