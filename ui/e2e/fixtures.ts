// Shared playwright fixtures: console capture, the injected wallet, and connecting through rainbowkit.
import { test as base, expect, type Page, type TestInfo } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { TestWallet } from './wallet';
import { assertFork } from './fork';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export interface ConsoleEntry {
  type: string;
  text: string;
}

export const ARTIFACTS = path.join(__dirname, 'artifacts');

/** console errors that come from the environment, not from the ui (no walletconnect project, fonts) */
const NOISE = [
  /walletconnect|web3modal|reown|relay\.walletconnect|pulse\.walletconnect|api\.web3modal/i,
  /Failed to load resource: net::ERR_(NAME_NOT_RESOLVED|CONNECTION_REFUSED|TUNNEL_CONNECTION_FAILED|CERT|INTERNET_DISCONNECTED|PROXY)/i,
  /Download the React DevTools/i,
  /Lit is in dev mode/i,
];

export function isNoise(e: ConsoleEntry): boolean {
  if (e.type === 'requestfailed') return true; // listed in the console artifact, judged by the scenario
  return NOISE.some((r) => r.test(e.text));
}

function record(testInfo: TestInfo, name: string, data: unknown) {
  fs.mkdirSync(ARTIFACTS, { recursive: true });
  const file = path.join(ARTIFACTS, `${testInfo.titlePath.slice(1).join(' - ').replace(/[^a-z0-9 _.-]+/gi, '_')}.${name}.json`);
  fs.writeFileSync(file, JSON.stringify(data, (_k, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
}

type Fixtures = {
  consoleLog: ConsoleEntry[];
  /** a wallet with a deterministic key, labelled by the test title. Not attached until `connectWallet` */
  makeWallet: (opts?: { label?: string; impersonate?: `0x${string}` }) => Promise<TestWallet>;
};

export const test = base.extend<Fixtures>({
  consoleLog: async ({ page }, provide, testInfo) => {
    const entries: ConsoleEntry[] = [];
    page.on('console', (m) => {
      if (m.type() === 'error' || m.type() === 'warning') entries.push({ type: m.type(), text: m.text().slice(0, 600) });
    });
    page.on('pageerror', (e) => entries.push({ type: 'pageerror', text: `${e.name}: ${e.message}`.slice(0, 600) }));
    page.on('requestfailed', (r) => entries.push({ type: 'requestfailed', text: `${r.failure()?.errorText ?? ''} ${r.url().slice(0, 200)}` }));
    await provide(entries);
    record(testInfo, 'console', { status: testInfo.status, entries });
  },
  makeWallet: async ({ page }, provide, testInfo) => {
    await assertFork();
    const made: TestWallet[] = [];
    await provide(async (opts) => {
      const w = opts?.impersonate ? TestWallet.impersonate(opts.impersonate) : TestWallet.fromLabel(opts?.label ?? testInfo.title);
      await w.attach(page);
      made.push(w);
      return w;
    });
    for (const w of made) record(testInfo, `wallet-${w.address.slice(0, 8)}`, { address: w.address, sent: w.sent, rpc: w.log });
  },
});

/** Connect through the rainbowkit modal, picking the injected e2e wallet. */
export async function connectWallet(page: Page, address: string): Promise<void> {
  const short = new RegExp(`0x${address.slice(2, 4)}.*${address.slice(-4)}`, "i");
  const connect = page.getByRole('button', { name: /connect wallet/i }).first();
  await connect.click();
  const dialog = page.getByRole('dialog');
  await expect(dialog).toBeVisible();
  // the eip-6963 announcement shows as "E2E Wallet"; fall back to the injected MetaMask entry
  const e2e = dialog.getByRole('button', { name: /E2E Wallet/i });
  if (await e2e.count()) await e2e.first().click();
  else await dialog.getByRole('button', { name: /metamask/i }).first().click();
  await expect(page.getByRole('button', { name: short }).first()).toBeVisible({ timeout: 30_000 });
}

export { expect };
