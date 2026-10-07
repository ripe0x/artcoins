// One tick: resolve the tx in flight (settle, replace or cancel it), read the previews of the keepers whose check
// is due, decide, quote by simulation plus an independent pool floor, send one tx at a time, wait for the receipt,
// decode its events, check the run made progress, persist state. All chain access goes through `io`.
import {
  decide111, decideLayer, decideV2, feeCaps, args111, argsLayer, argsV2, triggerMetrics, progressMade, nextBackoff,
  pendingValueWei, bumpFee,
} from './decide.mjs';
import { decodeKeeperLogs, describeError } from './events.mjs';
import { SimRevert, runCall } from './chain.mjs';
import { keeperState, saveState } from './state.mjs';
import * as L from './log.mjs';

const errMsg = (err) => err?.shortMessage || err?.message || String(err);
const maxB = (a, b) => (a > b ? a : b);
// results after which the keeper is checked again on the next tick instead of after its check interval
const RETRY_NEXT_TICK = new Set(['read_error', 'gas_cap', 'rpc_error', 'insufficient_funds', 'foreign_pending', 'send_unknown']);
// quote statuses that are not worth a warning (the simulation itself found nothing to convert or burn)
const QUIET_QUOTES = new Set(['ok', 'no_convert', 'no_burn']);

export function decideFor(k, preview, cfg, st, now) {
  const timer = { lastRunAt: st.lastRunAt, now, weeklySeconds: cfg.weeklySeconds };
  if (k.kind === '111') return decide111(preview, cfg.thresholds['111'], timer);
  if (k.kind === 'layer') return decideLayer(preview, preview.controllerWeth, cfg.thresholds.layer, timer);
  return decideV2(preview, cfg.thresholds.v2, timer);
}

/// quote with the independent floor: { args, status, ... } (decide.mjs args111 / argsLayer / argsV2)
export function argsFor(k, sim, market, preview, cfg) {
  const impact = cfg?.maxImpactBps ?? 100;
  if (k.kind === '111') return args111(sim, k.slippageBps, market, preview, impact);
  if (k.kind === 'layer') return argsLayer(sim, k.slippageBps, market, preview, impact);
  return argsV2(k.token, sim, k.slippageBps, market, impact);
}

/// KR-11: every send and receipt outcome lands in the state file and in `keeper_tx_outcomes_total`
function outcome(ctx, keeperId, what, extra = {}) {
  const st = keeperState(ctx.state, keeperId);
  st.outcomes[what] = (st.outcomes[what] || 0) + 1;
  st.lastOutcome = { outcome: what, at: ctx.io.now(), ...extra };
  ctx.metrics.inc('keeper_tx_outcomes_total', { keeper: keeperId, outcome: what });
}

