// independent review proofs (docs/v2/review/keeper-runner-review.md). fake chain only, no network.
// each test asserts the CURRENT behaviour that the finding describes; a fix should flip the assertion.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseEther } from 'viem';
import { loadConfig } from '../config.mjs';
import { loadState } from '../state.mjs';
import { Metrics } from '../metrics.mjs';
import { tick } from '../runner.mjs';
import { health } from '../server.mjs';
import { argsV2 } from '../decide.mjs';
import { realRegistry, registryWithV2, baseEnv, tmpDir, silentLog, COIN_V2 } from './helpers.mjs';

const E = (x) => parseEther(String(x));
const GWEI = 1_000_000_000n;
const T0 = 1_800_000_000;
const idle111 = { uncollectedEth: 0n, uncollectedCoin: 0n, escrowedEth: 0n, swapperEth: 0n, swapperCoin: 0n };
const idleLayer = { uncollectedLayer: 0n, uncollectedWeth: 0n, claimable: [0n, 0n, 0n, 0n], routerWeth: [0n, 0n, 0n], routerThreshold: [E('0.01'), E('0.01'), E('0.01')], controllerWeth: 0n };

/// fake chain with a mempool: `latest` nonce counts mined txs, `pending` adds the txs still in the pool.
/// `mineTxs` false keeps every tx pending (base fee above its maxFee). previews are fixed unless `onMined` edits them.
function chain({ previews = {}, sim, mineTxs = true, onMined } = {}) {
  const io = {
    address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
    t: T0, mined: 0, pool: [], sends: [], receipts: {},
    previews: { '111': idle111, layer: idleLayer, v2: null, ...previews },
    now: () => io.t,
    getBlock: async () => ({ baseFeePerGas: GWEI }),
    priorityEstimate: async () => GWEI / 10n,
    getBalance: async () => E('0.03'),
    getNonce: async (tag = 'latest') => io.mined + (tag === 'pending' ? io.pool.length : 0),
    getReceipt: async (h) => io.receipts[h] ?? null,
    read: async (k) => io.previews[k.kind],
    simulateZero: async (k) => sim(k),
    send: async (k, fn, args, fees) => {
      const nonce = await io.getNonce('pending');
      const hash = '0x' + String(io.sends.length + 1).padStart(64, '0');
      io.sends.push({ id: k.id, fn, args, nonce, hash, at: io.t });
      if (mineTxs) {
        io.mined += 1;
        io.receipts[hash] = { status: 'success', gasUsed: 700_000n, blockNumber: 100n, logs: [] };
        onMined?.(io, k);
      } else {
        io.pool.push(hash);
      }
      return { hash, nonce, private: false };
    },
    waitReceipt: async (h) => io.receipts[h] ?? null,
    replayRevert: async () => ({ name: null, raw: '0x' }),
  };
  return io;
}

function ctxFor(io, env, reg = realRegistry()) {
  const cfg = loadConfig(baseEnv(tmpDir(), env), reg);
  return { cfg, io, state: loadState(cfg.statePath), metrics: new Metrics(), log: silentLog(), startedAt: io.t };
}

async function runFor(ctx, seconds) {
  const end = ctx.io.t + seconds;
  for (; ctx.io.t < end; ctx.io.t += ctx.cfg.intervalSeconds) await tick(ctx);
}

// KR-01: a run that succeeds but skips the step that would clear its trigger is resent every tick, forever
test('KR-01 LAYER: router due but the burn is skipped in simulation, a doBurn false run is sent every 10 minutes', async () => {
  const layer = { ...idleLayer, routerWeth: [E('0.02'), 0n, 0n] }; // router0 at 2x its threshold
  // simulation: collect and claims ran, weth burn skipped (SlippageFloorNotSet / stale floor / partial fill)
  const io = chain({ previews: { layer }, sim: () => [0n, 0n, 0n, 0n, 0n] });
  const ctx = ctxFor(io, { KEEPERS: 'layer' });
  await runFor(ctx, 6 * 3600);
  assert.equal(io.sends.length, 36, 'one tx per tick for six hours');
  assert.ok(io.sends.every((s) => s.args[0] === false), 'never burns, so routerWeth never drops');
  assert.ok(ctx.state.keepers.layer.lastResult === 'ok');
  // at 0.69M gas (measured idle LAYER run) and 1 gwei: 144 * 0.00069 = 0.099 eth a day, a 0.03 eth key lasts about 7 hours
});

test('KR-01 v2: rpc without eth_simulateV1 never converts, accruedArtCoin stays above 10,000, sent every tick', async () => {
  const v2 = { swappers: 1n, accruedPaired: 0n, accruedArtCoin: E(50_000), nextConvertibleBlock: 0n };
  const io = chain({ previews: { v2 }, sim: () => null });
  const ctx = ctxFor(io, { KEEPERS: 'v2' }, registryWithV2());
  await runFor(ctx, 3600);
  assert.equal(io.sends.length, 6);
  assert.ok(io.sends.every((s) => s.args[0] === COIN_V2 && s.args[1] === false));
});

