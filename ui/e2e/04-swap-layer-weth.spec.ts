// 4. LAYER, the legacy stack's coin / weth pool: buy with 0.01 eth and sell back.
//
// a. through the widget. Discovery scans the legacy factory too (registry legacy stack, from its deploy block),
//    so /tokens/<LAYER> has a page and the widget, on the weth calldata path, with no referrer attached.
// b. the same weth calldata the widget would send (lib/swap.ts buildBuyCalldata / buildSellCalldata, weth
//    branch) signed and sent on the fork, with fresh quoter floors.
import { test, expect, connectWallet, infoRow, isNoise } from './fixtures';
import { fund, pub, walletClientFor, testAccount } from './fork';
import { decodeRouterSwap } from './decode';
import { widgetSwap, fmt18 } from './widget';
import { LAYER, LEGACY_LOCKER } from './constants';
import { erc20Abi, parseEther, maxUint256, type Hex } from 'viem';
import { INFRA } from '../src/lib/deployments.generated';
import { lockerV1Abi } from '../src/lib/abi/v1/locker';
import { permit2Abi, quoterAbi, universalRouterAbi } from '../src/lib/abi';
import { applySlippage, buildBuyCalldata, buildSellCalldata, classifyPool } from '../src/lib/swap';

const QUOTER = '0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203' as const; // ui/src/lib/config.ts MAINNET_V4_QUOTER

