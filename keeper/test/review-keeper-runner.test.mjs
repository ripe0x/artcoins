// independent review proofs (docs/v2/review/keeper-runner-review.md), flipped after the fixes: each test now
// asserts the fixed behaviour and keeps the finding id. fake chain only, no network.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { parseEther } from 'viem';
import { loadConfig } from '../config.mjs';
import { loadState } from '../state.mjs';
import { Metrics } from '../metrics.mjs';
import { tick } from '../runner.mjs';
import { health, status } from '../server.mjs';
import { argsV2 } from '../decide.mjs';
import { realRegistry, registryWithV2, baseEnv, tmpDir, silentLog, COIN_V2, Q96, sqrtFor } from './helpers.mjs';

const E = (x) => parseEther(String(x));
const GWEI = 1_000_000_000n;
const T0 = 1_800_000_000;
const HOUR = 3600;
const SELF = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';
const SWAPPER = '0x' + '5'.repeat(40);
const idle111 = { uncollectedEth: 0n, uncollectedCoin: 0n, escrowedEth: 0n, swapperEth: 0n, swapperCoin: 0n };
const idleLayer = { uncollectedLayer: 0n, uncollectedWeth: 0n, claimable: [0n, 0n, 0n, 0n], routerWeth: [0n, 0n, 0n], routerThreshold: [E('0.01'), E('0.01'), E('0.01')], controllerWeth: 0n };
// pool state for the independent floor: 111 and v2 at 1e-4 eth per coin, LAYER at 1.51e25 LAYER per weth
const COIN_PRICE = sqrtFor(10_000n * 10n ** 18n); // 10,000 coin per eth: token1 per token0
const MARKET = {
  '111': { sqrtPriceX96: COIN_PRICE, lpFeePpm: 0, skimPpm: 0, maxStepIn: E(1_000_000), swapperShareBps: 10_000, coinIsToken0: false },
  layer: { sqrtPriceX96: sqrtFor(15_100_000n * 10n ** 18n), liquidity: 10n ** 30n, lpFeePpm: 0, skimPpm: 0, wethIsToken0: true, routerFloors: [1n, 1n, null] },
};

/// fake chain with a mempool keyed by nonce: `latest` counts mined txs, `pending` adds the nonces still in the
/// pool. a same nonce send replaces the pool entry. `mineTxs` false keeps every tx pending (base fee above its
/// maxFee). previews are fixed unless `onMined` edits them.
function chain({ previews = {}, sim, mineTxs = true, onMined, market = MARKET } = {}) {
  const io = {
    address: SELF,
    t: T0, mined: 0, pool: new Map(), sends: [], receipts: {},
    previews: { '111': idle111, layer: idleLayer, v2: null, ...previews },
    now: () => io.t,
    getBlock: async () => ({ baseFeePerGas: GWEI }),
    priorityEstimate: async () => GWEI / 10n,
    getBalance: async () => E('0.05'),
    getNonce: async (tag = 'latest') => io.mined + (tag === 'pending' ? io.pool.size : 0),
    getReceipt: async (h) => io.receipts[h] ?? null,
    read: async (k) => io.previews[k.kind],
    market: async (k) => (typeof market === 'function' ? market(k) : market?.[k.kind] ?? null),
    simulateZero: async (k) => sim(k),
    send: async (k, fn, args, fees, opts = {}) => io.push({ id: k.id, fn, args, fees, to: k.address }, opts),
    cancel: async (nonce, fees, opts = {}) => io.push({ id: 'cancel', fees, to: SELF }, { ...opts, nonce }),
    async push(tx, opts) {
      const nonce = opts.nonce ?? (await io.getNonce('latest'));
      const hash = '0x' + String(io.sends.length + 1).padStart(64, '0');
      await opts.onSigned?.({ hash, nonce });
      io.sends.push({ ...tx, nonce, hash, at: io.t });
      io.pool.set(nonce, hash);
      if (mineTxs) io.mine(hash);
      return { hash, nonce, private: false };
    },
    mine(hash) {
      const tx = io.sends.find((s) => s.hash === hash);
      io.pool.delete(tx.nonce);
      io.mined += 1;
      io.receipts[hash] = { status: 'success', gasUsed: tx.id === 'cancel' ? 21_000n : 700_000n, blockNumber: 100n, logs: [] };
      if (tx.id !== 'cancel') onMined?.(io, tx);
    },
    waitReceipt: async (h) => io.receipts[h] ?? null,
    replayRevert: async () => ({ name: null, raw: '0x' }),
  };
  return io;
}

