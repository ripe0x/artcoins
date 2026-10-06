import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseEther } from 'viem';
import {
  decide111, decideLayer, decideV2, weeklyDue, feeCaps, minOutFromSim, rateFromSim, args111, argsLayer, argsV2, combinedLayerWeth,
  decodeSlot0, spotOut, spotNetOut, inRangeOut, floorQuote, progressMade, triggerMetrics, nextBackoff, bumpFee, pendingValueWei,
} from '../decide.mjs';
import { Q96, sqrtFor } from './helpers.mjs';

const E = (x) => parseEther(String(x));
const WEEK = 604800;
const t111 = { uncollectedEth: E('0.02'), uncollectedCoin: E(10000), escrowedEth: E('0.05') };
const fresh = { lastRunAt: 1_000_000, now: 1_000_000 + 3600, weeklySeconds: WEEK }; // ran an hour ago
const p111 = (o = {}) => ({ uncollectedEth: 0n, uncollectedCoin: 0n, escrowedEth: 0n, swapperEth: 0n, swapperCoin: 0n, ...o });

test('111: idle below every threshold', () => {
  const d = decide111(p111({ uncollectedEth: E('0.02'), uncollectedCoin: E(10000), escrowedEth: E('0.05') }), t111, fresh);
  assert.equal(d.run, false); // thresholds are strict ">"
  assert.deepEqual(d.reasons, []);
});

test('111: each threshold triggers on its own', () => {
  assert.deepEqual(decide111(p111({ uncollectedEth: E('0.02') + 1n }), t111, fresh).reasons, ['uncollected_eth']);
  assert.deepEqual(decide111(p111({ uncollectedCoin: E(10000) + 1n }), t111, fresh).reasons, ['uncollected_coin']);
  assert.deepEqual(decide111(p111({ escrowedEth: E('0.05') + 1n }), t111, fresh).reasons, ['escrowed_eth']);
});

test('111: swapperEth is an alert, not a trigger', () => {
  const d = decide111(p111({ swapperEth: 1n }), t111, fresh);
  assert.equal(d.run, false);
  assert.deepEqual(d.alerts, ['swapper_eth_stranded']);
});

test('weekly timer: due without state, due after a week, not before', () => {
  assert.equal(weeklyDue(null, 5, WEEK), true);
  assert.equal(weeklyDue(100, 100 + WEEK - 1, WEEK), false);
  assert.equal(weeklyDue(100, 100 + WEEK, WEEK), true);
  assert.deepEqual(decide111(p111(), t111, { lastRunAt: 1, now: 1 + WEEK, weeklySeconds: WEEK }).reasons, ['weekly']);
  assert.deepEqual(decide111(p111(), t111, { lastRunAt: null, now: 10, weeklySeconds: WEEK }).reasons, ['weekly']);
});

const pl = (o = {}) => ({ uncollectedLayer: 0n, uncollectedWeth: 0n, claimable: [0n, 0n, 0n, 0n], routerWeth: [0n, 0n, 0n], routerThreshold: [E('0.01'), E('0.01'), E('0.01')], ...o });
const tl = { combinedWeth: E('0.01') };

test('LAYER: a router at its threshold triggers, below does not', () => {
  assert.deepEqual(decideLayer(pl({ routerWeth: [0n, E('0.01'), 0n] }), 0n, tl, fresh).reasons, ['router1_due']);
  assert.deepEqual(decideLayer(pl({ routerWeth: [0n, 0n, E('0.01') - 1n] }), 0n, tl, fresh).reasons, []);
  assert.deepEqual(decideLayer(pl({ routerWeth: [0n, 0n, E('0.011')] }), 0n, tl, fresh).reasons, ['router2_due']);
});

test('LAYER: zero threshold with an empty router never triggers', () => {
  const d = decideLayer(pl({ routerThreshold: [0n, 0n, 0n] }), 0n, tl, fresh);
  assert.equal(d.run, false);
});

test('LAYER: combined rule routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controller weth)', () => {
  // 0.004 + 0.002 + 0.4 * (0.005 + 0.005) = 0.01 -> due
  const p = pl({ routerWeth: [E('0.004'), 0n, 0n], claimable: [0n, E('0.005'), 0n, E('0.002')] });
  assert.equal(combinedLayerWeth(p, E('0.005')), E('0.01'));
  assert.deepEqual(decideLayer(p, E('0.005'), tl, fresh).reasons, ['combined_weth']);
  // one wei less on the controller -> 0.4 * x rounds down below 0.01
  assert.deepEqual(decideLayer(p, E('0.005') - 3n, tl, fresh).reasons, []);
  // claimable[0] and [2] (LAYER) never count
  assert.equal(decideLayer(pl({ claimable: [E(1e6), 0n, E(1e6), 0n] }), 0n, tl, fresh).run, false);
});