test('a. LAYER through the widget: legacy page, weth pair, buy 0.01 eth and sell everything back', async ({ page, makeWallet, consoleLog }) => {
  const wallet = await makeWallet({ label: 'widget-layer' });
  await fund(wallet.address, '1');
  await page.goto(`/tokens/${LAYER}`);
  await connectWallet(page, wallet.address);
  await expect(page.getByRole('heading', { level: 1 })).toContainText('LAYER', { timeout: 120_000 });
  await expect(page.getByText('artcoins factory v1 (legacy)')).toBeVisible();
  await expect(infoRow(page, 'Pair')).toContainText('WETH');
  await expect(infoRow(page, 'Locker')).toContainText(/0x75BE.*1118/i);
  await expect(page.getByRole('heading', { name: 'Swap', exact: true })).toBeVisible({ timeout: 60_000 });
  // the legacy hook has no skim: no fee rows from skimConfig, no anti sniper card, no referrer attached
  await expect(page.getByText('Fee config unavailable.')).toBeVisible({ timeout: 60_000 });
  await expect(page.getByText(/no referral fees, so no referrer is attached/)).toBeVisible();

  // ── buy: WRAP_ETH then V4_SWAP, empty hookData ──
  const layer0 = await pub.readContract({ address: LAYER, abi: erc20Abi, functionName: 'balanceOf', args: [wallet.address] });
  const buy = await widgetSwap(page, wallet, { direction: 'buy', amount: '0.01', symbol: 'LAYER' });
  const buyTx = buy.at(-1)!;
  expect(buyTx.status).toBe('success');
  expect(buyTx.value).toBe(parseEther('0.01'));
  const db = decodeRouterSwap(buyTx.data!);
  expect(db.commands.slice(2, 4)).toBe('0b'); // WRAP_ETH first
  expect(db.hookData).toBe('0x');
  const got = (await pub.readContract({ address: LAYER, abi: erc20Abi, functionName: 'balanceOf', args: [wallet.address] })) - layer0;
  expect(got).toBeGreaterThan(0n);
  expect(db.amountOutMinimum).toBeLessThanOrEqual(got);

  // ── sell everything: approvals as the widget asks, TAKE(weth) then UNWRAP_WETH ──
  const ethBefore = await pub.getBalance({ address: wallet.address });
  const sell = await widgetSwap(page, wallet, { direction: 'sell', amount: fmt18(got), symbol: 'LAYER' });
  test.info().annotations.push({ type: 'sell txs', description: sell.map((t) => `${t.kind}:${t.status}`).join(', ') });
  for (const t of sell) expect(t.status).toBe('success');
  const ds = decodeRouterSwap(sell.at(-1)!.data!);
  expect(ds.hookData).toBe('0x');
  expect(ds.commands.slice(-2)).toBe('0c'); // UNWRAP_WETH last
  expect(await pub.readContract({ address: LAYER, abi: erc20Abi, functionName: 'balanceOf', args: [wallet.address] })).toBe(layer0);
  expect(await pub.getBalance({ address: wallet.address })).toBeGreaterThan(ethBefore - parseEther('0.002'));
  // nothing stranded in the router
  expect(await pub.readContract({ address: INFRA.weth, abi: erc20Abi, functionName: 'balanceOf', args: [INFRA.universalRouter] })).toBe(0n);
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('b. LAYER weth path: ui calldata buys with 0.01 eth and sells everything back', async () => {
  const label = 'swap-layer';
  const me = testAccount(label).address;
  const wc = walletClientFor(label);
  await fund(me, '1');
  const rewards = await pub.readContract({ address: LEGACY_LOCKER, abi: lockerV1Abi, functionName: 'tokenRewards', args: [LAYER] });
  const poolKey = rewards.poolKey;
  expect(classifyPool(poolKey, LAYER, INFRA.weth)).toBe('weth');
  const hookData: Hex = '0x';
  const quote = async (zeroForOne: boolean, amount: bigint) =>
    (await pub.simulateContract({ address: QUOTER, abi: quoterAbi, functionName: 'quoteExactInputSingle', args: [{ poolKey, zeroForOne, exactAmount: amount, hookData }] })).result[0];
  const deadline = async () => (await pub.getBlock()).timestamp + 300n;
  const send = async (b: { commands: Hex; inputs: Hex[]; value: bigint }) => {
    const sim = await pub.simulateContract({ account: wc.account, address: INFRA.universalRouter, abi: universalRouterAbi, functionName: 'execute', args: [b.commands, b.inputs, await deadline()], value: b.value });
    const hash = await wc.writeContract(sim.request);
    return pub.waitForTransactionReceipt({ hash, pollingInterval: 250 }).then((r) => ({ r, hash }));
  };

  // ── buy: WRAP_ETH to the router, V4_SWAP with SETTLE(weth, payerIsUser false) ──
  const ethIn = parseEther('0.01');
  const coinIs0 = poolKey.currency0.toLowerCase() === LAYER.toLowerCase();
  const qBuy = await quote(!coinIs0, ethIn);
  const buy = buildBuyCalldata({ poolKey, token: LAYER, weth: INFRA.weth, ethAmount: ethIn, minTokenOut: applySlippage(qBuy, 100), hookData });
  const layer0 = await pub.readContract({ address: LAYER, abi: erc20Abi, functionName: 'balanceOf', args: [me] });
  const { r: rb } = await send(buy);
  expect(rb.status).toBe('success');
  const layer1 = await pub.readContract({ address: LAYER, abi: erc20Abi, functionName: 'balanceOf', args: [me] });
  const got = layer1 - layer0;
  expect(got).toBeGreaterThanOrEqual(applySlippage(qBuy, 100));
  const d = decodeRouterSwap(
    (await pub.getTransaction({ hash: rb.transactionHash })).input
  );
  expect(d.zeroForOne).toBe(!coinIs0);
  test.info().annotations.push({ type: 'buy', description: `quote ${qBuy}, got ${got}, gas ${rb.gasUsed}` });

  // ── sell everything: permit2 approvals, V4_SWAP with TAKE(weth, router) then UNWRAP_WETH(me) ──
  const allowance = await pub.readContract({ address: LAYER, abi: erc20Abi, functionName: 'allowance', args: [me, INFRA.permit2] });
  if (allowance < got) {
    const h = await wc.writeContract({ address: LAYER, abi: erc20Abi, functionName: 'approve', args: [INFRA.permit2, maxUint256] });
    expect((await pub.waitForTransactionReceipt({ hash: h })).status).toBe('success');
  }
  const exp = Number((await pub.getBlock()).timestamp) + 900;
  const h2 = await wc.writeContract({ address: INFRA.permit2, abi: permit2Abi, functionName: 'approve', args: [LAYER, INFRA.universalRouter, got, exp] });
  expect((await pub.waitForTransactionReceipt({ hash: h2 })).status).toBe('success');
  const qSell = await quote(coinIs0, got);
  const sell = buildSellCalldata({ poolKey, token: LAYER, weth: INFRA.weth, tokenAmount: got, minEthOut: applySlippage(qSell, 100), recipient: me, hookData });
  const eth0 = await pub.getBalance({ address: me });
  const { r: rs } = await send(sell);
  expect(rs.status).toBe('success');
  const eth1 = await pub.getBalance({ address: me });
  const gasCost = rs.gasUsed * rs.effectiveGasPrice;
  const ethOut = eth1 - eth0 + gasCost;
  expect(ethOut).toBeGreaterThanOrEqual(applySlippage(qSell, 100));
  // nothing stranded in the router
  const routerWeth = await pub.readContract({ address: INFRA.weth, abi: erc20Abi, functionName: 'balanceOf', args: [INFRA.universalRouter] });
  const routerEth = await pub.getBalance({ address: INFRA.universalRouter });
  test.info().annotations.push({ type: 'sell', description: `quote ${qSell}, eth out ${ethOut}, router weth ${routerWeth} eth ${routerEth}` });
  expect(await pub.readContract({ address: LAYER, abi: erc20Abi, functionName: 'balanceOf', args: [me] })).toBe(layer0);
});