function ctxFor(io, env, reg = realRegistry(), dir = tmpDir()) {
  const cfg = loadConfig(baseEnv(dir, env), reg);
  return { cfg, io, state: loadState(cfg.statePath), metrics: new Metrics(), log: silentLog(), startedAt: io.t, dir };
}

async function runFor(ctx, seconds) {
  const end = ctx.io.t + seconds;
  for (; ctx.io.t < end; ctx.io.t += ctx.cfg.intervalSeconds) await tick(ctx);
}

const gaps = (sends) => sends.slice(1).map((s, i) => s.at - sends[i].at);

// KR-01 (was: 36 txs in 6 h): a run that does not clear its trigger is spaced by the minimum run interval and
// backs off; KR-01b: "due, simulation burned nothing" is its own alert
test('KR-01 LAYER: router due but the burn is skipped in simulation: one tx per 24 h, no_progress backoff, due_no_burn alert', async () => {
  const layer = { ...idleLayer, routerWeth: [E('0.02'), 0n, 0n] }; // router0 at 2x its threshold
  // simulation: collect and claims ran, weth burn skipped (SlippageFloorNotSet / stale floor / partial fill)
  const io = chain({ previews: { layer }, sim: () => [0n, 0n, 0n, 0n, 0n] });
  const ctx = ctxFor(io, { KEEPERS: 'layer' });
  await runFor(ctx, 6 * HOUR);
  assert.equal(io.sends.length, 1, 'one tx in six hours (was 36)');
  assert.equal(io.sends[0].args[0], false);
  assert.equal(ctx.metrics.get('keeper_alerts_total', { keeper: 'layer', alert: 'due_no_burn' }), 1);
  assert.equal(ctx.metrics.get('keeper_no_progress_total', { keeper: 'layer' }), 1);
  assert.ok(status(ctx, io.t).alerts.some((a) => a.alert === 'no_progress' && a.keeper === 'layer'));
  await runFor(ctx, 4 * 24 * HOUR);
  assert.ok(gaps(io.sends).every((g) => g >= 24 * HOUR), `at most one tx per day: ${gaps(io.sends)}`);
  assert.equal(io.sends.length, 5);
});

test('KR-01 v2: rpc without eth_simulateV1 never converts: one tx per 6 h, not one per tick', async () => {
  const v2 = { swappers: 1n, accruedPaired: 0n, accruedCoin: E(50_000), nextConvertibleBlock: 0n };
  const sw = { address: SWAPPER, accruedCoin: E(50_000), maxStepIn: E(1000), sqrtPriceX96: COIN_PRICE, lpFeePpm: 0, skimPpm: 0 };
  const io = chain({ previews: { v2 }, sim: () => null, market: { v2: { swappers: [sw] } } });
  const ctx = ctxFor(io, { KEEPERS: 'v2' }, registryWithV2());
  await runFor(ctx, HOUR);
  assert.equal(io.sends.length, 1, 'was 6 in an hour');
  assert.ok(io.sends.every((s) => s.args[0] === COIN_V2 && s.args[1] === false));
  await runFor(ctx, 23 * HOUR);
  assert.equal(io.sends.length, 4, 'a day: 0, 6, 12, 18 h');
});

