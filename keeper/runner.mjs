// One tick: resolve the tx in flight, read every keeper's preview, decide, quote by simulation, send one tx at
// a time, wait for the receipt, decode its events, persist state. All chain access goes through `io`.
import { decide111, decideLayer, decideV2, feeCaps, args111, argsLayer, argsV2 } from './decide.mjs';
import { decodeKeeperLogs, describeError } from './events.mjs';
import { SimRevert, runCall } from './chain.mjs';
import { keeperState, saveState } from './state.mjs';
import * as L from './log.mjs';

export function decideFor(k, preview, cfg, st, now) {
  const timer = { lastRunAt: st.lastRunAt, now, weeklySeconds: cfg.weeklySeconds };
  if (k.kind === '111') return decide111(preview, cfg.thresholds['111'], timer);
  if (k.kind === 'layer') return decideLayer(preview, preview.controllerWeth, cfg.thresholds.layer, timer);
  return decideV2(preview, cfg.thresholds.v2, timer);
}

export function argsFor(k, sim) {
  if (k.kind === '111') return args111(sim, k.slippageBps);
  if (k.kind === 'layer') return argsLayer(sim, k.slippageBps);
  return argsV2(k.token, sim, k.slippageBps);
}

/// ctx: { cfg, io, state, metrics, log? }. Returns a summary per keeper (also kept on ctx.lastTick).
export async function tick(ctx) {
  const { cfg, io, state, metrics } = ctx;
  const log = ctx.log || L;
  const save = () => saveState(cfg.statePath, state);
  const now = io.now();
  const summary = { at: now, keepers: {} };
  metrics.inc('keeper_ticks_total');

  // 1. one tx in flight at a time: settle the previous one before anything else
  if (state.inFlight) {
    const f = state.inFlight;
    const k = cfg.keepers.find((x) => x.id === f.keeper);
    const receipt = await io.getReceipt(f.hash);
    if (receipt) {
      log.info('in flight tx mined', { keeper: f.keeper, hash: f.hash, status: receipt.status });
      if (k) await settle(ctx, k, f, receipt);
      state.inFlight = null;
      save();
    } else if ((await io.getNonce('latest')) > f.nonce) {
      log.warn('in flight tx replaced or dropped (nonce used)', { keeper: f.keeper, hash: f.hash, nonce: f.nonce });
      state.inFlight = null;
      save();
    } else if (now - f.sentAt > cfg.dropAfterSeconds) {
      log.warn('in flight tx not mined, giving up on it', { keeper: f.keeper, hash: f.hash, ageSeconds: now - f.sentAt });
      metrics.inc('keeper_dropped_tx_total', { keeper: f.keeper });
      state.inFlight = null;
      save();
    } else {
      log.info('tx still in flight, skipping tick', { keeper: f.keeper, hash: f.hash, ageSeconds: now - f.sentAt });
      metrics.inc('keeper_inflight_skips_total');
      summary.skipped = 'in_flight';
      return finish(ctx, summary, now);
    }
  }

  // 2. gas price and key balance
  const block = await io.getBlock();
  const fees = feeCaps({ baseFeePerGas: block.baseFeePerGas ?? 0n, priorityEstimate: await io.priorityEstimate(), capWei: cfg.maxGasWei, maxPriorityWei: cfg.maxPriorityWei });
  metrics.set('keeper_base_fee_wei', {}, block.baseFeePerGas ?? 0n);
  const balance = await io.getBalance();
  metrics.set('keeper_key_balance_wei', {}, balance);
  summary.balance = balance;
  if (balance < cfg.lowBalanceWei) log.warn('keeper key balance low, fund it', { address: io.address, balance });
  if (balance > cfg.highBalanceWei) log.warn('keeper key holds more than the hot key limit', { address: io.address, balance });

  // 3. keepers, in order, one tx at a time
  for (const k of cfg.keepers) {
    const st = keeperState(state, k.id);
    const r = (summary.keepers[k.id] = { result: null });
    const result = (res, extra = {}) => {
      Object.assign(r, { result: res, ...extra });
      st.lastResult = res;
      metrics.inc('keeper_results_total', { keeper: k.id, result: res });
    };
    if (!k.address) {
      result('no_address');
      log.warn('keeper has no address (registry entry or env override missing)', { keeper: k.id });
      continue;
    }
    let preview;
    try {
      preview = await io.read(k);
    } catch (err) {
      result('read_error', { error: err.shortMessage || err.message });
      metrics.inc('keeper_rpc_errors_total', { keeper: k.id });
      log.error('preview read failed', { keeper: k.id, error: err.shortMessage || err.message });
      continue;
    }
    r.preview = preview;
    if (k.kind === '111') metrics.set('keeper_111_swapper_eth_wei', {}, preview.swapperEth);
    const d = decideFor(k, preview, cfg, st, now);
    r.reasons = d.reasons;
    for (const a of d.alerts) {
      metrics.inc('keeper_alerts_total', { keeper: k.id, alert: a });
      log.warn('alert', { keeper: k.id, alert: a, preview });
    }
    log.info('preview', { keeper: k.id, preview, run: d.run, reasons: d.reasons });
    if (!d.run) { result('idle'); continue; }
    if (st.lastRevertAt && now - st.lastRevertAt < cfg.revertCooldownSeconds) {
      result('cooldown');
      log.warn('due but in revert cooldown', { keeper: k.id, lastRevertAt: st.lastRevertAt, consecutiveReverts: st.consecutiveReverts });
      continue;
    }
    if (!fees.ok) {
      result('gas_cap');
      metrics.inc('keeper_gas_cap_skips_total', { keeper: k.id });
      log.warn('due but base fee above MAX_GAS_GWEI, skipping', { keeper: k.id, baseFeePerGas: fees.baseFeePerGas, capWei: fees.capWei });
      continue;
    }

    // quote: simulate with minOut / rate 0, apply slippage
    st.lastAttemptAt = now;
    let sim;
    try {
      sim = await io.simulateZero(k);
    } catch (err) {
      if (err instanceof SimRevert) {
        result('sim_revert', { error: err.description });
        metrics.inc('keeper_sim_reverts_total', { keeper: k.id });
        log.error('simulation reverted, not sending', { keeper: k.id, error: err.description });
      } else {
        result('rpc_error', { error: err.shortMessage || err.message });
        metrics.inc('keeper_rpc_errors_total', { keeper: k.id });
        log.error('simulation failed', { keeper: k.id, error: err.shortMessage || err.message });
      }
      save();
      continue;
    }
    if (k.kind === 'v2' && sim === null) log.warn('rpc has no eth_simulateV1, sending without convert', { keeper: k.id });
    const args = argsFor(k, sim);
    const [fn] = runCall(k, args);
    r.args = args;
    log.info('quoted', { keeper: k.id, simulated: sim, fn, args });
    if (cfg.dryRun) { result('dry_run'); save(); continue; }

    // send and wait. never resend in this tick
    let sent;
    try {
      sent = await io.send(k, fn, args, fees);
    } catch (err) {
      result('send_error', { error: err.shortMessage || err.message });
      metrics.inc('keeper_send_errors_total', { keeper: k.id });
      log.error('send failed', { keeper: k.id, error: err.details || err.shortMessage || err.message });
      save();
      continue;
    }
    state.inFlight = { keeper: k.id, hash: sent.hash, nonce: sent.nonce, sentAt: now, fn, args };
    metrics.inc('keeper_txs_sent_total', { keeper: k.id });
    log.info('sent', { keeper: k.id, hash: sent.hash, nonce: sent.nonce, private: sent.private, gas: k.gas, maxFeePerGas: fees.maxFeePerGas });
    save();
    const receipt = await io.waitReceipt(sent.hash, cfg.receiptTimeoutSeconds * 1000);
    if (!receipt) {
      result('pending', { hash: sent.hash });
      log.warn('receipt timeout, tx stays in flight', { keeper: k.id, hash: sent.hash });
      summary.skipped = 'in_flight';
      break; // one tx in flight at a time: the rest waits for the next tick
    }
    Object.assign(r, await settle(ctx, k, state.inFlight, receipt));
    state.inFlight = null;
    save();
  }
  return finish(ctx, summary, now);
}