test('KR-01 v2: convert paced (ConvertTooEarly / maxStepIn) leaves the trigger set, a run every tick', async () => {
  // the swapper converts at most maxStepIn per call and once per minBlocksBetweenConverts: 1,000 coin per run here
  let accrued = E(100_000);
  const io = chain({
    previews: { v2: { swappers: 1n, accruedPaired: 0n, accruedArtCoin: accrued, nextConvertibleBlock: 0n } },
    sim: () => [{ swapper: '0x' + '5'.repeat(40), flushed: 0n, converted: E('0.0001') }],
    onMined: (c) => { accrued -= E(1000); c.previews.v2 = { ...c.previews.v2, accruedArtCoin: accrued }; },
  });
  const ctx = ctxFor(io, { KEEPERS: 'v2' }, registryWithV2());
  await runFor(ctx, 24 * 3600);
  assert.equal(io.sends.length, 90, '90 runs in a day until accrued falls to the 10,000 threshold');
});

// KR-02: the rpc that quotes also sets min out. a 1 wei simulated convert rounds to minOut 0
test('KR-02 rpc controlled quote: 1 wei simulated output sends run(true, 0); LAYER rate rounds to 0 with doBurn true', async () => {
  const p111 = { ...idle111, uncollectedCoin: E(20_000) };
  const io = chain({ previews: { '111': p111 }, sim: (k) => (k.kind === '111' ? [0n, 0n, 1n] : [0n, 0n, 0n, E(1), 1n]) });
  const ctx = ctxFor(io, { KEEPERS: '111,layer' });
  await tick(ctx);
  const s111 = io.sends.find((s) => s.id === '111');
  const sLayer = io.sends.find((s) => s.id === 'layer');
  assert.deepEqual(s111.args, [true, 0n], 'convert with no runner floor, only the swapper floor on the in tx spot');
  assert.deepEqual(sLayer.args, [true, 0n, true], 'weth burn with rate 0, router 0x0EB2 then gets minOut 0');
});

// KR-03: one minOut for every swapper of a v2 coin, sized by the smallest convert
test('KR-03 v2 min out is the smallest convert: a 1 eth convert is sent with a 0.00099 eth floor', () => {
  const ev = [
    { swapper: '0x' + 'a'.repeat(40), flushed: 0n, converted: E(1) },
    { swapper: '0x' + 'b'.repeat(40), flushed: 0n, converted: E('0.001') },
  ];
  const [, doConvert, minOut] = argsV2(COIN_V2, ev, 100);
  assert.equal(doConvert, true);
  assert.equal(minOut, E('0.00099'));
  assert.ok(minOut * 1000n < E(1), 'the 1 eth swapper is protected by under 0.1% of its quote');
});

// KR-04: a dropped (still pending) public tx is forgotten; the next run queues behind it at nonce + 1
test('KR-04 stuck tx: after DROP_AFTER_SECONDS a new run is signed at the pending nonce, runs stack up unmined', async () => {
  const p111 = { ...idle111, uncollectedCoin: E(20_000) };
  const io = chain({ previews: { '111': p111 }, sim: () => [0n, 0n, E('0.001')], mineTxs: false });
  const ctx = ctxFor(io, { KEEPERS: '111' });
  await runFor(ctx, 6 * 3600);
  assert.deepEqual(io.sends.map((s) => s.nonce), [0, 1, 2, 3, 4, 5, 6, 7, 8]);
  assert.equal(io.pool.length, 9, 'nine run txs queued for one key, all mine when the base fee falls');
  assert.equal(io.mined, 0);
  // no replacement at the stuck nonce is ever sent (no fee bump, no cancel)
  assert.equal(new Set(io.sends.map((s) => s.nonce)).size, io.sends.length);
});

// KR-05: the public /healthz leaks the private relay tx while it is pending
test('KR-05 /healthz publishes the in flight tx (hash, nonce, minOut) and the tick schedule', async () => {
  const p111 = { ...idle111, uncollectedCoin: E(20_000) };
  const io = chain({ previews: { '111': p111 }, sim: () => [0n, 0n, E('0.5')], mineTxs: false });
  const ctx = ctxFor(io, { KEEPERS: '111', PRIVATE_RPC_URL: 'https://rpc.flashbots.net/fast' });
  await tick(ctx);
  const h = JSON.parse(JSON.stringify(health(ctx, io.t + 5), (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
  assert.equal(h.inFlight.hash, io.sends[0].hash);
  assert.equal(h.inFlight.fn, 'run');
  assert.deepEqual(h.inFlight.args, [true, (E('0.5') * 9900n / 10000n).toString()]);
  assert.equal(typeof h.lastTickAt, 'number');
  assert.equal(h.intervalSeconds, 600);
  assert.ok(h.address && h.balance);
});

// KR-07 (low, cheap to prove): DRY_RUN only accepts exactly "1" or "true"
test('KR-07 DRY_RUN=TRUE / yes / on is live', () => {
  for (const v of ['TRUE', 'True', 'yes', 'on', ' 1']) {
    assert.equal(loadConfig(baseEnv(tmpDir(), { DRY_RUN: v }), realRegistry()).dryRun, false, v);
  }
});