test('KR-01 v2: convert paced (ConvertTooEarly / maxStepIn) leaves the trigger set: 4 runs a day, not 90', async () => {
  // the swapper converts at most maxStepIn per call and once per minBlocksBetweenConverts: 1,000 coin per run here
  let accrued = E(100_000);
  const sw = () => ({ address: SWAPPER, accruedCoin: accrued, maxStepIn: E(1000), sqrtPriceX96: COIN_PRICE, lpFeePpm: 0, skimPpm: 0 });
  const io = chain({
    previews: { v2: { swappers: 1n, accruedPaired: 0n, accruedCoin: accrued, nextConvertibleBlock: 0n } },
    sim: () => [{ swapper: SWAPPER, flushed: 0n, converted: E('0.1') }], // 1,000 coin at 1e-4 eth
    market: () => ({ swappers: [sw()] }),
    onMined: (c) => { accrued -= E(1000); c.previews.v2 = { ...c.previews.v2, accruedCoin: accrued }; },
  });
  const ctx = ctxFor(io, { KEEPERS: 'v2' }, registryWithV2());
  await runFor(ctx, 24 * HOUR);
  assert.equal(io.sends.length, 4, 'was 90 runs in a day');
  assert.ok(io.sends.every((s) => s.args[1] === true && s.args[2] === E('0.099')), 'each run still converts one quoted step');
  assert.equal(ctx.state.keepers['v2:CRED'].noProgress.reasons[0], 'accrued_coin');
});

// KR-01: the backoff doubles from 1 h to 24 h, and the weekly timer (due on every tick here) never overrides it
test('KR-01 backoff: no progress doubles the wait 1 h to 24 h; a due weekly timer does not override it; progress clears it', async () => {
  const v2 = { swappers: 1n, accruedPaired: 0n, accruedCoin: E(50_000), nextConvertibleBlock: 0n };
  const io = chain({ previews: { v2 }, sim: () => null, market: { v2: { swappers: [] } } });
  const ctx = ctxFor(io, { KEEPERS: 'v2', KEEPER_V2_MIN_RUN_INTERVAL_SECONDS: '0', CHECK_INTERVAL_SECONDS: '0', WEEKLY_SECONDS: '60' }, registryWithV2());
  await runFor(ctx, 4 * 24 * HOUR);
  assert.deepEqual(gaps(io.sends).slice(0, 7), [1, 2, 4, 8, 16, 24, 24].map((h) => h * HOUR));
  assert.ok(ctx.log.lines.some((l) => l.msg === 'due but backing off after a run without progress' && l.reasons.includes('weekly')));
  assert.ok(ctx.log.lines.some((l) => l.msg === 'no_progress'));
  // the trigger clears after the next run: backoff and alert reset
  const n = io.sends.length;
  ctx.io.t = ctx.state.keepers['v2:CRED'].backoffUntil;
  const settle = io.mine.bind(io);
  io.mine = (h) => { io.previews.v2 = { ...v2, accruedCoin: E(100) }; settle(h); };
  await tick(ctx);
  assert.equal(io.sends.length, n + 1);
  assert.equal(ctx.state.keepers['v2:CRED'].backoffUntil, null);
  assert.equal(ctx.state.keepers['v2:CRED'].noProgress, null);
});

// KR-02 (was: run(true, 0) and rate 0 with doBurn true): the pool floor overrules a 1 wei quote
test('KR-02 rpc controlled quote: a 1 wei simulated output never sends run(true, 0); LAYER never burns at rate 0', async () => {
  const p111 = { ...idle111, uncollectedCoin: E(20_000) };
  const io = chain({ previews: { '111': p111 }, sim: (k) => (k.kind === '111' ? [0n, 0n, 1n] : [0n, 0n, 0n, E(1), 1n]) });
  const ctx = ctxFor(io, { KEEPERS: '111,layer' });
  await tick(ctx);
  const s111 = io.sends.find((s) => s.id === '111');
  const sLayer = io.sends.find((s) => s.id === 'layer');
  assert.deepEqual(s111.args, [false, 0n], 'the 20,000 coin floor (about 2 eth) is above the 1 wei quote: no convert');
  assert.deepEqual(sLayer.args, [false, 0n, true], 'no weth burn at a rate the pool contradicts');
  assert.equal(ctx.metrics.get('keeper_quote_status_total', { keeper: '111', status: 'floor_above_quote' }), 1);
  // no market read at all (rpc down for it): still no convert, logged no_quote
  const io2 = chain({ previews: { '111': p111 }, sim: () => [0n, 0n, E(1)], market: null });
  const ctx2 = ctxFor(io2, { KEEPERS: '111' });
  await tick(ctx2);
  assert.deepEqual(io2.sends[0].args, [false, 0n]);
  assert.ok(ctx2.log.lines.some((l) => l.msg === 'no_quote'));
  // an honest quote near spot converts with minOut = max(sim floor, spot floor), never 0
  const io3 = chain({ previews: { '111': p111 }, sim: () => [0n, 0n, E('1.99')] });
  await tick(ctxFor(io3, { KEEPERS: '111' }));
  assert.deepEqual(io3.sends[0].args, [true, E('1.99') * 9900n / 10000n]);
});

