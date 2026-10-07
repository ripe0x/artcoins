// 5b. deploy page against a v2 stack deployed on the fork (project "v2", needs E2E_V2_JSON):
//   - a stranger's launch is blocked while the factory is deprecated
//   - after setDeprecated(false) (owner tx) the form validates: byte caps, referral cap max, min lp fee,
//     restriction allowlist; then a launch succeeds through the ui
//   - the new v2 coin trades through the widget and its hookData names the wallet as the refund address
//   - its referral page reads the fee escrow
import { test, expect, connectWallet, isNoise, infoRow } from './fixtures';
import { fund, pub, rpc, v2Env } from './fork';
import { decodeRouterSwap } from './decode';
import { widgetSwap, fmt18 } from './widget';
import { DEFAULT_REFERRER } from './constants';
import { factoryV2Abi } from '../src/lib/abi/v2/factory';
import { escrowV2Abi } from '../src/lib/abi/v2/escrow';
import { hookV2Abi } from '../src/lib/abi/v2/hook';
import { STRING_CAPS } from '../src/lib/launchRules';
import { encodeFunctionData, erc20Abi, parseEther, parseEventLogs, type Address } from 'viem';
import type { Page as PwPage } from '@playwright/test';

const v2 = v2Env()!;
test.skip(!v2, 'E2E_V2_JSON not set');
test.describe.configure({ mode: 'serial' });

async function ownerTx(data: `0x${string}`) {
  const hash = await rpc<`0x${string}`>('eth_sendTransaction', [{ from: v2.owner, to: v2.factory, data }]);
  const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 250 });
  expect(r.status).toBe('success');
}
const setDeprecated = (d: boolean) => ownerTx(encodeFunctionData({ abi: factoryV2Abi, functionName: 'setDeprecated', args: [d] }));
const deprecated = () => pub.readContract({ address: v2.factory, abi: factoryV2Abi, functionName: 'deprecated' });
const step = (page: PwPage, title: RegExp) => page.getByRole('button', { name: title });
const slider = (page: PwPage, label: string) =>
  page.locator('label', { hasText: new RegExp(`^${label}:`) }).locator('xpath=following-sibling::input[@type="range"][1]');
/** set a range input like a drag would: the browser sanitizes (clamps, steps) the value, react sees an input event */
async function setRange(loc: ReturnType<PwPage['locator']>, v: string) {
  await loc.evaluate((el, val) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!;
    setter.call(el, val);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }, v);
}
const deployButton = (page: PwPage) => page.getByRole('button', { name: /Deploy token|problem|owner only|Connect your wallet|Checking|Confirm|Could not read/ }).last();

let launched: Address | null = null;
let referralPushed: boolean | null = null;

