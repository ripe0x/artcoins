// Drives the SwapWidget like a user: tab, amount, approvals, swap, confirmation.
import { expect, type Page } from '@playwright/test';
import { formatUnits, type Hex } from 'viem';
import { pub } from './fork';
import type { TestWallet } from './wallet';

export interface WidgetTx {
  uiConfirmed?: boolean;
  kind: 'approve-erc20' | 'approve-permit2' | 'swap';
  hash: Hex;
  status: 'success' | 'reverted';
  data: Hex | undefined;
  value: bigint;
}

function widget(page: Page) {
  return page.locator('div.rounded-xl', { has: page.getByRole('heading', { name: 'Swap', exact: true }) }).first();
}

async function lastSentAfter(wallet: TestWallet, before: number): Promise<{ hash: Hex; data: Hex | undefined; value: bigint }> {
  await expect.poll(() => wallet.sent.length, { timeout: 60_000 }).toBeGreaterThan(before);
  return wallet.sent[wallet.sent.length - 1];
}

async function sendAndWait(
  page: Page,
  wallet: TestWallet,
  button: ReturnType<Page['getByRole']>,
  kind: WidgetTx['kind'],
  uiConfirmed?: ReturnType<Page['getByText']>
): Promise<WidgetTx & { uiConfirmed: boolean }> {
  const before = wallet.sent.length;
  await expect(button).toBeEnabled({ timeout: 90_000 });
  // the success banner is shown for 2.5 s after the ui sees the receipt, watch for it from the click on
  const seen = uiConfirmed ? uiConfirmed.waitFor({ state: 'visible', timeout: 90_000 }).then(() => true, () => false) : Promise.resolve(false);
  await button.click();
  const tx = await lastSentAfter(wallet, before);
  const r = await pub.waitForTransactionReceipt({ hash: tx.hash, timeout: 120_000, pollingInterval: 250 });
  const ok = r.status === 'success' ? await seen : false;
  return { kind, hash: tx.hash, status: r.status, data: tx.data, value: tx.value, uiConfirmed: ok };
}

/** Run one swap through the widget. `amount` is the decimal string typed in the input. */
export async function widgetSwap(
  page: Page,
  wallet: TestWallet,
  opts: { direction: 'buy' | 'sell'; amount: string; symbol: string }
): Promise<WidgetTx[]> {
  const w = widget(page);
  await expect(w).toBeVisible({ timeout: 120_000 });
  await w.getByRole('button', { name: opts.direction === 'buy' ? 'Buy' : 'Sell', exact: true }).click();
  const input = w.getByPlaceholder('0.0');
  await input.fill(opts.amount);
  await expect(w.getByText(/^Min received/)).toBeVisible({ timeout: 90_000 });
  const txs: WidgetTx[] = [];

  if (opts.direction === 'sell') {
    const a1 = w.getByRole('button', { name: /^1\. Approve exactly/ });
    if (await a1.isVisible()) {
      txs.push(await sendAndWait(page, wallet, a1, 'approve-erc20'));
      expect(txs.at(-1)!.status).toBe('success');
    }
    const a2 = w.getByRole('button', { name: /^2\. Let the router spend it/ });
    await expect(a2.or(w.getByRole('button', { name: `Sell ${opts.symbol}`, exact: true }))).toBeVisible({ timeout: 60_000 });
    if (await a2.isVisible()) {
      txs.push(await sendAndWait(page, wallet, a2, 'approve-permit2'));
      expect(txs.at(-1)!.status).toBe('success');
    }
  }

  const ack = w.getByRole('checkbox');
  if (await ack.isVisible().catch(() => false)) await ack.check();

  const go = w.getByRole('button', { name: `${opts.direction === 'buy' ? 'Buy' : 'Sell'} ${opts.symbol}`, exact: true });
  const res = await sendAndWait(page, wallet, go, 'swap', w.getByText(/Swap confirmed in block \d+/));
  txs.push(res);
  if (res.status === 'success') expect(res.uiConfirmed, 'the widget showed "Swap confirmed"').toBe(true);
  return txs;
}

export function fmt18(v: bigint): string {
  return formatUnits(v, 18);
}
