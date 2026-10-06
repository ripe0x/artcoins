// 3. buy 111 with 0.01 eth through the widget, then sell half back (native pool path)
import { test, expect, connectWallet, isNoise } from './fixtures';
import { fund, pub } from './fork';
import { decodeRouterSwap } from './decode';
import { widgetSwap, fmt18 } from './widget';
import { COIN_111, DEFAULT_REFERRER } from './constants';
import { erc20Abi, parseEther, type Address } from 'viem';
import { CURRENT, INFRA } from '../src/lib/deployments.generated';
import { permit2Abi } from '../src/lib/abi';

const bal = (a: Address) => pub.getBalance({ address: a });
const coinBal = (a: Address) => pub.readContract({ address: COIN_111, abi: erc20Abi, functionName: 'balanceOf', args: [a] });

test('buy 111 with 0.01 eth, then sell half back', async ({ page, makeWallet, consoleLog }) => {
  const wallet = await makeWallet({ label: 'swap-111' });
  await fund(wallet.address, '1');
  await page.goto(`/tokens/${COIN_111}`);
  await connectWallet(page, wallet.address);

  // ── buy ──
  const eth0 = await bal(wallet.address);
  const coin0 = await coinBal(wallet.address);
  const buy = await widgetSwap(page, wallet, { direction: 'buy', amount: '0.01', symbol: '111' });
  const buyTx = buy.at(-1)!;
  expect(buyTx.status).toBe('success');
  const eth1 = await bal(wallet.address);
  const coin1 = await coinBal(wallet.address);
  expect(coin1).toBeGreaterThan(coin0);
  expect(eth0 - eth1).toBeGreaterThanOrEqual(parseEther('0.01'));
  expect(eth0 - eth1).toBeLessThan(parseEther('0.011')); // 0.01 + gas
  expect(buyTx.value).toBe(parseEther('0.01'));

  const d = decodeRouterSwap(buyTx.data!);
  test.info().annotations.push({ type: 'buy hookData', description: JSON.stringify({ ...d, deadline: d.deadline.toString(), amountIn: d.amountIn.toString(), amountOutMinimum: d.amountOutMinimum.toString() }) });
  expect(d.hooks.toLowerCase()).toBe(CURRENT.hook.toLowerCase());
  expect(d.zeroForOne).toBe(true); // eth is currency0
  expect(d.amountIn).toBe(parseEther('0.01'));
  expect(d.amountOutMinimum).toBeGreaterThan(0n);
  expect(d.amountOutMinimum).toBeLessThanOrEqual(coin1 - coin0);
  // attribution: the site default referrer, requesting the 0.25% default
  expect(d.referrer?.toLowerCase()).toBe(DEFAULT_REFERRER.toLowerCase());
  expect(d.referralBps).toBe(250);
  // 111 sits on the v1 skim hook: the ui sends no refund address there by design (only v2 hooks read it).
  // the v2 refund address is asserted in 05-deploy-v2.spec.ts on a v2 pool.
  expect(d.refundTo).toBeNull();

  // ── sell half ──
  const half = (coin1 - coin0) / 2n;
  const ethBeforeSell = await bal(wallet.address);
  const sell = await widgetSwap(page, wallet, { direction: 'sell', amount: fmt18(half), symbol: '111' });
  test.info().annotations.push({ type: 'sell txs', description: sell.map((t) => `${t.kind}:${t.status}`).join(', ') });
  // artcoins tokens give permit2 an infinite allowance (solady _givePermit2InfiniteAllowance), so the ui
  // correctly skips step 1 and asks only for the permit2 -> router approval
  expect(sell.map((t) => t.kind)).toEqual(['approve-permit2', 'swap']);
  for (const t of sell) expect(t.status).toBe('success');
  const s = decodeRouterSwap(sell.at(-1)!.data!);
  expect(s.zeroForOne).toBe(false); // coin (currency1) in, eth out
  expect(s.amountIn).toBe(half);
  expect(s.referrer?.toLowerCase()).toBe(DEFAULT_REFERRER.toLowerCase());
  const coin2 = await coinBal(wallet.address);
  expect(coin2).toBe(coin1 - half);
  const ethAfterSell = await bal(wallet.address);
  // eth came back (more than the gas of three txs)
  expect(ethAfterSell).toBeGreaterThan(ethBeforeSell - parseEther('0.002'));
  const gotBack = ethAfterSell - ethBeforeSell;
  test.info().annotations.push({ type: 'eth', description: `paid ${fmt18(eth0 - eth1)}, sell half net ${fmt18(gotBack)}` });

  // exact approval: the permit2 -> router allowance was for exactly `half` and is spent to zero
  const [p2amount] = await pub.readContract({ address: INFRA.permit2, abi: permit2Abi, functionName: 'allowance', args: [wallet.address, COIN_111, INFRA.universalRouter] });
  expect(p2amount).toBe(0n);

  // the widget balance line follows the chain after the sell
  await expect(page.getByRole('button', { name: /^Balance: / })).toBeVisible();
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('selling more than the balance says "Insufficient 111" and sends nothing', async ({ page, makeWallet }) => {
  test.fail(true, 'known bug: the permit2 approval step hides the balance check, see docs/v2/review/ui-e2e.md (UI-E2E-02)');
  const wallet = await makeWallet({ label: 'overbalance' });
  await fund(wallet.address, '0.1');
  await page.goto(`/tokens/${COIN_111}`);
  await connectWallet(page, wallet.address);
  await page.getByRole('button', { name: 'Sell', exact: true }).click();
  await page.getByPlaceholder('0.0').fill('100000'); // the wallet holds 0
  await expect(page.getByText(/^Min received/)).toBeVisible({ timeout: 90_000 });
  // today: "2. Let the router spend it for 10 minutes", enabled
  await expect(page.getByRole('button', { name: 'Insufficient 111' })).toBeVisible({ timeout: 10_000 });
});