test('LAYER: weekly', () => {
  assert.deepEqual(decideLayer(pl(), 0n, tl, { lastRunAt: 0, now: WEEK, weeklySeconds: WEEK }).reasons, ['weekly']);
});

test('v2: paired and coin thresholds and weekly', () => {
  const t = { accruedPaired: E('0.02'), accruedArtCoin: E(10000) };
  const p = (o) => ({ swappers: 1n, accruedPaired: 0n, accruedArtCoin: 0n, nextConvertibleBlock: 0n, ...o });
  assert.deepEqual(decideV2(p({}), t, fresh).reasons, []);
  assert.deepEqual(decideV2(p({ accruedPaired: E('0.021') }), t, fresh).reasons, ['accrued_paired']);
  assert.deepEqual(decideV2(p({ accruedArtCoin: E(10001) }), t, fresh).reasons, ['accrued_coin']);
  assert.deepEqual(decideV2(p({}), t, { lastRunAt: null, now: 1, weeklySeconds: WEEK }).reasons, ['weekly']);
});

test('gas cap: skip when base fee plus priority is above the cap', () => {
  const g = 1_000_000_000n;
  const cap = 30n * g;
  assert.equal(feeCaps({ baseFeePerGas: 31n * g, priorityEstimate: g, capWei: cap, maxPriorityWei: 2n * g }).ok, false);
  assert.equal(feeCaps({ baseFeePerGas: 29n * g + 1n, priorityEstimate: g, capWei: cap, maxPriorityWei: 2n * g }).ok, false);
  const ok = feeCaps({ baseFeePerGas: 20n * g, priorityEstimate: 5n * g, capWei: cap, maxPriorityWei: 2n * g });
  assert.equal(ok.ok, true);
  assert.equal(ok.maxPriorityFeePerGas, 2n * g); // priority capped by MAX_PRIORITY_GWEI
  assert.equal(ok.maxFeePerGas, cap); // 2 * 20 + 2 = 42 capped to 30
  const low = feeCaps({ baseFeePerGas: g, priorityEstimate: g / 10n, capWei: cap, maxPriorityWei: 2n * g });
  assert.equal(low.maxFeePerGas, 2n * g + g / 10n);
});

// 111 pool at fork block 26130269 (coin 111 is currency1, eth currency0): slot0 word, skimConfig baseline 6000
// (SKIM_DENOMINATOR) and lp fee 5000 ppm. the simulated convert of 13,404.198e18 coin was 648,951,817,551,513 wei
const SLOT0_111 = '0x000000001388000000028f5d000000000000112b32d4f31f9e320f796ebfd616';
const m111 = { ...decodeSlot0(SLOT0_111), lpFeePpm: 5000, skimPpm: 60_000, maxStepIn: E(1_000_000), swapperShareBps: 10_000, coinIsToken0: false };
const p111fork = p111({ uncollectedCoin: 13_404_198n * 10n ** 15n });

test('min out math matches RunKeeper111.quoteMinOut', () => {
  assert.equal(minOutFromSim(4_739_500_000_000_000n, 100), 4_692_105_000_000_000n);
  assert.equal(minOutFromSim(10_001n, 100), 9_900n); // floor division
  assert.equal(minOutFromSim(0n, 100), 0n);
  // the fork quote: the simulation floor wins, same minOut the runner sent on the fork
  const q = args111([1n, 2n, 648_951_817_551_513n], 100, m111, p111fork);
  assert.equal(q.status, 'ok');
  assert.deepEqual(q.args, [true, 642_462_299_375_997n]);
  assert.ok(q.spotFloor > 0n && q.spotFloor < q.simFloor);
  assert.deepEqual(args111([1n, 2n, 0n], 100, m111, p111fork).args, [false, 0n]); // nothing converted in the simulation
});

test('slot0 decode and spot math (RUNBOOK action 5 recipe)', () => {
  const { sqrtPriceX96, lpFee } = decodeSlot0(SLOT0_111);
  assert.equal(lpFee, 5000);
  assert.equal(sqrtPriceX96, 0x112b32d4f31f9e320f796ebfd616n);
  // eth for 13,404.198 coin at spot, and net of the 6% skim plus 0.5% lp fee: the simulated convert is within 0.03%
  const net = spotNetOut(p111fork.uncollectedCoin, m111, false);
  assert.equal(net, 648_777_000_228_461n);
  assert.equal(spotOut(10n ** 18n, Q96, true), 10n ** 18n);
  // constant liquidity output never beats spot net, and approaches it for a small input
  const m = { sqrtPriceX96: sqrtFor(E(2)), liquidity: E(1000), lpFeePpm: 10_000, skimPpm: 0 };
  const small = inRangeOut(E('0.001'), m, true);
  const big = inRangeOut(E(10), m, true);
  assert.ok(small <= spotNetOut(E('0.001'), m, true) && small * 10_000n >= spotNetOut(E('0.001'), m, true) * 9999n);
  assert.ok(big * 100n < spotNetOut(E(10), m, true) * 99n, 'a large input pays impact');
  assert.ok(inRangeOut(E(10), m, false) < spotNetOut(E(10), m, false));
});

