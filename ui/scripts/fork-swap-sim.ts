// Proves the ui swap calldata against the live stack on a mainnet fork (UI-06, UI-14).
//
//   source /tmp/claude-0/env.sh   (or any foundry install)
//   anvil --fork-url "$MAINNET_RPC_URL" --fork-block-number 26130269 --port 8599 --silent &
//   cd ui && npx tsx scripts/fork-swap-sim.ts
//
// Buys coin 111 with eth, then sells it back, both through the Universal Router with the commands
// lib/swap.ts builds, using a fresh quoter quote for the floor. Exits 1 on any failure.
import { createPublicClient, createWalletClient, http, formatEther, parseEther, type Address } from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { mainnet } from 'viem/chains';
import { buildBuyCalldata, buildSellCalldata, applySlippage, priceImpactPercent } from '../src/lib/swap';
import { encodeAttributionHookData } from '../src/lib/attribution';
import { erc20Abi, permit2Abi, quoterAbi, universalRouterAbi, stateViewAbi } from '../src/lib/abi';
import { lockerV1Abi } from '../src/lib/abi/v1/locker';
import { CURRENT, INFRA, COINS } from '../src/lib/deployments.generated';
import { priceFromSqrtX96 } from '../src/lib/pool';

const RPC = process.env.FORK_RPC ?? 'http://127.0.0.1:8599';
const QUOTER: Address = '0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203';
// A fresh key, funded with anvil_setBalance. Do NOT use anvil's default account 0: on mainnet it carries a
// sweeper delegation (eip-7702) that forwards any eth it receives, which looks like a sell paying nothing.
const account = privateKeyToAccount(generatePrivateKey());
const pub = createPublicClient({ chain: mainnet, transport: http(RPC) });
const wallet = createWalletClient({ account, chain: mainnet, transport: http(RPC) });

const coin = COINS.find((c) => c.symbol === '111')!.address;
const log = (...a: unknown[]) => console.log(...a);

async function main() {
  await pub.request({ method: 'anvil_setBalance' as never, params: [account.address, '0x56bc75e2d63100000'] as never });
  const rewards = await pub.readContract({ address: CURRENT.locker, abi: lockerV1Abi, functionName: 'tokenRewards', args: [coin] });
  const poolKey = rewards.poolKey;
  log('pool key', poolKey);
  const hookData = encodeAttributionHookData({ referrer: CURRENT.payout });

  const poolId = (await import('../src/lib/pool')).computePoolId({
    currency0: poolKey.currency0,
    currency1: poolKey.currency1,
    fee: poolKey.fee,
    tickSpacing: poolKey.tickSpacing,
    hooks: poolKey.hooks,
  });
  const slot0 = await pub.readContract({ address: INFRA.stateView, abi: stateViewAbi, functionName: 'getSlot0', args: [poolId] });
  const mid = priceFromSqrtX96(slot0[0]); // coin per eth, coin is currency1
  log('mid coin per eth', mid);

  // ── buy ──
  const ethIn = parseEther('0.05');
  const quoteBuy = (
    await pub.simulateContract({
      address: QUOTER,
      abi: quoterAbi,
      functionName: 'quoteExactInputSingle',
      args: [{ poolKey, zeroForOne: true, exactAmount: ethIn, hookData }],
    })
  ).result[0];
  const minOut = applySlippage(quoteBuy, 100);
  log('buy quote', quoteBuy, 'min', minOut, 'impact %', priceImpactPercent('buy', ethIn, quoteBuy, mid));
  const buy = buildBuyCalldata({ poolKey, token: coin, weth: INFRA.weth, ethAmount: ethIn, minTokenOut: minOut, hookData });
  const deadline = BigInt((await pub.getBlock()).timestamp + 300n);
  const before = await pub.readContract({ address: coin, abi: erc20Abi, functionName: 'balanceOf', args: [account.address] });
  const sim = await pub.simulateContract({
    account,
    address: INFRA.universalRouter,
    abi: universalRouterAbi,
    functionName: 'execute',
    args: [buy.commands, buy.inputs, deadline],
    value: buy.value,
  });
  const h1 = await wallet.writeContract(sim.request);
  const r1 = await pub.waitForTransactionReceipt({ hash: h1 });
  if (r1.status !== 'success') throw new Error('buy reverted');
  const bal = await pub.readContract({ address: coin, abi: erc20Abi, functionName: 'balanceOf', args: [account.address] });
  const got = bal - before;
  log('bought', got, 'quote', quoteBuy);
  if (got < minOut) throw new Error('received below min out');
  if (got !== quoteBuy) log('note: received differs from quote by', got - quoteBuy);

  // ── approve (exact amounts, short expiry) ──
  const sellAmt = got / 2n;
  const allowance = await pub.readContract({ address: coin, abi: erc20Abi, functionName: 'allowance', args: [account.address, INFRA.permit2] });
  if (allowance < sellAmt) {
    const h = await wallet.writeContract({ address: coin, abi: erc20Abi, functionName: 'approve', args: [INFRA.permit2, sellAmt] });
    await pub.waitForTransactionReceipt({ hash: h });
  }
  const exp = Number((await pub.getBlock()).timestamp) + 300;
  const hp = await wallet.writeContract({ address: INFRA.permit2, abi: permit2Abi, functionName: 'approve', args: [coin, INFRA.universalRouter, sellAmt, exp] });
  await pub.waitForTransactionReceipt({ hash: hp });

  // ── sell ──
  const quoteSell = (
    await pub.simulateContract({
      address: QUOTER,
      abi: quoterAbi,
      functionName: 'quoteExactInputSingle',
      args: [{ poolKey, zeroForOne: false, exactAmount: sellAmt, hookData }],
    })
  ).result[0];
  const minEth = applySlippage(quoteSell, 100);
  log('sell quote', quoteSell, 'min', minEth, 'impact %', priceImpactPercent('sell', sellAmt, quoteSell, mid));
  const sell = buildSellCalldata({ poolKey, token: coin, weth: INFRA.weth, tokenAmount: sellAmt, minEthOut: minEth, recipient: account.address, hookData });
  const ethBefore = await pub.getBalance({ address: account.address });
  const sim2 = await pub.simulateContract({
    account,
    address: INFRA.universalRouter,
    abi: universalRouterAbi,
    functionName: 'execute',
    args: [sell.commands, sell.inputs, deadline + 600n],
    value: 0n,
  });
  const h2 = await wallet.writeContract(sim2.request);
  const r2 = await pub.waitForTransactionReceipt({ hash: h2 });
  if (r2.status !== 'success') throw new Error('sell reverted');
  const ethAfter = await pub.getBalance({ address: account.address });
  const gas = r2.gasUsed * r2.effectiveGasPrice;
  log('eth before', ethBefore, 'after', ethAfter, 'gas', gas, 'tokens left', await pub.readContract({ address: coin, abi: erc20Abi, functionName: 'balanceOf', args: [account.address] }));
  const received = ethAfter - ethBefore + gas;
  log('sold', sellAmt, 'received eth', formatEther(received), 'quote', formatEther(quoteSell));
  if (received < minEth) throw new Error('eth received below min out');

  // ── a zero floor is refused before anything is sent ──
  let refused = false;
  try {
    buildSellCalldata({ poolKey, token: coin, weth: INFRA.weth, tokenAmount: sellAmt, minEthOut: 0n, recipient: account.address });
  } catch {
    refused = true;
  }
  if (!refused) throw new Error('zero min out was not refused');
  log('OK: buy and sell through the universal router succeed on the fork, zero floor refused');
}

main().catch((e) => {
  console.error('FAIL', e);
  process.exit(1);
});