/// ctx: { cfg, io, state, metrics, log? }. Returns a summary per keeper (also kept on ctx.lastTick).
export async function tick(ctx) {
  const { cfg, io, state, metrics } = ctx;
  const log = ctx.log || L;
  const save = () => saveState(cfg.statePath, state);
  const now = io.now();
  const summary = { at: now, keepers: {} };
  metrics.inc('keeper_ticks_total');

  // 1. one tx in flight at a time: settle, replace or cancel it before anything else. no new nonce meanwhile
  if (state.inFlight) {
    const cleared = await resolveInFlight(ctx, now);
    if (!cleared) {
      summary.skipped = 'in_flight';
      return finish(ctx, summary, now);
    }
  }

  // 2. gas price and key balance
  const block = await io.getBlock();
  const baseFee = block.baseFeePerGas ?? 0n;
  const fees = feeCaps({ baseFeePerGas: baseFee, priorityEstimate: await io.priorityEstimate(), capWei: cfg.maxGasWei, maxPriorityWei: cfg.maxPriorityWei });
  metrics.set('keeper_base_fee_wei', {}, baseFee);
  const balance = await io.getBalance();
  metrics.set('keeper_key_balance_wei', {}, balance);
  summary.balance = balance;
  if (balance < cfg.lowBalanceWei) log.warn('keeper key balance under the funding need, fund it', { address: io.address, balance, needWei: cfg.lowBalanceWei });
  if (balance > cfg.highBalanceWei) log.warn('keeper key holds more than the hot key limit', { address: io.address, balance });

  // 3. keepers, in order, one tx at a time
  for (const k of cfg.keepers) {
    const st = keeperState(state, k.id);
    const r = (summary.keepers[k.id] = { result: null });
    const prevCheck = st.nextCheckAt;
    const result = (res, extra = {}) => {
      Object.assign(r, { result: res, ...extra });
      st.lastResult = res;
      metrics.inc('keeper_results_total', { keeper: k.id, result: res });
      if (RETRY_NEXT_TICK.has(res)) st.nextCheckAt = prevCheck && prevCheck < now ? prevCheck : now;
    };
    if (!k.address) {
      result('no_address');
      log.warn('keeper has no address (registry entry or env override missing)', { keeper: k.id });
      continue;
    }
    // KR-14: runbook cadence, each keeper is read and decided once per check interval
    if (st.nextCheckAt && now < st.nextCheckAt) {
      r.result = 'wait';
      r.nextCheckAt = st.nextCheckAt;
      continue;
    }
    let preview;
    try {
      preview = await io.read(k);
    } catch (err) {
      result('read_error', { error: errMsg(err) });
      metrics.inc('keeper_rpc_errors_total', { keeper: k.id });
      log.error('preview read failed', { keeper: k.id, error: errMsg(err) });
      continue;
    }
    st.nextCheckAt = now + k.checkIntervalSeconds;
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

    // KR-01: a backoff after a run that made no progress holds even when the weekly timer is due
    if (st.backoffUntil && now < st.backoffUntil) {
      result('backoff', { backoffUntil: st.backoffUntil });
      st.nextCheckAt = Math.max(st.nextCheckAt, st.backoffUntil);
      log.warn('due but backing off after a run without progress', { keeper: k.id, backoffUntil: st.backoffUntil, reasons: d.reasons });
      continue;
    }
    // KR-01: minimum spacing between successful runs
    if (st.lastRunAt && now - st.lastRunAt < k.minRunIntervalSeconds) {
      result('min_interval', { nextRunAt: st.lastRunAt + k.minRunIntervalSeconds });
      st.nextCheckAt = Math.max(st.nextCheckAt, st.lastRunAt + k.minRunIntervalSeconds);
      log.info('due but inside the minimum run interval', { keeper: k.id, lastRunAt: st.lastRunAt, minRunIntervalSeconds: k.minRunIntervalSeconds });
      continue;
    }
    if (st.lastRevertAt && now - st.lastRevertAt < cfg.revertCooldownSeconds) {
      result('cooldown');
      st.nextCheckAt = Math.max(st.nextCheckAt, st.lastRevertAt + cfg.revertCooldownSeconds);
      log.warn('due but in revert cooldown', { keeper: k.id, lastRevertAt: st.lastRevertAt, consecutiveReverts: st.consecutiveReverts });
      continue;
    }
    if (!fees.ok) {
      result('gas_cap');
      metrics.inc('keeper_gas_cap_skips_total', { keeper: k.id });
      log.warn('due but base fee above MAX_GAS_GWEI, skipping', { keeper: k.id, baseFeePerGas: fees.baseFeePerGas, capWei: fees.capWei });
      continue;
    }

    // KR-02: pool state for the independent floor. a failed read means no convert and no burn this run
    let market = null;
    if (io.market) {
      try {
        market = await io.market(k);
      } catch (err) {
        metrics.inc('keeper_rpc_errors_total', { keeper: k.id });
        log.warn('market read failed, sending without convert or burn', { keeper: k.id, error: errMsg(err) });
      }
    }

    // KR-14: skip when what the run moves is worth less than its gas, unless the weekly timer is due. pricing the
    // coin needs the pool read: without it the thresholds alone decide
    const value = market ? pendingValueWei(k.kind, preview, market) : null;
    if (value !== null && !d.reasons.includes('weekly')) {
      const gasCost = k.expectedGas * (baseFee + fees.maxPriorityFeePerGas);
      if (value < gasCost) {
        result('below_gas_value', { valueWei: value, gasCostWei: gasCost });
        log.info('due but pending value is under the gas cost', { keeper: k.id, valueWei: value, gasCostWei: gasCost });
        continue;
      }
    }

    // quote: simulate with minOut / rate 0, then the floor from pool state
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
        result('rpc_error', { error: errMsg(err) });
        metrics.inc('keeper_rpc_errors_total', { keeper: k.id });
        log.error('simulation failed', { keeper: k.id, error: errMsg(err) });
      }
      save();
      continue;
    }
    if (k.kind === 'v2' && sim === null) log.warn('rpc has no eth_simulateV1, sending without convert', { keeper: k.id });
    const q = argsFor(k, sim, market, preview, cfg);
    const args = q.args;
    const [fn] = runCall(k, args);
    r.args = args;
    r.quote = q.status;
    r.quoteDetail = q;
    metrics.inc('keeper_quote_status_total', { keeper: k.id, status: q.status });
    if (!QUIET_QUOTES.has(q.status)) {
      // KR-02 `no_quote`, KR-03 `floor_above_quote` with the blocking swapper, KR-12 `impact_too_high`
      log.warn(q.status, { keeper: k.id, simulated: sim, quote: q, note: 'sent without convert or burn, a later run converts the rest' });
    }
    // KR-01b: a LAYER router is due but the simulation burned nothing: its own result and alert
    if (k.kind === 'layer' && q.status !== 'ok' && d.reasons.some((x) => x !== 'weekly')) {
      metrics.inc('keeper_alerts_total', { keeper: k.id, alert: 'due_no_burn' });
      log.warn('alert', { keeper: k.id, alert: 'due_no_burn', reasons: d.reasons, quote: q.status });
      r.alert = 'due_no_burn';
    }
    log.info('quoted', { keeper: k.id, simulated: sim, fn, args, quote: q });
    if (cfg.dryRun) { result('dry_run'); save(); continue; }

    // KR-06: the node refuses a tx the key cannot cover at its fee cap: skip with a clear result, not a send error
    const need = k.gas * fees.maxFeePerGas;
    if (balance < need) {
      result('insufficient_funds', { balance, needWei: need });
      metrics.inc('keeper_insufficient_funds_total', { keeper: k.id });
      log.error('key balance under gas limit times max fee, not sending. fund the key', { keeper: k.id, balance, needWei: need, gas: k.gas, maxFeePerGas: fees.maxFeePerGas });
      continue;
    }
    // KR-04: never stack a tx behind one the node already holds for this key (lost state, a manual send)
    const [latest, pendingNonce] = await Promise.all([io.getNonce('latest'), io.getNonce('pending')]);
    if (pendingNonce > latest) {
      result('foreign_pending', { latest, pending: pendingNonce });
      metrics.inc('keeper_alerts_total', { keeper: k.id, alert: 'foreign_pending' });
      log.error('ALERT the node holds an unmined tx from this key that the state file does not know, not sending', { keeper: k.id, latest, pending: pendingNonce });
      break;
    }

    // send and wait. never resend in this tick. the record is on disk before the broadcast (KR-11)
    const trigger = triggerMetrics(k.kind, d.reasons, preview);
    let sent;
    try {
      sent = await io.send(k, fn, args, fees, {
        onSigned: ({ hash, nonce }) => {
          state.inFlight = {
            keeper: k.id, hash, hashes: [hash], cancelHashes: [], nonce, sentAt: now, lastSentAt: now, fn, args,
            maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas, replacements: 0,
            private: cfg.privateKeepers?.has(k.kind) && Boolean(cfg.privateRpcUrl), trigger,
          };
          save();
        },
      });
    } catch (err) {
      if (err.ambiguous && state.inFlight) {
        result('send_unknown', { error: errMsg(err) });
        outcome(ctx, k.id, 'send_unknown', { nonce: state.inFlight.nonce });
        log.error('send failed but the tx may be in a pool, keeping it in flight', { keeper: k.id, error: err.details || errMsg(err) });
        save();
        summary.skipped = 'in_flight';
        break;
      }
      state.inFlight = null;
      result('send_error', { error: errMsg(err) });
      outcome(ctx, k.id, 'send_error');
      metrics.inc('keeper_send_errors_total', { keeper: k.id });
      log.error('send failed', { keeper: k.id, error: err.details || errMsg(err) });
      save();
      continue;
    }
    // fakes and older io may not call onSigned
    if (!state.inFlight) {
      state.inFlight = {
        keeper: k.id, hash: sent.hash, hashes: [sent.hash], cancelHashes: [], nonce: sent.nonce, sentAt: now, lastSentAt: now, fn, args,
        maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas, replacements: 0, private: Boolean(sent.private), trigger,
      };
    }
    state.inFlight.private = Boolean(sent.private);
    outcome(ctx, k.id, 'sent', { nonce: sent.nonce });
    metrics.inc('keeper_txs_sent_total', { keeper: k.id });
    log.info('sent', { keeper: k.id, hash: sent.hash, nonce: sent.nonce, private: sent.private, gas: k.gas, maxFeePerGas: fees.maxFeePerGas });
    save();
    const receipt = await io.waitReceipt(sent.hash, cfg.receiptTimeoutSeconds * 1000);
    if (!receipt) {
      result('pending'); // no hash here: /status never shows an unmined tx (KR-05)
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

/// the tx in flight: mined (any of its hashes) settles it; its nonce used without a receipt three ticks in a row
/// clears it as lost; older than PENDING_TIMEOUT_SECONDS gets a same nonce replacement at +12.5% fees (same calldata)
/// up to MAX_REPLACEMENTS, then a cancel to self. Returns true when the slot is free again.
async function resolveInFlight(ctx, now) {
  const { cfg, io, state, metrics } = ctx;
  const log = ctx.log || L;
  const save = () => saveState(cfg.statePath, state);
  const f = state.inFlight;
  f.hashes ??= [f.hash];
  f.cancelHashes ??= [];
  f.lastSentAt ??= f.sentAt;
  f.replacements ??= 0;
  const k = cfg.keepers.find((x) => x.id === f.keeper);
  metrics.set('keeper_pending_age_seconds', {}, now - f.sentAt);

  for (const h of [...f.hashes].reverse()) {
    const receipt = await io.getReceipt(h);
    if (!receipt) continue;
    if (f.cancelHashes.includes(h)) {
      outcome(ctx, f.keeper, 'cancelled', { nonce: f.nonce, hash: h });
      keeperState(state, f.keeper).lastResult = 'cancelled';
      log.warn('stuck run cancelled (nonce freed by the self transfer)', { keeper: f.keeper, hash: h, nonce: f.nonce, replacements: f.replacements });
    } else {
      log.info('in flight tx mined', { keeper: f.keeper, hash: h, status: receipt.status });
      if (k) await settle(ctx, k, { ...f, hash: h }, receipt);
    }
    state.inFlight = null;
    metrics.set('keeper_pending_age_seconds', {}, 0);
    save();
    return true;
  }

  // KR-11: nonce used but none of our hashes has a receipt (lagging rpc, or a tx from elsewhere): look again a few
  // ticks before giving up on it
  if ((await io.getNonce('latest')) > f.nonce) {
    f.nonceUsedChecks = (f.nonceUsedChecks || 0) + 1;
    if (f.nonceUsedChecks >= 3) {
      outcome(ctx, f.keeper, 'lost', { nonce: f.nonce });
      metrics.inc('keeper_alerts_total', { keeper: f.keeper, alert: 'lost_tx' });
      log.error('ALERT nonce used but no receipt for any of our txs, clearing it', { keeper: f.keeper, nonce: f.nonce, hashes: f.hashes });
      state.inFlight = null;
      save();
      return true;
    }
    log.warn('in flight nonce used, waiting for its receipt', { keeper: f.keeper, nonce: f.nonce, checks: f.nonceUsedChecks });
    save();
    return false;
  }

  if (now - f.lastSentAt <= cfg.pendingTimeoutSeconds) {
    log.info('tx still in flight, skipping tick', { keeper: f.keeper, nonce: f.nonce, ageSeconds: now - f.sentAt });
    metrics.inc('keeper_inflight_skips_total');
    return false;
  }
  await replaceOrCancel(ctx, k, f, now);
  save();
  return false;
}

/// KR-04: same nonce, fees +12.5% (at least today's fee caps). the run is replaced with the same calldata while the
/// bumped fee stays under MAX_GAS_GWEI and fewer than MAX_REPLACEMENTS were sent, else a 0 value self transfer
/// cancels the nonce (fee cap 2 x MAX_GAS_GWEI, 21,000 gas)
async function replaceOrCancel(ctx, k, f, now) {
  const { cfg, io, metrics } = ctx;
  const log = ctx.log || L;
  const block = await io.getBlock();
  const priorityEstimate = await io.priorityEstimate();
  const caps = (capWei) => feeCaps({ baseFeePerGas: block.baseFeePerGas ?? 0n, priorityEstimate, capWei, maxPriorityWei: cfg.maxPriorityWei });
  const oldMax = f.maxFeePerGas ?? cfg.maxGasWei;
  const oldPrio = f.maxPriorityFeePerGas ?? cfg.maxPriorityWei;
  const bump = (fresh) => {
    const m = maxB(bumpFee(oldMax), fresh.ok ? fresh.maxFeePerGas : 0n);
    const p = bumpFee(oldPrio);
    return { maxFeePerGas: m, maxPriorityFeePerGas: p > m ? m : p };
  };
  // the run is replaced under MAX_GAS_GWEI (today's caps at that limit), the cancel under 2 x MAX_GAS_GWEI
  const asRun = bump(caps(cfg.maxGasWei));
  const replace = Boolean(k) && !f.cancel && f.replacements < cfg.maxReplacements && asRun.maxFeePerGas <= cfg.maxGasWei;
  const { maxFeePerGas, maxPriorityFeePerGas } = replace ? asRun : bump(caps(2n * cfg.maxGasWei));
  const bumped = { maxFeePerGas, maxPriorityFeePerGas };
  if (!replace && maxFeePerGas > 2n * cfg.maxGasWei) {
    metrics.inc('keeper_alerts_total', { keeper: f.keeper, alert: 'stuck_tx' });
    log.error('ALERT tx stuck and a cancel would pay more than 2 x MAX_GAS_GWEI, waiting', { keeper: f.keeper, nonce: f.nonce, maxFeePerGas });
    f.lastSentAt = now;
    return;
  }
  const pushed = [];
  const onSigned = ({ hash }) => {
    pushed.push(hash);
    f.hashes.push(hash);
    if (!replace) f.cancelHashes.push(hash);
    f.hash = hash;
    saveState(cfg.statePath, ctx.state);
  };
  const what = replace ? 'replaced' : 'cancel_sent';
  try {
    if (replace) await io.send(k, f.fn, f.args, bumped, { nonce: f.nonce, onSigned });
    else await io.cancel(f.nonce, bumped, { private: f.private, onSigned });
    if (pushed.length === 0) throw new Error('io did not report the signed hash');
    outcome(ctx, f.keeper, what, { nonce: f.nonce });
    log.warn(replace ? 'stuck tx replaced at the same nonce' : 'stuck tx cancelled with a self transfer at the same nonce', {
      keeper: f.keeper, nonce: f.nonce, replacements: f.replacements + (replace ? 1 : 0), maxFeePerGas, maxPriorityFeePerGas,
    });
  } catch (err) {
    if (!err.ambiguous) {
      // a definite reject: the old tx is still the one in the pool
      f.hashes = f.hashes.filter((h) => !pushed.includes(h));
      f.cancelHashes = f.cancelHashes.filter((h) => !pushed.includes(h));
      f.hash = f.hashes.at(-1);
      outcome(ctx, f.keeper, replace ? 'replace_error' : 'cancel_error', { nonce: f.nonce });
      log.error('replacement rejected', { keeper: f.keeper, nonce: f.nonce, error: err.details || errMsg(err) });
      if (replace) f.replacements += 1; // bounded either way
      f.lastSentAt = now;
      return;
    }
    log.error('replacement send failed but may be in a pool', { keeper: f.keeper, nonce: f.nonce, error: errMsg(err) });
  }
  if (replace) f.replacements += 1;
  else f.cancel = true;
  f.maxFeePerGas = maxFeePerGas;
  f.maxPriorityFeePerGas = maxPriorityFeePerGas;
  f.lastSentAt = now;
  metrics.inc('keeper_replacements_total', { keeper: f.keeper, kind: replace ? 'replace' : 'cancel' });
}

/// records a mined tx: success resets the weekly timer and checks progress, a revert counts toward the alert
async function settle(ctx, k, f, receipt) {
  const { state, metrics, io, cfg } = ctx;
  const log = ctx.log || L;
  const st = keeperState(state, k.id);
  st.lastTx = f.hash;
  const out = { hash: f.hash, gasUsed: receipt.gasUsed, block: receipt.blockNumber };
  metrics.set('keeper_last_gas_used', { keeper: k.id }, receipt.gasUsed);
  if (receipt.status === 'success') {
    outcome(ctx, k.id, 'mined_ok', { nonce: f.nonce, hash: f.hash });
    st.lastRunAt = f.sentAt;
    st.consecutiveReverts = 0;
    st.lastRevertAt = null;
    st.lastResult = 'ok';
    const events = decodeKeeperLogs(receipt.logs, k.kind, k.address);
    for (const e of events.filter((x) => x.skipped)) {
      metrics.inc('keeper_skipped_events_total', { keeper: k.id, event: e.event });
      // the normal idle answers log at info, anything else (floors, slippage, broken recipients) at warn
      const idle = /^(NothingToFlush|NothingToConvert|ConvertTooEarly)\(/.test(e.reason || '');
      (idle ? log.info : log.warn)('step skipped', { keeper: k.id, event: e.event, step: e.step, reason: e.reason, hash: f.hash });
    }
    metrics.inc('keeper_runs_total', { keeper: k.id });
    metrics.inc('keeper_results_total', { keeper: k.id, result: 'ok' });
    log.info('run ok', { keeper: k.id, hash: f.hash, gasUsed: receipt.gasUsed, events: events.map((e) => ({ event: e.event, args: e.args, reason: e.reason })) });
    const progress = await checkProgress(ctx, k, f);
    return { ...out, result: 'ok', events, progress };
  }
  outcome(ctx, k.id, 'mined_reverted', { nonce: f.nonce, hash: f.hash });
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

/// KR-01: after a successful run every threshold metric that triggered it must have dropped by PROGRESS_MIN_BPS of
/// its value at send time. otherwise `no_progress`: a backoff doubling from BACKOFF_MIN_SECONDS to
/// BACKOFF_MAX_SECONDS and the `/status` alert flag. a run with progress clears both. weekly only runs are not judged
async function checkProgress(ctx, k, f) {
  const { state, metrics, io, cfg } = ctx;
  const log = ctx.log || L;
  const st = keeperState(state, k.id);
  if (!f.trigger || Object.keys(f.trigger).length === 0) return null;
  let after;
  try {
    after = await io.read(k);
  } catch (err) {
    log.warn('progress check skipped, preview read failed', { keeper: k.id, error: errMsg(err) });
    return null;
  }
  const now = io.now();
  const p = progressMade(f.trigger, triggerMetrics(k.kind, Object.keys(f.trigger), after), cfg.progressMinBps);
  if (p.ok) {
    st.backoffSeconds = 0;
    st.backoffUntil = null;
    st.noProgress = null;
    metrics.set('keeper_no_progress', { keeper: k.id }, 0);
    return 'ok';
  }
  st.backoffSeconds = nextBackoff(st.backoffSeconds, cfg.backoffMinSeconds, cfg.backoffMaxSeconds);
  st.backoffUntil = now + st.backoffSeconds;
  st.noProgress = { at: now, reasons: p.failed, backoffSeconds: st.backoffSeconds };
  metrics.inc('keeper_no_progress_total', { keeper: k.id });
  metrics.set('keeper_no_progress', { keeper: k.id }, 1);
  log.warn('no_progress', {
    keeper: k.id, reasons: p.failed, before: f.trigger, after: triggerMetrics(k.kind, p.failed, after),
    backoffSeconds: st.backoffSeconds, backoffUntil: st.backoffUntil,
  });
  return 'no_progress';
}

function finish(ctx, summary, now) {
  ctx.state.lastTickAt = now;
  ctx.metrics.set('keeper_last_tick_timestamp', {}, now);
  for (const [id, s] of Object.entries(ctx.state.keepers)) {
    ctx.metrics.set('keeper_consecutive_reverts', { keeper: id }, s.consecutiveReverts);
    if (s.lastRunAt) ctx.metrics.set('keeper_last_run_timestamp', { keeper: id }, s.lastRunAt);
    ctx.metrics.set('keeper_backoff_until', { keeper: id }, s.backoffUntil ?? 0);
  }
  ctx.metrics.set('keeper_in_flight', {}, ctx.state.inFlight ? 1 : 0);
  saveState(ctx.cfg.statePath, ctx.state);
  ctx.lastTick = summary;
  return summary;
}