// KR-02: an rpc quote of 1 wei (or a zero floor) never sends run(true, 0)
test('KR-02 floor: max(sim minus slippage, spot net minus slippage and impact); no floor means no convert', () => {
  assert.deepEqual(floorQuote(1000n, 0n, 100, 100), { status: 'no_quote', minOut: 0n, simFloor: 990n, spotFloor: 0n });
  // the rpc says 1 wei, the pool says 0.6 eth: the floor is the pool's, above the quote, so no convert
  const q = args111([0n, 0n, 1n], 100, m111, p111fork);
  assert.equal(q.status, 'floor_above_quote');
  assert.deepEqual(q.args, [false, 0n]);
  // no market read (rpc failure): no convert
  assert.deepEqual(args111([0n, 0n, E(1)], 100, null, p111fork).args, [false, 0n]);
  // too much impact: the simulated output is under spot net minus 2%
  assert.equal(args111([0n, 0n, 600_000_000_000_000n], 100, m111, p111fork).status, 'floor_above_quote');
  // the amount in is capped at maxStepIn and scaled by the swapper's reward share
  const half = args111([0n, 0n, 648_951_817_551_513n / 2n], 100, { ...m111, swapperShareBps: 5000 }, p111fork);
  assert.equal(half.status, 'ok');
});

// LAYER: weth is currency1 on the live pool; this fake pool has weth as currency0, 1.51e25 LAYER per 1e18 weth
// (raw price 1.51e7) and deep liquidity
const mLayer = (o = {}) => ({ sqrtPriceX96: sqrtFor(15_100_000n * E(1)), liquidity: 10n ** 30n, lpFeePpm: 0, skimPpm: 0, wethIsToken0: true, ...o });
const pLayer = (o = {}) => ({ uncollectedLayer: 0n, uncollectedWeth: 0n, claimable: [0n, 0n, 0n, 0n], routerWeth: [0n, 0n, 0n], routerThreshold: [E('0.01'), E('0.01'), E('0.01')], controllerWeth: 0n, ...o });

test('LAYER rate math matches RunKeeperLayer.quoteRate', () => {
  // 293,849 LAYER for 0.0204 weth at 200 bps
  const wb = E('0.0204');
  const lb = E(293849);
  const expect = ((lb * 10n ** 18n) / wb) * 9800n / 10000n;
  assert.equal(rateFromSim(wb, lb, 200), expect);
  assert.equal(rateFromSim(0n, 5n, 200), 0n);
  const sim = [1n, 1n, 1n, E('0.02'), E(300_000)]; // 1.5e25 LAYER per weth
  const q = argsLayer(sim, 200, mLayer(), pLayer());
  assert.equal(q.status, 'ok');
  assert.deepEqual(q.args, [true, rateFromSim(E('0.02'), E(300_000), 200), true]);
  assert.deepEqual(argsLayer([1n, 1n, 1n, 0n, 0n], 200, mLayer(), pLayer()).args, [false, 0n, true]);
});

// KR-02 LAYER: a 1 wei LAYER quote against 1 weth burned never sends doBurn true with rate 0
test('KR-02 LAYER: rate 0 or a missing floor never burns', () => {
  assert.deepEqual(argsLayer([0n, 0n, 0n, E(1), 1n], 200, mLayer(), pLayer()).args, [false, 0n, true]);
  assert.equal(argsLayer([0n, 0n, 0n, E(1), 1n], 200, mLayer(), pLayer()).status, 'floor_above_quote');
  assert.equal(argsLayer([0n, 0n, 0n, E(1), E(1)], 200, null, pLayer()).status, 'no_quote');
  assert.equal(argsLayer([0n, 0n, 0n, E(1), E(1)], 200, mLayer({ sqrtPriceX96: 0n }), pLayer()).status, 'no_quote');
});