// KR-03 (was: a 1 eth convert sent with a 0.00099 eth floor): per swapper floors, one minOut must fit them all
test('KR-03 v2: a 1 eth and a 0.001 eth swapper: no convert, the small one is named as the blocker', () => {
  const A = '0x' + 'a'.repeat(40);
  const B = '0x' + 'b'.repeat(40);
  const ev = [{ swapper: A, flushed: 0n, converted: E(1) }, { swapper: B, flushed: 0n, converted: E('0.001') }];
  const sw = (address, coin) => ({ address, accruedCoin: coin, maxStepIn: E(1e9), sqrtPriceX96: COIN_PRICE, lpFeePpm: 0, skimPpm: 0 });
  const q = argsV2(COIN_V2, ev, 100, { swappers: [sw(A, E(10_000)), sw(B, E(10))] });
  assert.equal(q.status, 'floor_above_quote');
  assert.equal(q.blockedBy, B);
  assert.deepEqual(q.args, [COIN_V2, false, 0n]);
  assert.ok(q.minOut > E('0.97'), 'the 1 eth swapper would get a floor near its own quote');
  // the same two swappers at similar sizes convert with the larger floor
  const ok = argsV2(COIN_V2, [{ swapper: A, converted: E(1) }, { swapper: B, converted: E('0.995') }], 100, { swappers: [sw(A, E(10_000)), sw(B, E(9_950))] });
  assert.deepEqual(ok.args, [COIN_V2, true, E('0.99')]);
});

// KR-04 (was: 9 runs queued at nonces 0 to 8): the stuck nonce is replaced at +12.5%, then cancelled; never nonce 1
test('KR-04 stuck tx: same nonce replacements at +12.5% up to 3, then a cancel to self; no new nonce meanwhile', async () => {
  const p111 = { ...idle111, uncollectedCoin: E(20_000) };
  const io = chain({ previews: { '111': p111 }, sim: () => [0n, 0n, E('1.99')], mineTxs: false });
  const ctx = ctxFor(io, { KEEPERS: '111' });
  await runFor(ctx, 6 * HOUR);
  assert.ok(io.sends.every((s) => s.nonce === 0), 'every tx at nonce 0');
  assert.equal(io.pool.size, 1, 'one tx in the pool for this key');
  const runs = io.sends.filter((s) => s.id === '111');
  const cancels = io.sends.filter((s) => s.id === 'cancel');
  assert.equal(runs.length, 4, 'the run plus 3 replacements');
  assert.ok(runs.every((s) => JSON.stringify(s.args, (_k, v) => String(v)) === JSON.stringify(runs[0].args, (_k, v) => String(v))), 'same calldata');
  assert.ok(cancels.length >= 1 && cancels.every((c) => c.to === SELF));
  const fees = io.sends.map((s) => s.fees.maxFeePerGas);
  for (let i = 1; i < fees.length; i++) assert.ok(fees[i] * 8n >= fees[i - 1] * 9n, `fee ${i} bumped at least 12.5%`);
  assert.ok(io.sends.map((s) => s.fees.maxPriorityFeePerGas).every((p, i, a) => i === 0 || p * 8n >= a[i - 1] * 9n));
  assert.deepEqual(gaps(io.sends).slice(0, 4), [2400, 2400, 2400, 2400], 'one action per PENDING_TIMEOUT_SECONDS');
  assert.equal(ctx.state.keepers['111'].outcomes.replaced, 3);
  assert.ok(ctx.state.keepers['111'].outcomes.cancel_sent >= 1);
  // the cancel mines: the slot frees, the run did not happen (timer unchanged), outcome recorded
  io.mine(cancels.at(-1).hash);
  await tick(ctx);
  assert.equal(ctx.state.keepers['111'].outcomes.cancelled, 1);
  assert.equal(ctx.state.keepers['111'].lastRunAt, null);
});

