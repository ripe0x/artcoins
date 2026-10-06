// 6. referrals: the ?ref= indicator is sticky for the session and lands in the swap hookData; the referral
//    earnings page reads the coin's referral ledger and claims it.
import { test, expect, connectWallet, isNoise } from './fixtures';
import { fund, pub } from './fork';
import { decodeRouterSwap } from './decode';
import { widgetSwap } from './widget';
import { COIN_111, DEFAULT_REFERRER, REFERRAL_PAYOUT_111 } from './constants';
import { referralPayoutAbi } from '../src/lib/abi';
import { formatEther, getAddress, type Address } from 'viem';

const FRIEND: Address = getAddress('0x00000000000000000000000000000000000f00d1');
const short = (a: string) => new RegExp(`${a.slice(0, 6)}…${a.slice(-4)}`, 'i');

test('?ref= is shown, sticky for the session, dropped when invalid, and sent in hookData', async ({ page, browser, makeWallet, consoleLog }) => {
  const wallet = await makeWallet({ label: 'ref-buyer' });
  await fund(wallet.address, '1');

  await page.goto(`/tokens/${COIN_111}?ref=${FRIEND}`);
  await expect(page.getByText(/Referred by/)).toContainText(short(FRIEND), { timeout: 120_000 });
  await expect(page.getByText(/Referred by/)).toContainText('(from your link)');

  // same tab, no ?ref: remembered for the session
  await page.goto(`/tokens/${COIN_111}`);
  await expect(page.getByText(/Referred by/)).toContainText(short(FRIEND));
  await expect(page.getByText(/Referred by/)).toContainText('(from an earlier link this session)');

  // an invalid ?ref is reported and does not replace the remembered one
  await page.goto(`/tokens/${COIN_111}?ref=0xdead`);
  await expect(page.getByText(/ignored \?ref:/)).toBeVisible();
  await expect(page.getByText(/Referred by/)).toContainText(short(FRIEND));

  // the remembered referrer is what the swap carries
  await page.goto(`/tokens/${COIN_111}`);
  await connectWallet(page, wallet.address);
  const [buy] = (await widgetSwap(page, wallet, { direction: 'buy', amount: '0.002', symbol: '111' })).slice(-1);
  expect(buy.status).toBe('success');
  expect(decodeRouterSwap(buy.data!).referrer).toBe(FRIEND);

  // opting out: no attribution at all
  await page.getByRole('button', { name: "Don't use a referrer" }).click();
  await expect(page.getByText('No referrer on this swap.')).toBeVisible();
  const [buy2] = (await widgetSwap(page, wallet, { direction: 'buy', amount: '0.001', symbol: '111' })).slice(-1);
  expect(buy2.status).toBe('success');
  const d2 = decodeRouterSwap(buy2.data!);
  expect(d2.hookData).toBe('0x');

  // a fresh session (new context) falls back to the site default from /config.json
  const ctx = await browser.newContext();
  const p2 = await ctx.newPage();
  await p2.goto(`/tokens/${COIN_111}`);
  await expect(p2.getByText(/Referred by/)).toContainText(short(DEFAULT_REFERRER), { timeout: 120_000 });
  await expect(p2.getByText(/Referred by/)).toContainText('(site default)');
  await ctx.close();
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('referral earnings page: a stranger sees 0 and cannot claim', async ({ page, makeWallet, consoleLog }) => {
  const wallet = await makeWallet({ label: 'ref-stranger' });
  await page.goto(`/tokens/${COIN_111}/referrals`);
  await expect(page.getByRole('heading', { name: 'Referral earnings' })).toBeVisible({ timeout: 120_000 });
  await expect(page.getByText(/0\.25%/).first()).toBeVisible();
  await expect(page.getByText(/Connect to view your balance and claim/)).toBeVisible();
  await connectWallet(page, wallet.address);
  const claim = page.getByRole('button', { name: /^Claim .* ETH$/ });
  await expect(claim).toHaveText('Claim 0 ETH');
  await expect(claim).toBeDisabled();
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('referral earnings page: the default referrer (impersonated) claims its ledger balance', async ({ page, makeWallet, consoleLog }) => {
  const owed = await pub.readContract({ address: REFERRAL_PAYOUT_111, abi: referralPayoutAbi, functionName: 'balances', args: [DEFAULT_REFERRER] });
  test.info().annotations.push({ type: 'owed', description: `${formatEther(owed)} ETH` });
  expect(owed).toBeGreaterThan(0n);
  const wallet = await makeWallet({ impersonate: DEFAULT_REFERRER });
  await page.goto(`/tokens/${COIN_111}/referrals`);
  await connectWallet(page, wallet.address);
  // the ledger the hook names, and the balance read from it
  await expect(page.getByText(/Pool ReferralPayout/)).toBeVisible();
  const claim = page.getByRole('button', { name: /^Claim .* ETH$/ });
  await expect(claim).toHaveText(`Claim ${formatEther(owed)} ETH`, { timeout: 60_000 });
  // a v1 coin's ledger was chosen by its deployer: the claim needs an explicit confirmation first
  await expect(claim).toBeDisabled();
  await page.getByRole('checkbox').check();
  await expect(claim).toBeEnabled();
  const ethBefore = await pub.getBalance({ address: DEFAULT_REFERRER });
  await claim.click();
  await expect(page.getByText(/^Confirmed/)).toBeVisible({ timeout: 90_000 });
  const tx = wallet.sent.at(-1)!;
  expect(tx.to?.toLowerCase()).toBe(REFERRAL_PAYOUT_111.toLowerCase());
  const rc = await pub.getTransactionReceipt({ hash: tx.hash });
  expect(rc.status).toBe('success');
  expect(await pub.readContract({ address: REFERRAL_PAYOUT_111, abi: referralPayoutAbi, functionName: 'balances', args: [DEFAULT_REFERRER] })).toBe(0n);
  // the referrer paid the gas of its own claim and received exactly the ledger balance
  expect((await pub.getBalance({ address: DEFAULT_REFERRER })) - ethBefore + rc.gasUsed * rc.effectiveGasPrice).toBe(owed);
  await expect(claim).toHaveText('Claim 0 ETH', { timeout: 60_000 });
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});