// KR-12: the rate is quoted for the largest router balance; a balance whose impact passes the allowance is not burned
test('KR-12 LAYER: rate from the largest router balance; impact above MAX_IMPACT_BPS sends doBurn false', () => {
  const thin = mLayer({ liquidity: 4n * 10n ** 23n }); // about 100 weth of virtual reserve: 2 weth moves the price 2%
  const sim = [0n, 0n, 0n, E('0.03'), E('0.03') * 15_100_000n]; // the simulated average is at spot
  const small = argsLayer(sim, 200, thin, pLayer({ routerWeth: [E('0.02'), E('0.01'), 0n] }));
  const large = argsLayer(sim, 200, thin, pLayer({ routerWeth: [E('0.02'), E(2), 0n] }));
  assert.equal(small.status, 'ok');
  assert.equal(large.largest, E(2));
  assert.ok(large.impactBps > 100, String(large.impactBps));
  assert.equal(large.status, 'impact_too_high');
  assert.deepEqual(large.args, [false, 0n, true]);
  // a medium router: burned, but at the rate its own impact allows, below the simulated average
  const mid = argsLayer(sim, 200, thin, pLayer({ routerWeth: [E('0.02'), E('0.5'), 0n] }));
  assert.equal(mid.status, 'ok');
  assert.ok(mid.estRate < mid.simRate && mid.rate <= mid.estRate);
});

// KR-03: one minOut must satisfy every converting swapper's own floor, else no convert and the blocker is named
test('KR-03 v2: per swapper floors, convert only when one minOut fits every swapper', () => {
  const tok = '0x4444444444444444444444444444444444444444';
  const A = '0x' + 'a'.repeat(40);
  const B = '0x' + 'b'.repeat(40);
  const sw = (address, accruedArtCoin, maxStepIn = E(1_000_000)) => ({ address, accruedArtCoin, maxStepIn, sqrtPriceX96: Q96, lpFeePpm: 0, skimPpm: 0 });
  // price 1: 1 coin wei buys 1 eth wei
  const same = argsV2(tok, [{ swapper: A, converted: E(1) }, { swapper: B, converted: E('0.999') }], 100, { swappers: [sw(A, E(1)), sw(B, E(1))] });
  assert.equal(same.status, 'ok');
  assert.deepEqual(same.args, [tok, true, E('0.99')]);
  const apart = argsV2(tok, [{ swapper: A, converted: E(1) }, { swapper: B, converted: E('0.001') }], 100, { swappers: [sw(A, E(1)), sw(B, E('0.001'))] });
  assert.equal(apart.status, 'floor_above_quote');
  assert.equal(apart.blockedBy, B);
  assert.deepEqual(apart.args, [tok, false, 0n]);
  // the step cap sizes the floor: 1 eth pending, 0.1 eth per step
  const step = argsV2(tok, [{ swapper: A, converted: E('0.1') }], 100, { swappers: [sw(A, E(1), E('0.1'))] });
  assert.deepEqual(step.args, [tok, true, E('0.099')]);
  // a swapper missing from the market read: no quote
  assert.equal(argsV2(tok, [{ swapper: A, converted: E(1) }], 100, { swappers: [] }).status, 'no_quote');
  assert.deepEqual(argsV2(tok, [{ swapper: A, converted: 0n }], 100, { swappers: [] }).args, [tok, false, 0n]);
  assert.deepEqual(argsV2(tok, [], 100, null).args, [tok, false, 0n]);
  assert.deepEqual(argsV2(tok, null, 100, null).args, [tok, false, 0n]);
});

test('progress, backoff, value and fee bump helpers', () => {
  const before = triggerMetrics('111', ['uncollected_coin', 'weekly'], p111({ uncollectedCoin: E(20_000) }));
  assert.deepEqual(before, { uncollected_coin: E(20_000) });
  assert.equal(progressMade(before, { uncollected_coin: E(10_000) }, 5000).ok, true);
  assert.deepEqual(progressMade(before, { uncollected_coin: E(10_001) }, 5000).failed, ['uncollected_coin']);
  assert.equal(progressMade({}, {}, 5000).ok, true); // weekly only
  assert.deepEqual(triggerMetrics('layer', ['router1_due', 'combined_weth'], pl({ routerWeth: [E(1), E(2), 0n], controllerWeth: 0n })), { router1_due: E(2), combined_weth: E(1) });
  assert.deepEqual([nextBackoff(0, 3600, 86400), nextBackoff(3600, 3600, 86400), nextBackoff(57600, 3600, 86400)], [3600, 7200, 86400]);
  assert.equal(bumpFee(8n), 9n);
  assert.equal(bumpFee(1_000_000_000n), 1_125_000_000n);
  assert.equal(pendingValueWei('111', p111({ uncollectedEth: 5n, escrowedEth: 7n }), null), 12n);
  assert.equal(pendingValueWei('layer', pl(), null), null);
});
