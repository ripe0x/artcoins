import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeAbiParameters, encodeErrorResult, encodeEventTopics, parseEther } from 'viem';
import { loadConfig } from '../config.mjs';
import { loadState } from '../state.mjs';
import { Metrics } from '../metrics.mjs';
import { tick } from '../runner.mjs';
import { SimRevert } from '../chain.mjs';
import { health } from '../server.mjs';
import { keeper111Abi, reasonsAbi } from '../abi.mjs';
import { realRegistry, baseEnv, tmpDir, silentLog, K111, KLAYER } from './helpers.mjs';

const E = (x) => parseEther(String(x));
const GWEI = 1_000_000_000n;
const idle111 = { uncollectedEth: 0n, uncollectedCoin: 0n, escrowedEth: 0n, swapperEth: 0n, swapperCoin: 0n };
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
    send: async (k, fn, args, fees) => {
      const hash = '0x' + String(io.sends.length + 1).padStart(64, '0');
      io.sends.push({ id: k.id, fn, args, fees, hash, nonce: io.nonce });
      const r = o.noReceipt ? null : io.mine(k);
      if (r) { io.receipts[hash] = r; io.nonce += 1; }
      return { hash, nonce: io.sends.at(-1).nonce, private: false };
    },
    waitReceipt: async (h) => io.receipts[h] ?? null,
    replayRevert: async () => ({ name: 'InsufficientGas', args: [1] }),
  };
  return io;
}

function ctxFor(io, envExtra = {}, dir = tmpDir()) {
  const cfg = loadConfig(baseEnv(dir, envExtra), realRegistry());
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
  const io = fakeIo({ now: 1_800_003_600, previews: { '111': { ...idle111, uncollectedCoin: E(10001) } } });
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
  assert.equal(health(ctx, io.t).keepers['111'].consecutiveReverts, 2);

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

test('dropped tx: cleared after DROP_AFTER_SECONDS or when the nonce moved', async () => {
  const dir = tmpDir();
  const io = fakeIo({ noReceipt: true });
  const ctx = ctxFor(io, { KEEPERS: '111' }, dir);
  await tick(ctx);
  io.t += 1801;
  await tick(ctx); // dropped, then sent again (timer still due)
  assert.equal(io.sends.length, 2);
  assert.equal(ctx.metrics.get('keeper_dropped_tx_total', { keeper: '111' }), 1);
  io.nonce = 5; // the pending nonce got used by something else
  io.t += 60;
  await tick(ctx);
  assert.equal(io.sends.length, 3);
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

test('healthz: ok while starting and after a tick, 503 when the loop is stale; metrics render', async () => {
  const io = fakeIo();
  const ctx = ctxFor(io);
  assert.equal(health(ctx, io.t).ok, true);
  assert.equal(health(ctx, io.t + 3 * 600 + 121).ok, false);
  await tick(ctx);
  const h = health(ctx, io.t + 10);
  assert.equal(h.ok, true);
  assert.equal(h.keepers['111'].lastResult, 'ok');
  assert.equal(h.keepers.layer.address, KLAYER);
  assert.equal(health(ctx, io.t + 3 * 600 + 121).ok, false);
  const m = ctx.metrics.render();
  assert.match(m, /^keeper_ticks_total 1$/m);
  assert.match(m, /^keeper_runs_total\{keeper="111"\} 1$/m);
  assert.match(m, /# TYPE keeper_key_balance_wei gauge/);
});
