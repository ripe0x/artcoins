import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeAbiParameters, encodeErrorResult, encodeEventTopics, parseEther } from 'viem';
import { loadConfig } from '../config.mjs';
import { loadState } from '../state.mjs';
import { Metrics } from '../metrics.mjs';
import { tick } from '../runner.mjs';
import { SimRevert } from '../chain.mjs';
import { bumpFee } from '../decide.mjs';
import { health, status } from '../server.mjs';
import { keeper111Abi, reasonsAbi } from '../abi.mjs';
import { realRegistry, baseEnv, tmpDir, silentLog, K111, KLAYER, Q96, sqrtFor } from './helpers.mjs';

const E = (x) => parseEther(String(x));
const GWEI = 1_000_000_000n;
// swapperCoin 1e6: the independent floor for the default 1e6 wei simulated convert (price 1, no fees)
const idle111 = { uncollectedEth: 0n, uncollectedCoin: 0n, escrowedEth: 0n, swapperEth: 0n, swapperCoin: 1_000_000n };
// pool state for the independent floor: 111 at price 1 coin per eth wei, LAYER at 1.51e25 LAYER per weth (deep)
const MARKET = {
  '111': { sqrtPriceX96: Q96, lpFeePpm: 0, skimPpm: 0, maxStepIn: 10n ** 30n, swapperShareBps: 10_000, coinIsToken0: false },
  layer: { sqrtPriceX96: sqrtFor(15_100_000n * 10n ** 18n), liquidity: 10n ** 30n, lpFeePpm: 0, skimPpm: 0, wethIsToken0: true, routerFloors: [1n, 1n, null] },
};
const idleLayer = { uncollectedLayer: 0n, uncollectedWeth: 0n, claimable: [0n, 0n, 0n, 0n], routerWeth: [0n, 0n, 0n], routerThreshold: [E('0.01'), E('0.01'), E('0.01')], controllerWeth: 0n };

function fakeIo(o = {}) {
  const io = {
    address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
    t: o.now ?? 1_800_000_000,
    nonce: 0,
    sends: [],
    sims: [],
    receipts: {},
    mine: o.mine ?? ((k) => ({ status: 'success', gasUsed: 800_000n, blockNumber: 100n, logs: [] })),
    previews: { '111': idle111, layer: idleLayer, ...(o.previews || {}) },
    now: () => io.t,
    getBlock: async () => ({ baseFeePerGas: o.baseFee ?? GWEI }),
    priorityEstimate: async () => GWEI / 10n,
    getBalance: async () => E('0.02'),
    getNonce: async () => io.nonce,
    getReceipt: async (h) => io.receipts[h] ?? null,
    read: async (k) => io.previews[k.kind],
    simulateZero: async (k) => {
      io.sims.push(k.id);
      if (o.simulate) return o.simulate(k);
      return k.kind === '111' ? [0n, 0n, 1_000_000n] : [0n, 0n, 0n, E('0.02'), E(300000)];
    },
    market: async (k) => (o.market === null ? null : (o.market ?? MARKET)[k.kind]),
    send: async (k, fn, args, fees, opts = {}) => {
      const hash = '0x' + String(io.sends.length + 1).padStart(64, '0');
      const nonce = opts.nonce ?? io.nonce;
      await opts.onSigned?.({ hash, nonce });
      io.sends.push({ id: k.id, fn, args, fees, hash, nonce });
      const r = o.noReceipt ? null : io.mine(k);
      if (r) { io.receipts[hash] = r; io.nonce += 1; }
      return { hash, nonce, private: false };
    },
    cancel: async (nonce, fees, opts = {}) => {
      const hash = '0x' + String(io.sends.length + 1).padStart(64, '0');
      await opts.onSigned?.({ hash, nonce });
      io.sends.push({ id: 'cancel', fees, hash, nonce });
      return { hash, nonce, private: false };
    },
    waitReceipt: async (h) => io.receipts[h] ?? null,
    replayRevert: async () => ({ name: 'InsufficientGas', args: [1] }),
  };
  return io;
}

// CHECK_INTERVAL_SECONDS 0: these tests drive ticks by hand; the cadence has its own tests below
function ctxFor(io, envExtra = {}, dir = tmpDir()) {
  const cfg = loadConfig(baseEnv(dir, { CHECK_INTERVAL_SECONDS: '0', ...envExtra }), realRegistry());
  return { cfg, io, state: loadState(cfg.statePath), metrics: new Metrics(), log: silentLog(), startedAt: io.t, dir };
}

