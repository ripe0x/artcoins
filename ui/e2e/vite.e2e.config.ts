// Vite config for the e2e runs: the app's own config plus a per port dep cache and an upfront dep scan,
// so two dev servers (with and without a v2 stack) never race on node_modules/.vite and the browser is
// never reloaded mid test by a late "new dependencies optimized" pass.
import { defineConfig, mergeConfig } from 'vite';
import base from '../vite.config';

const port = Number(process.env.E2E_PORT ?? 5181);

export default mergeConfig(
  base,
  defineConfig({
    cacheDir: `node_modules/.vite-e2e-${port}`,
    // e2e/artifacts gets traces and screenshots during a run, never reload the app for them
    server: { port, strictPort: true, host: '127.0.0.1', watch: { ignored: ['**/e2e/**', '**/node_modules/**'] } },
    optimizeDeps: { entries: ['index.html', 'src/**/*.tsx'] },
    clearScreen: false,
  })
);
