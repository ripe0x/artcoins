// e2e against a local mainnet fork. See the "e2e" section of ui/README.md for the setup.
//
//   project "fork": the ui as built today, no v2 stack (VITE_V2_* unset), port 5181
//   project "v2":   the same ui with VITE_V2_* from E2E_V2_JSON (a v2 stack deployed on the fork), port 5182.
//                   skipped when E2E_V2_JSON is unset or missing.
import { defineConfig, devices } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const RPC = process.env.E2E_FORK_RPC ?? 'http://127.0.0.1:8545';
const UI_DIR = path.resolve(__dirname, '..');
const v2Json = process.env.E2E_V2_JSON;
const v2 = v2Json && fs.existsSync(v2Json) ? (JSON.parse(fs.readFileSync(v2Json, 'utf8')) as Record<string, string>) : null;
const v2Vite = v2 ? Object.fromEntries(Object.entries(v2).filter(([k]) => k.startsWith('VITE_V2_'))) : {};

const common = {
  // vite exposes VITE_* from the process env, no ui/.env is written
  VITE_WALLETCONNECT_PROJECT_ID: 'e2e-local-no-walletconnect',
  VITE_MAINNET_RPC_URL: RPC,
};

const server = (port: number, extra: Record<string, string>) => ({
  command: `npx vite --config e2e/vite.e2e.config.ts`,
  cwd: UI_DIR,
  url: `http://127.0.0.1:${port}/`,
  reuseExistingServer: false,
  timeout: 180_000,
  stdout: 'ignore' as const,
  stderr: 'pipe' as const,
  env: { ...process.env, ...common, ...extra, E2E_PORT: String(port) } as Record<string, string>,
});

// set E2E_CHROMIUM to a chromium binary when the installed playwright browsers do not match this version
const executablePath = process.env.E2E_CHROMIUM;

export default defineConfig({
  testDir: __dirname,
  globalSetup: path.join(__dirname, 'global-setup.ts'),
  outputDir: path.join(__dirname, 'artifacts'),
  timeout: 240_000,
  expect: { timeout: 60_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list'], ['json', { outputFile: path.join(__dirname, 'artifacts', 'results.json') }]],
  use: {
    ...devices['Desktop Chrome'],
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
    launchOptions: executablePath ? { executablePath } : {},
  },
  projects: [
    { name: 'fork', testMatch: /\d\d-.*\.spec\.ts$/, testIgnore: /v2\.spec\.ts$/, use: { baseURL: 'http://127.0.0.1:5181' } },
    ...(v2 ? [{ name: 'v2', testMatch: /v2\.spec\.ts$/, use: { baseURL: 'http://127.0.0.1:5182' } }] : []),
  ],
  webServer: [server(5181, {}), ...(v2 ? [server(5182, v2Vite)] : [])],
});