test('first start: weekly timer runs both keepers with quoted args; a restart on the same state does not re run', async () => {
  const io = fakeIo();
  const ctx = ctxFor(io);
  const s = await tick(ctx);
  assert.deepEqual(io.sends.map((x) => [x.id, x.fn]), [['111', 'run'], ['layer', 'run']]);
  assert.deepEqual(io.sends[0].args, [true, 990_000n]); // 1e6 simulated convert minus 100 bps
  const rate = ((E(300000) * 10n ** 18n) / E('0.02')) * 9800n / 10000n;
  assert.deepEqual(io.sends[1].args, [true, rate, true]);
  assert.equal(io.sends[0].fees.maxFeePerGas, 2n * GWEI + GWEI / 10n);
  assert.equal(s.keepers['111'].result, 'ok');
  assert.deepEqual(s.keepers['111'].reasons, ['weekly']);
  assert.equal(ctx.state.keepers['111'].lastRunAt, io.t);
  assert.equal(ctx.state.inFlight, null);

  // restart: new process, same volume, an hour later
  const io2 = fakeIo({ now: io.t + 3600 });
  const ctx2 = { ...ctxFor(io2, {}, ctx.dir) };
  assert.equal(ctx2.state.keepers['111'].lastRunAt, io.t);
  const s2 = await tick(ctx2);
  assert.equal(io2.sends.length, 0);
  assert.equal(s2.keepers['111'].result, 'idle');
  assert.equal(s2.keepers.layer.result, 'idle');
  // a week later both are due again
  const io3 = fakeIo({ now: io.t + 7 * 24 * 3600 });
  await tick({ ...ctxFor(io3, {}, ctx.dir) });
  assert.equal(io3.sends.length, 2);
});

test('threshold trigger runs only that keeper', async () => {
  const dir = tmpDir();
  await tick(ctxFor(fakeIo(), {}, dir)); // seed timers
  // an hour later: due, but inside the 6 h minimum run interval (KR-01)
  const early = fakeIo({ now: 1_800_003_600, previews: { '111': { ...idle111, uncollectedCoin: E(10001) } } });
  assert.equal((await tick(ctxFor(early, {}, dir))).keepers['111'].result, 'min_interval');
  assert.equal(early.sends.length, 0);
  const io = fakeIo({ now: 1_800_000_000 + 6 * 3600, previews: { '111': { ...idle111, uncollectedCoin: E(10001) } } });
  const s = await tick(ctxFor(io, {}, dir));
  assert.deepEqual(io.sends.map((x) => x.id), ['111']);
  assert.deepEqual(s.keepers['111'].reasons, ['uncollected_coin']);
});

test('gas cap: due keepers are skipped, nothing simulated or sent', async () => {
  const io = fakeIo({ baseFee: 31n * GWEI });
  const ctx = ctxFor(io);
  const s = await tick(ctx);
  assert.equal(io.sims.length, 0);
  assert.equal(io.sends.length, 0);
  assert.equal(s.keepers['111'].result, 'gas_cap');
  assert.equal(ctx.metrics.get('keeper_gas_cap_skips_total', { keeper: '111' }), 1);
  assert.equal(ctx.state.keepers['111'].lastRunAt, null); // timer stays due
});

test('revert: not retried in the tick, cooldown, two in a row alerts', async () => {
  const dir = tmpDir();
  const reverted = () => ({ status: 'reverted', gasUsed: 700_000n, blockNumber: 100n, logs: [] });
  const io = fakeIo({ mine: reverted });
  const ctx = ctxFor(io, { KEEPERS: '111' }, dir);
  const s = await tick(ctx);
  assert.equal(io.sends.length, 1);
  assert.equal(s.keepers['111'].result, 'reverted');
  assert.equal(s.keepers['111'].reason, 'InsufficientGas(1: collect)');
  assert.equal(ctx.state.keepers['111'].consecutiveReverts, 1);
  assert.equal(ctx.state.keepers['111'].lastRunAt, null);

  io.t += 600; // next tick, inside the 1h cooldown
  assert.equal((await tick(ctx)).keepers['111'].result, 'cooldown');
  assert.equal(io.sends.length, 1);

  io.t += 3600; // after the cooldown: tries again, reverts again -> alert
  await tick(ctx);
  assert.equal(io.sends.length, 2);
  assert.equal(ctx.state.keepers['111'].consecutiveReverts, 2);
  assert.ok(ctx.log.lines.some((l) => l.level === 'error' && /two consecutive reverts/.test(l.msg)));
  assert.equal(status(ctx, io.t).keepers['111'].consecutiveReverts, 2);
  assert.ok(status(ctx, io.t).alerts.some((a) => a.alert === 'consecutive_reverts'));
  assert.deepEqual(ctx.state.keepers['111'].outcomes, { sent: 2, mined_reverted: 2 });

  io.mine = () => ({ status: 'success', gasUsed: 800_000n, blockNumber: 101n, logs: [] });
  io.t += 3600;
  await tick(ctx);
  assert.equal(ctx.state.keepers['111'].consecutiveReverts, 0);
  assert.equal(ctx.state.keepers['111'].lastRunAt, io.t);
});

