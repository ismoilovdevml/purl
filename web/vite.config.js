import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  build: {
    outDir: 'public',
    // NOTE: outDir === Vite's default publicDir, so emptying it would delete
    // hand-maintained static files. Keep false (pre-existing behavior).
    emptyOutDir: false,
    rollupOptions: {
      output: {
        // Split third-party code (the Svelte runtime) out of the app bundle so
        // it can be cached independently of app deploys. Route chunks are
        // created automatically from the dynamic import()s in App.svelte.
        manualChunks(id) {
          if (id.includes('node_modules')) return 'vendor';
        },
      },
    },
  },
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:3000',
        changeOrigin: true,
      },
    },
  },
});