/// records a mined tx: success resets the weekly timer, a revert counts toward the two in a row alert
async function settle(ctx, k, f, receipt) {
  const { state, metrics, io, cfg } = ctx;
  const log = ctx.log || L;
  const st = keeperState(state, k.id);
  st.lastTx = f.hash;
  const out = { hash: f.hash, gasUsed: receipt.gasUsed, block: receipt.blockNumber };
  metrics.set('keeper_last_gas_used', { keeper: k.id }, receipt.gasUsed);
  if (receipt.status === 'success') {
    st.lastRunAt = f.sentAt;
    st.consecutiveReverts = 0;
    st.lastRevertAt = null;
    st.lastResult = 'ok';
    const events = decodeKeeperLogs(receipt.logs, k.kind, k.address);
    for (const e of events.filter((x) => x.skipped)) {
      metrics.inc('keeper_skipped_events_total', { keeper: k.id, event: e.event });
      log.warn('step skipped', { keeper: k.id, event: e.event, step: e.step, reason: e.reason, hash: f.hash });
    }
    metrics.inc('keeper_runs_total', { keeper: k.id });
    metrics.inc('keeper_results_total', { keeper: k.id, result: 'ok' });
    log.info('run ok', { keeper: k.id, hash: f.hash, gasUsed: receipt.gasUsed, events: events.map((e) => ({ event: e.event, args: e.args, reason: e.reason })) });
    return { ...out, result: 'ok', events };
  }
  st.consecutiveReverts += 1;
  st.lastRevertAt = f.sentAt;
  st.lastResult = 'reverted';
  metrics.inc('keeper_reverts_total', { keeper: k.id });
  metrics.inc('keeper_results_total', { keeper: k.id, result: 'reverted' });
  metrics.set('keeper_consecutive_reverts', { keeper: k.id }, st.consecutiveReverts);
  const reason = describeError(await io.replayRevert(k, f.fn, f.args, receipt.blockNumber), k.kind);
  const level = st.consecutiveReverts >= 2 ? 'error' : 'warn';
  (level === 'error' ? log.error : log.warn)(st.consecutiveReverts >= 2 ? 'ALERT two consecutive reverts' : 'run reverted', {
    keeper: k.id, hash: f.hash, reason, consecutiveReverts: st.consecutiveReverts, cooldownSeconds: cfg.revertCooldownSeconds,
  });
  return { ...out, result: 'reverted', reason };
}

function finish(ctx, summary, now) {
  ctx.state.lastTickAt = now;
  ctx.metrics.set('keeper_last_tick_timestamp', {}, now);
  for (const [id, s] of Object.entries(ctx.state.keepers)) {
    ctx.metrics.set('keeper_consecutive_reverts', { keeper: id }, s.consecutiveReverts);
    if (s.lastRunAt) ctx.metrics.set('keeper_last_run_timestamp', { keeper: id }, s.lastRunAt);
  }
  saveState(ctx.cfg.statePath, ctx.state);
  ctx.lastTick = summary;
  return summary;
}