test('simulation revert: logged, nothing sent', async () => {
  const io = fakeIo({ simulate: (k) => { throw new SimRevert(k.kind, { name: 'InsufficientGas', args: [5] }); } });
  const ctx = ctxFor(io, { KEEPERS: 'layer' });
  const s = await tick(ctx);
  assert.equal(io.sends.length, 0);
  assert.equal(s.keepers.layer.result, 'sim_revert');
  assert.equal(s.keepers.layer.error, 'InsufficientGas(5: processBurnWeth)');
});

test('no weth burned in the simulation: LAYER sends doBurn false; 111 with no convert sends doConvert false', async () => {
  const io = fakeIo({ simulate: (k) => (k.kind === '111' ? [5n, 0n, 0n] : [1n, 0n, 0n, 0n, 0n]) });
  await tick(ctxFor(io));
  assert.deepEqual(io.sends.map((x) => x.args), [[false, 0n], [false, 0n, true]]);
});

test('receipt timeout: tx stays in flight across ticks and restarts, next keeper waits', async () => {
  const dir = tmpDir();
  const io = fakeIo({ noReceipt: true });
  const ctx = ctxFor(io, {}, dir);
  const s = await tick(ctx);
  assert.deepEqual(io.sends.map((x) => x.id), ['111']); // layer not sent: one tx in flight at a time
  assert.equal(s.keepers['111'].result, 'pending');
  assert.equal(ctx.state.inFlight.keeper, '111');

  // restart while pending: the tick is skipped
  const io2 = fakeIo({ now: io.t + 600 });
  const ctx2 = ctxFor(io2, {}, dir);
  assert.equal((await tick(ctx2)).skipped, 'in_flight');
  assert.equal(io2.sends.length, 0);

  // mined meanwhile: settled from the persisted record, then the tick goes on (layer due, 111 just ran)
  io2.t += 600;
  io2.receipts[ctx2.state.inFlight.hash] = { status: 'success', gasUsed: 790_000n, blockNumber: 200n, logs: [] };
  io2.nonce = 1;
  const s3 = await tick(ctx2);
  assert.equal(ctx2.state.keepers['111'].lastRunAt, io.t);
  assert.equal(s3.keepers['111'].result, 'idle');
  assert.deepEqual(io2.sends.map((x) => x.id), ['layer']);
});

// KR-11 (a): nonce used but no receipt for any of our hashes: looked at for three ticks, then cleared as lost
test('nonce used without a receipt: kept three ticks, then cleared as lost and counted', async () => {
  const io = fakeIo({ noReceipt: true });
  const ctx = ctxFor(io, { KEEPERS: '111' });
  await tick(ctx);
  assert.equal(ctx.state.inFlight.nonce, 0);
  io.nonce = 5; // the nonce got used by something the rpc shows no receipt for
  for (let i = 0; i < 2; i++) {
    io.t += 600;
    assert.equal((await tick(ctx)).skipped, 'in_flight');
  }
  io.t += 600;
  await tick(ctx);
  assert.equal(ctx.state.keepers['111'].outcomes.lost, 1);
  assert.equal(ctx.metrics.get('keeper_tx_outcomes_total', { keeper: '111', outcome: 'lost' }), 1);
  assert.equal(io.sends.length, 2, 'the slot is free again: the still due keeper is sent');
  assert.equal(io.sends[1].nonce, 5);
});

test('skip events in the receipt are logged and counted', async () => {
  const reason = encodeErrorResult({ abi: reasonsAbi, errorName: 'ConvertTooEarly', args: [123n] });
  const logs = [{ address: K111, topics: encodeEventTopics({ abi: keeper111Abi, eventName: 'ConvertSkipped' }), data: encodeAbiParameters([{ type: 'bytes' }], [reason]) }];
  const io = fakeIo({ mine: () => ({ status: 'success', gasUsed: 700_000n, blockNumber: 1n, logs }) });
  const ctx = ctxFor(io, { KEEPERS: '111' });
  const s = await tick(ctx);
  assert.equal(s.keepers['111'].events[0].reason, 'ConvertTooEarly(123)');
  assert.equal(ctx.metrics.get('keeper_skipped_events_total', { keeper: '111', event: 'ConvertSkipped' }), 1);
  assert.ok(ctx.log.lines.some((l) => l.msg === 'step skipped' && l.reason === 'ConvertTooEarly(123)'));
});

