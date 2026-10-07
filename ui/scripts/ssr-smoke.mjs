// Runs scripts/ssr-smoke.tsx through vite's ssr loader (rainbowkit does not load in plain node).
import { createServer } from 'vite';
import react from '@vitejs/plugin-react';

const server = await createServer({
  configFile: false,
  plugins: [react()],
  appType: 'custom',
  logLevel: 'error',
  server: { middlewareMode: true },
  ssr: { noExternal: [/@rainbow-me/, /@vanilla-extract/] },
});
try {
  await server.ssrLoadModule('/scripts/ssr-smoke.tsx');
} catch (e) {
  console.error(e);
  process.exitCode = 1;
} finally {
  await server.close();
}
// wallet libraries keep handles open, exit explicitly with the recorded code
process.exit(process.exitCode ?? 0);