test('stranger is blocked while the v2 factory is deprecated', async ({ page, makeWallet, consoleLog }) => {
  if (!(await deprecated())) await setDeprecated(true);
  const wallet = await makeWallet({ label: 'v2-stranger' });
  await fund(wallet.address, '2');
  await page.goto('/');
  await connectWallet(page, wallet.address);
  const status = page.getByRole('status');
  await expect(status).toContainText(/Only the factory owner can launch/);
  await expect(page.getByText(/Public launches: closed/)).toBeVisible();
  await expect(page.getByText(/Deploy fee: 0\.069 ETH/)).toBeVisible();
  await expect(page.getByText(/Min lp fee: 0\.3%/)).toBeVisible();
  await expect(page.getByText(/Min protocol skim share: 10%/)).toBeVisible();
  await page.getByPlaceholder('My Token').fill('E2E Blocked');
  await page.getByPlaceholder('MTK').fill('BLKD');
  await step(page, /Review and launch/).click();
  await expect(deployButton(page)).toBeDisabled();
  await expect(deployButton(page)).toContainText(/owner only/);
  expect(wallet.sent).toHaveLength(0);
  test.info().annotations.push({ type: 'wording', description: (await status.innerText()).replace(/\s+/g, ' ') });
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('after setDeprecated(false) the form validates and a launch succeeds', async ({ page, makeWallet, consoleLog }) => {
  await setDeprecated(false);
  const wallet = await makeWallet({ label: 'v2-stranger' });
  await page.goto('/');
  await connectWallet(page, wallet.address);
  await expect(page.getByText(/Public launches: open/)).toBeVisible({ timeout: 60_000 });
  await expect(page.getByRole('status')).toHaveCount(0);

  // ── byte caps (utf8 bytes, not characters) ──
  const name = page.getByPlaceholder('My Token');
  const symbol = page.getByPlaceholder('MTK');
  const tooLongName = '🎨'.repeat(Math.floor(STRING_CAPS.name / 4) + 1); // 4 bytes each
  await name.fill(tooLongName);
  await expect(page.getByText(new RegExp(`name is ${[...tooLongName].length * 4} bytes, the cap is ${STRING_CAPS.name}`))).toBeVisible();
  await symbol.fill('X'.repeat(STRING_CAPS.symbol + 1));
  await expect(page.getByText(new RegExp(`symbol is ${STRING_CAPS.symbol + 1} bytes, the cap is ${STRING_CAPS.symbol}`))).toBeVisible();
  await name.fill('E2E Launch');
  await symbol.fill('E2EL');
  await expect(page.getByText(/bytes, the cap is/)).toHaveCount(0);
  await page.getByPlaceholder('https://example.com/token-image.png').fill('https://example.com/e2e.png');

  // ── pool and fees ──
  await step(page, /Pool and fees/).click();
  const lp = slider(page, 'LP fee');
  await expect(lp).toHaveAttribute('min', '0.3'); // the factory's minLpFee, 3000 pips
  await setRange(lp, '0.1'); // the browser clamps a range input to its min, a lower fee cannot be entered
  await expect(page.getByText(/^LP fee: 0\.3%/)).toBeVisible();
  await setRange(lp, '0.5');
  // referral cap max: bounty to its ceiling (90% with a 10% floor) leaves no room for a referral cap
  const bounty = slider(page, 'Bounty share of the skim');
  await expect(bounty).toHaveAttribute('max', '90');
  await setRange(bounty, '90');
  await expect(page.getByText(/referral cap is above the maximum of 0% of volume/)).toBeVisible();
  await page.getByRole('button', { name: /^Set it to 0%$/ }).click();
  await expect(page.getByText(/referral cap is above the maximum/)).toHaveCount(0);
  // back to 111's numbers and the largest cap they allow: 6% x (100 - 83.33 - 10)% = 0.4%
  await setRange(bounty, '83.33');
  const cap = slider(page, 'Referral cap');
  await expect(cap).toHaveAttribute('max', '0.4');
  await setRange(cap, '0.4');
  await expect(page.getByText(/^Referral cap: 0\.4%/)).toBeVisible();
  await expect(page.getByText(/Referral cap max \(these fees\): 0\.4% of volume/)).toBeVisible();

  // ── restriction: a zero address on the allowlist is refused ──
  await step(page, /Transfer restriction/).click();
  await page.getByRole('checkbox', { name: /Restrict transfers/ }).check();
  await page.getByPlaceholder('0x..., 0x...').fill('0x0000000000000000000000000000000000000000');
  await expect(page.getByText(/is not a valid nonzero address/i)).toBeVisible();
  await step(page, /Review and launch/).click();
  await expect(deployButton(page)).toBeDisabled();
  await expect(deployButton(page)).toContainText(/problem/);
  await step(page, /Transfer restriction/).click();
  await page.getByPlaceholder('0x..., 0x...').fill('');
  await page.getByRole('checkbox', { name: /Restrict transfers/ }).uncheck();

  // ── review and launch ──
  await step(page, /Review and launch/).click();
  const btn = deployButton(page);
  await expect(btn).toHaveText(/Deploy token \(0\.069 ETH\)/, { timeout: 30_000 });
  await expect(btn).toBeEnabled();
  const before = wallet.sent.length;
  await btn.click();
  await expect(page.getByText('Token launched')).toBeVisible({ timeout: 120_000 });
  const tx = wallet.sent[before];
  expect(tx.to?.toLowerCase()).toBe(v2.factory.toLowerCase());
  expect(tx.value).toBe(parseEther('0.069'));
  const rc = await pub.getTransactionReceipt({ hash: tx.hash });
  expect(rc.status).toBe('success');
  const [ev] = parseEventLogs({ abi: factoryV2Abi, eventName: 'TokenCreatedV2', logs: rc.logs });
  launched = ev.args.token;
  await expect(page.getByText(launched!, { exact: true })).toBeVisible();
  expect(await pub.readContract({ address: v2.factory, abi: factoryV2Abi, functionName: 'isArtCoin', args: [launched!] })).toBe(true);
  const cfg = ev.args.config;
  expect(cfg.token.name).toBe('E2E Launch');
  expect(cfg.token.symbol).toBe('E2EL');
  test.info().annotations.push({ type: 'launch', description: `${launched} gas ${rc.gasUsed} pool ${ev.args.poolId} fees ${JSON.stringify(cfg.pool, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)).slice(0, 400)}` });
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('the launched v2 coin is listed, trades through the widget, and names the refund address', async ({ page, makeWallet, consoleLog }) => {
  test.skip(!launched, 'launch did not happen');
  const coin = launched!;
  const wallet = await makeWallet({ label: 'v2-trader' });
  await fund(wallet.address, '1');
  await page.goto('/tokens');
  await expect(page.locator(`a[href="/tokens/${coin}"]`)).toContainText('artcoins factory v2', { timeout: 120_000 });
  await page.goto(`/tokens/${coin}`);
  await expect(page.getByText('artcoins factory v2').first()).toBeVisible({ timeout: 120_000 });
  await connectWallet(page, wallet.address);
  const buy = await widgetSwap(page, wallet, { direction: 'buy', amount: '0.01', symbol: 'E2EL' });
  const b = buy.at(-1)!;
  expect(b.status).toBe('success');
  const d = decodeRouterSwap(b.data!);
  expect(d.hooks.toLowerCase()).toBe(v2.hook.toLowerCase());
  expect(d.refundTo).toBe(wallet.address); // D58: every v2 swap names the connected wallet
  expect(d.referrer?.toLowerCase()).toBe(DEFAULT_REFERRER.toLowerCase());
  // D59: the referral leg is pushed straight to the referrer (escrow only when the push fails)
  const brc = await pub.getTransactionReceipt({ hash: b.hash });
  const legs = parseEventLogs({ abi: hookV2Abi, eventName: 'FeeDelivered', logs: brc.logs });
  const ref = legs.find((l) => Number(l.args.leg) === 2);
  test.info().annotations.push({ type: 'buy fee legs', description: JSON.stringify(legs.map((l) => l.args), (_k, v) => (typeof v === 'bigint' ? v.toString() : v)) });
  expect(ref, 'a referral leg was paid').toBeTruthy();
  expect(ref!.args.to.toLowerCase()).toBe(DEFAULT_REFERRER.toLowerCase());
  referralPushed = !ref!.args.escrowed;
  const bal = await pub.readContract({ address: coin, abi: erc20Abi, functionName: 'balanceOf', args: [wallet.address] });
  expect(bal).toBeGreaterThan(0n);
  const sell = await widgetSwap(page, wallet, { direction: 'sell', amount: fmt18(bal / 2n), symbol: 'E2EL' });
  test.info().annotations.push({ type: 'sell txs', description: sell.map((t) => `${t.kind}:${t.status}`).join(', ') });
  for (const t of sell) expect(t.status).toBe('success');
  const s = decodeRouterSwap(sell.at(-1)!.data!);
  expect(s.refundTo).toBe(wallet.address);
  expect(await pub.readContract({ address: coin, abi: erc20Abi, functionName: 'balanceOf', args: [wallet.address] })).toBe(bal - bal / 2n);
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('the v2 coin referral page reads the fee escrow and claims for the referrer', async ({ page, makeWallet, consoleLog }) => {
  test.skip(!launched, 'launch did not happen');
  const coin = launched!;
  const wallet = await makeWallet({ label: 'v2-claimer' });
  await fund(wallet.address, '0.1');
  await page.goto(`/tokens/${coin}/referrals`);
  await expect(page.getByText('Referral earnings that could not be delivered')).toBeVisible({ timeout: 120_000 });
  await connectWallet(page, wallet.address);
  const claim = page.getByRole('button', { name: /^Claim .* ETH$|Checking the claim|Confirm in wallet|Claiming/ });
  await expect(claim).toHaveText('Claim 0 ETH');
  await expect(claim).toBeDisabled();
  const owed = await pub.readContract({ address: v2.escrow, abi: escrowV2Abi, functionName: 'balances', args: [DEFAULT_REFERRER, '0x0000000000000000000000000000000000000000'] });
  test.info().annotations.push({ type: 'escrow owed to the default referrer', description: `${owed} (referral leg pushed directly: ${referralPushed})` });
  // D59: the page says the referral is pushed to the referrer and only a failed push sits in the escrow
  test.info().annotations.push({ type: 'copy', description: await page.getByText('Referral earnings that could not be delivered').locator('..').innerText() });
  await page.getByPlaceholder('0x...').fill(DEFAULT_REFERRER);
  await expect(claim).toHaveText(`Claim ${Number(owed) === 0 ? '0' : (await import('viem')).formatEther(owed)} ETH`, { timeout: 60_000 });
  if (owed > 0n) {
    const ethBefore = await pub.getBalance({ address: DEFAULT_REFERRER });
    await claim.click();
    await expect(page.getByText(/^Claimed:/)).toBeVisible({ timeout: 90_000 });
    expect(await pub.getBalance({ address: DEFAULT_REFERRER })).toBe(ethBefore + owed);
  }
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('v2 deprecated notice names the v2 factory, not "the current factory" (UI-E2E-04)', async ({ page }) => {
  if (!(await deprecated())) await setDeprecated(true);
  await page.goto('/');
  await expect(page.getByRole('status')).toContainText(/owner only on the v2 factory/, { timeout: 60_000 });
  await expect(page.getByRole('status')).not.toContainText('current factory', { timeout: 5_000 });
});

test('anti sniper countdown follows the chain clock, not the browser clock (UI-E2E-03)', async ({ page }) => {
  test.skip(!launched, 'launch did not happen');
  await page.goto(`/tokens/${launched}`);
  await expect(infoRow(page, 'Status')).toContainText('Active', { timeout: 60_000 });
  await expect(infoRow(page, 'Time remaining')).not.toContainText('expired', { timeout: 5_000 });
  await expect(page.getByText(/decaying to the baseline in (?!expired)/)).toBeVisible();
});

test('the v2 referral page says the referral is pushed to the referrer, the escrow is the fallback (UI-E2E-05)', async ({ page }) => {
  test.skip(!launched, 'launch did not happen');
  await page.goto(`/tokens/${launched}/referrals`);
  await expect(page.getByText('Referral earnings that could not be delivered')).toBeVisible({ timeout: 60_000 });
  await expect(page.getByText(/credits the referrer in the fee escrow/)).toHaveCount(0, { timeout: 5_000 });
  await expect(page.getByText(/sends each referral fee straight to the referrer/)).toBeVisible();
});