test('KR-04 stuck tx: a restart resumes the replacement count from the state file; a mined replacement settles the run', async () => {
  const p111 = { ...idle111, uncollectedCoin: E(20_000) };
  const io = chain({ previews: { '111': p111 }, sim: () => [0n, 0n, E('1.99')], mineTxs: false });
  const ctx = ctxFor(io, { KEEPERS: '111' });
  await runFor(ctx, 5400); // the run and 2 replacements
  assert.equal(ctx.state.inFlight.replacements, 2);
  assert.equal(ctx.state.inFlight.hashes.length, 3);
  // restart: a new process on the same volume, 40 minutes later
  io.t += 2400;
  const ctx2 = { ...ctxFor(io, { KEEPERS: '111' }, realRegistry(), ctx.dir) };
  assert.equal(ctx2.state.inFlight.replacements, 2);
  await tick(ctx2);
  assert.equal(io.sends.length, 4);
  assert.equal(io.sends[3].id, '111', 'the third replacement, not a new run');
  assert.equal(io.sends[3].nonce, 0);
  // an earlier hash of the same nonce mines: settled as the run, sent time kept from the first send
  io.mine(io.sends[1].hash);
  io.t += 600;
  await tick(ctx2);
  assert.equal(ctx2.state.keepers['111'].lastRunAt, T0);
  assert.equal(ctx2.state.keepers['111'].outcomes.mined_ok, 1);
  assert.equal(ctx2.state.keepers['111'].lastTx, io.sends[1].hash);
  assert.equal(ctx2.state.inFlight, null);
});

// KR-05 (was: /healthz published the in flight tx and the schedule): public health is ok plus tick age only
test('KR-05 /healthz says only ok and the tick age; /status never shows an unmined tx hash or its args', async () => {
  const p111 = { ...idle111, uncollectedCoin: E(20_000) };
  const io = chain({ previews: { '111': p111 }, sim: () => [0n, 0n, E('1.99')], mineTxs: false });
  const ctx = ctxFor(io, { KEEPERS: '111', PRIVATE_RPC_URL: 'https://rpc.flashbots.net/fast', STATUS_TOKEN: 'x'.repeat(32) });
  await tick(ctx);
  assert.deepEqual(health(ctx, io.t + 5), { ok: true, lastTickAgeSeconds: 5 });
  const text = JSON.stringify(status(ctx, io.t + 5), (_k, v) => (typeof v === 'bigint' ? v.toString() : v));
  assert.ok(!text.includes(io.sends[0].hash), 'no hash of the pending tx');
  assert.ok(!text.includes((E('1.99') * 9900n / 10000n).toString()), 'no minOut of the pending tx');
  assert.deepEqual(JSON.parse(text).inFlight, { keeper: '111', nonce: 0, ageSeconds: 5, replacements: 0, cancelling: false });
  assert.equal(ctx.lastTick.keepers['111'].hash, undefined);
});

// KR-07 (was: TRUE / yes / on ran live): DRY_RUN fails closed
test('KR-07 DRY_RUN=TRUE / yes / on is a dry run', () => {
  for (const v of ['TRUE', 'True', 'yes', 'on', ' 1']) {
    assert.equal(loadConfig(baseEnv(tmpDir(), { DRY_RUN: v }), realRegistry()).dryRun, true, v);
  }
});

// KR-13: base image pinned by digest, a stray keeper/.env never reaches the builder, no mkdir of a missing volume
test('KR-13 image hygiene: digest pinned base, .env excluded from the build context', () => {
  const docker = fs.readFileSync(new URL('../Dockerfile', import.meta.url), 'utf8');
  assert.match(docker, /^FROM node:22-alpine@sha256:[0-9a-f]{64}$/m);
  assert.match(docker, /volume not mounted/, 'KR-10: the start command refuses a missing volume dir');
  assert.doesNotMatch(docker, /mkdir -p/, 'KR-10: no unconditional mkdir of the state dir');
  const ignore = fs.readFileSync(new URL('../.dockerignore', import.meta.url), 'utf8');
  assert.match(ignore, /^keeper\/\.env\*$/m);
});
