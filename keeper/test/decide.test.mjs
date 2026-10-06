import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseEther } from 'viem';
import {
  decide111, decideLayer, decideV2, weeklyDue, feeCaps, minOutFromSim, rateFromSim, args111, argsLayer, argsV2, combinedLayerWeth,
} from '../decide.mjs';

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

test('min out math matches RunKeeper111.quoteMinOut', () => {
  assert.equal(minOutFromSim(4_739_500_000_000_000n, 100), 4_692_105_000_000_000n);
  assert.equal(minOutFromSim(10_001n, 100), 9_900n); // floor division
  assert.equal(minOutFromSim(0n, 100), 0n);
  assert.deepEqual(args111([1n, 2n, 1_000_000n], 100), [true, 990_000n]);
  assert.deepEqual(args111([1n, 2n, 0n], 100), [false, 0n]); // nothing converted in the simulation: no unquoted convert
});

test('LAYER rate math matches RunKeeperLayer.quoteRate', () => {
  // 293,849 LAYER for 0.0204 weth at 200 bps
  const wb = E('0.0204');
  const lb = E(293849);
  const expect = ((lb * 10n ** 18n) / wb) * 9800n / 10000n;
  assert.equal(rateFromSim(wb, lb, 200), expect);
  assert.equal(rateFromSim(0n, 5n, 200), 0n);
  assert.deepEqual(argsLayer([1n, 1n, 1n, wb, lb], 200), [true, expect, true]);
  assert.deepEqual(argsLayer([1n, 1n, 1n, 0n, 0n], 200), [false, 0n, true]);
});

test('v2 min out: smallest nonzero convert minus slippage; no simulation means no convert', () => {
  const tok = '0x4444444444444444444444444444444444444444';
  assert.deepEqual(argsV2(tok, [{ converted: 0n }, { converted: 2000n }, { converted: 1000n }], 100), [tok, true, 990n]);
  assert.deepEqual(argsV2(tok, [{ converted: 0n }], 100), [tok, false, 0n]);
  assert.deepEqual(argsV2(tok, [], 100), [tok, false, 0n]);
  assert.deepEqual(argsV2(tok, null, 100), [tok, false, 0n]);
});