test('DRY_RUN simulates and quotes but never sends; swapperEth raises an alert', async () => {
  const io = fakeIo({ previews: { '111': { ...idle111, swapperEth: 5n } } });
  const ctx = ctxFor(io, { DRY_RUN: '1' });
  const s = await tick(ctx);
  assert.equal(io.sends.length, 0);
  assert.equal(io.sims.length, 2);
  assert.equal(s.keepers['111'].result, 'dry_run');
  assert.equal(ctx.metrics.get('keeper_alerts_total', { keeper: '111', alert: 'swapper_eth_stranded' }), 1);
});

test('missing keeper address is reported, not fatal', async () => {
  const dir = tmpDir();
  const cfg = loadConfig({ ...baseEnv(dir), KEEPER_LAYER: '' }, realRegistry());
  const io = fakeIo();
  const s = await tick({ cfg, io, state: loadState(cfg.statePath), metrics: new Metrics(), log: silentLog() });
  assert.equal(s.keepers.layer.result, 'no_address');
  assert.equal(s.keepers['111'].result, 'ok');
});

test('healthz: ok while starting and after a tick, 503 when the loop is stale; status and metrics render', async () => {
  const io = fakeIo();
  const ctx = ctxFor(io);
  assert.equal(health(ctx, io.t).ok, true);
  assert.equal(health(ctx, io.t + 3 * 600 + 121).ok, false);
  await tick(ctx);
  const h = health(ctx, io.t + 10);
  assert.deepEqual(h, { ok: true, lastTickAgeSeconds: 10 });
  const st = status(ctx, io.t + 10);
  assert.equal(st.keepers['111'].lastResult, 'ok');
  assert.equal(st.keepers.layer.address, KLAYER);
  assert.equal(health(ctx, io.t + 3 * 600 + 121).ok, false);
  const m = ctx.metrics.render();
  assert.match(m, /^keeper_ticks_total 1$/m);
  assert.match(m, /^keeper_runs_total\{keeper="111"\} 1$/m);
  assert.match(m, /# TYPE keeper_key_balance_wei gauge/);
});

// KR-02 in the runner: a failed market read (no independent floor) runs without convert or burn
test('KR-02 no market read: 111 sends doConvert false, LAYER doBurn false, logged no_quote', async () => {
  const io = fakeIo({ market: null });
  const ctx = ctxFor(io);
  await tick(ctx);
  assert.deepEqual(io.sends.map((x) => x.args), [[false, 0n], [false, 0n, true]]);
  assert.equal(ctx.metrics.get('keeper_quote_status_total', { keeper: '111', status: 'no_quote' }), 1);
  assert.ok(ctx.log.lines.some((l) => l.msg === 'no_quote' && l.keeper === 'layer'));
});

// KR-14: each keeper is read on its runbook cadence (111 hourly, LAYER daily) while the loop ticks every 10 minutes
test('KR-14 cadence: 111 checked hourly, LAYER daily, runs spaced by the minimum run interval', async () => {
  const dir = tmpDir();
  const io = fakeIo();
  const ctx = ctxFor(io, { CHECK_INTERVAL_SECONDS: '' }, dir);
  const reads = [];
  const read = io.read;
  io.read = async (k) => { reads.push([k.id, io.t]); return read(k); };
  for (let i = 0; i < 6 * 25; i++) { await tick(ctx); io.t += 600; } // 25 hours
  const t0 = 1_800_000_000;
  // 111: a read per hour (plus the post run progress reads are not made for weekly runs)
  assert.equal(reads.filter(([id]) => id === '111').length, 25);
  assert.deepEqual(reads.filter(([id]) => id === 'layer').map(([, t]) => t - t0), [0, 86400]);
  assert.equal(io.sends.length, 2, 'weekly runs once each, nothing else is due');
  assert.equal(ctx.lastTick.keepers.layer.result, 'wait');
});

// KR-14 value rule: a threshold run worth less than its gas is skipped (not when the weekly timer is due)
test('KR-14 value vs gas: due on a threshold but worth less than the gas, skipped', async () => {
  const dir = tmpDir();
  await tick(ctxFor(fakeIo(), { KEEPERS: '111' }, dir)); // weekly run seeds the timer
  // 0.0201 eth uncollected at 30 gwei base: 900k gas costs 0.027 eth
  const io = fakeIo({ now: 1_800_000_000 + 7 * 3600, baseFee: 30n * GWEI, previews: { '111': { ...idle111, uncollectedEth: E('0.0201') } } });
  const s = await tick(ctxFor(io, { KEEPERS: '111', MAX_GAS_GWEI: '40' }, dir));
  assert.equal(s.keepers['111'].result, 'below_gas_value');
  assert.equal(io.sends.length, 0);
});

// KR-06: a key that cannot cover gas limit x max fee is not sent from (and no send_error every tick)
test('KR-06 insufficient funds: gas limit x max fee above the balance is not sent', async () => {
  const io = fakeIo({ baseFee: 5n * GWEI });
  io.getBalance = async () => E('0.02'); // 111 needs 1.2M x 10.1 gwei = 0.012 eth, LAYER 3.5M x 10.1 gwei = 0.035 eth
  const ctx = ctxFor(io);
  const s = await tick(ctx);
  assert.equal(s.keepers['111'].result, 'ok');
  assert.equal(s.keepers.layer.result, 'insufficient_funds');
  assert.deepEqual(io.sends.map((x) => x.id), ['111']);
  assert.equal(ctx.metrics.get('keeper_insufficient_funds_total', { keeper: 'layer' }), 1);
  assert.equal(ctx.metrics.get('keeper_send_errors_total', { keeper: 'layer' }), undefined);
});

// KR-11 (b): the tx is on disk before the broadcast; a definite reject clears it, an ambiguous error keeps it
test('KR-11 send outcomes: recorded before broadcast; ambiguous errors stay in flight, definite rejects clear', async () => {
  const dir = tmpDir();
  const io = fakeIo();
  let onDisk = null;
  io.send = async (k, fn, args, fees, opts) => {
    await opts.onSigned({ hash: '0x' + 'e'.repeat(64), nonce: 0 });
    onDisk = loadState(ctx.cfg.statePath).inFlight;
    const err = new Error('request timed out');
    err.ambiguous = true;
    throw err;
  };
  const ctx = ctxFor(io, { KEEPERS: '111' }, dir);
  const s = await tick(ctx);
  assert.equal(onDisk.hash, '0x' + 'e'.repeat(64));
  assert.equal(s.keepers['111'].result, 'send_unknown');
  assert.equal(ctx.state.inFlight.nonce, 0);
  assert.equal(ctx.state.keepers['111'].outcomes.send_unknown, 1);

  const io2 = fakeIo();
  io2.send = async (k, fn, args, fees, opts) => {
    await opts.onSigned({ hash: '0x' + 'f'.repeat(64), nonce: 0 });
    throw new Error('insufficient funds for gas * price + value');
  };
  const ctx2 = ctxFor(io2, { KEEPERS: '111' });
  assert.equal((await tick(ctx2)).keepers['111'].result, 'send_error');
  assert.equal(ctx2.state.inFlight, null);
  assert.equal(ctx2.state.keepers['111'].outcomes.send_error, 1);
});

// KR-04: never a new nonce while the node holds a tx from this key the state does not know
test('KR-04 foreign pending tx at the node: nothing is sent', async () => {
  const io = fakeIo();
  io.getNonce = async (tag) => (tag === 'pending' ? 4 : 3);
  const ctx = ctxFor(io);
  const s = await tick(ctx);
  assert.equal(io.sends.length, 0);
  assert.equal(s.keepers['111'].result, 'foreign_pending');
});

// KR-04: a run already at MAX_GAS_GWEI cannot be replaced under the cap, so the first timeout cancels it
test('KR-04 a stuck run at the fee cap is cancelled (cap 2 x MAX_GAS_GWEI), not replaced above the cap', async () => {
  const io = fakeIo({ noReceipt: true, baseFee: 3n * GWEI / 2n });
  const ctx = ctxFor(io, { KEEPERS: '111', MAX_GAS_GWEI: '3' });
  await tick(ctx);
  assert.equal(io.sends[0].fees.maxFeePerGas, 3n * GWEI);
  io.t += 1801;
  await tick(ctx);
  assert.equal(io.sends[1].id, 'cancel');
  assert.equal(io.sends[1].nonce, 0);
  assert.equal(io.sends[1].fees.maxFeePerGas, bumpFee(3n * GWEI));
  assert.ok(ctx.state.inFlight.cancel && ctx.state.inFlight.cancelHashes.length === 1);
  assert.equal(status(ctx, io.t).inFlight.cancelling, true);
});
