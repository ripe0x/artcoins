// Pure decision and quote math. No network, no clocks: callers pass `now` (unix seconds).
// Rules: docs/v2/RUNBOOK.md part 1 action 3 (111), action 2b (LAYER), part 2 2b keeper table (v2 coins).

export const BPS = 10_000n;
const E18 = 10n ** 18n;

/// weekly timer: due when the keeper never ran (no state) or the last successful run is `weekly` old
export function weeklyDue(lastRunAt, now, weeklySeconds) {
  return !lastRunAt || now - lastRunAt >= weeklySeconds;
}

/// 111: run when uncollectedEth > 0.02 eth, uncollectedCoin > 10,000e18, escrowedEth > 0.05 eth (flush
/// overdue) or the weekly timer is due. `swapperEth > 0` is an alert (a third party stranded eth), not a trigger.
export function decide111(p, t, timer) {
  const reasons = [];
  if (p.uncollectedEth > t.uncollectedEth) reasons.push('uncollected_eth');
  if (p.uncollectedCoin > t.uncollectedCoin) reasons.push('uncollected_coin');
  if (p.escrowedEth > t.escrowedEth) reasons.push('escrowed_eth');
  if (weeklyDue(timer.lastRunAt, timer.now, timer.weeklySeconds)) reasons.push('weekly');
  const alerts = p.swapperEth > 0n ? ['swapper_eth_stranded'] : [];
  return { run: reasons.length > 0, reasons, alerts };
}

/// LAYER: run when a router holds weth at or above its own threshold, when
/// `routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controllerWeth) >= 0.01 weth` (what router0 would hold
/// after the claims and the controller split), or the weekly timer is due. A router with nothing never triggers,
/// even if its threshold reads 0.
export function decideLayer(p, controllerWeth, t, timer) {
  const reasons = [];
  for (let i = 0; i < 3; i++) {
    if (p.routerWeth[i] > 0n && p.routerWeth[i] >= p.routerThreshold[i]) reasons.push(`router${i}_due`);
  }
  if (combinedLayerWeth(p, controllerWeth) >= t.combinedWeth) reasons.push('combined_weth');
  if (weeklyDue(timer.lastRunAt, timer.now, timer.weeklySeconds)) reasons.push('weekly');
  return { run: reasons.length > 0, reasons, alerts: [] };
}

export function combinedLayerWeth(p, controllerWeth) {
  return p.routerWeth[0] + p.claimable[3] + ((p.claimable[1] + controllerWeth) * 4n) / 10n;
}

/// v2 coin: run when the fee swappers hold more than 0.02 eth or 10,000 coin (held plus escrowed), or weekly.
/// uncollected lp fees are not readable through the v2 locker, so the weekly timer is what collects them.
export function decideV2(p, t, timer) {
  const reasons = [];
  if (p.accruedPaired > t.accruedPaired) reasons.push('accrued_paired');
  if (p.accruedCoin > t.accruedCoin) reasons.push('accrued_coin');
  if (weeklyDue(timer.lastRunAt, timer.now, timer.weeklySeconds)) reasons.push('weekly');
  return { run: reasons.length > 0, reasons, alerts: [] };
}

/// Fee caps for one tx. Skips (ok false) when base fee plus priority is above `capWei`: a tx priced under the
/// base fee would sit unmined and block the next tick. Otherwise maxFee = min(2 * base + priority, cap).
export function feeCaps({ baseFeePerGas, priorityEstimate, capWei, maxPriorityWei }) {
  let priority = priorityEstimate < maxPriorityWei ? priorityEstimate : maxPriorityWei;
  if (priority < 0n) priority = 0n;
  if (baseFeePerGas + priority > capWei) {
    return { ok: false, reason: 'gas_cap', baseFeePerGas, capWei };
  }
  const want = 2n * baseFeePerGas + priority;
  const maxFeePerGas = want < capWei ? want : capWei;
  return { ok: true, maxFeePerGas, maxPriorityFeePerGas: priority, baseFeePerGas, capWei };
}

/// 111 and v2 minOut: the simulated convert output at minOut 0 minus slippage (RunKeeper111.quoteMinOut)
export function minOutFromSim(converted, slippageBps) {
  return (converted * (BPS - BigInt(slippageBps))) / BPS;
}

/// LAYER rate: realized LAYER per 1e18 weth of the simulated weth burns minus slippage
/// (RunKeeperLayer.quoteRate, same rounding). 0 when the simulation burned no weth.
export function rateFromSim(wethBurned, layerBought, slippageBps) {
  if (wethBurned === 0n) return 0n;
  return (((layerBought * E18) / wethBurned) * (BPS - BigInt(slippageBps))) / BPS;
}

// ── independent floor from pool state (KR-02, KR-03, KR-12) ─────────────────────────────────────────────

export const PPM = 1_000_000n;
const Q96 = 1n << 96n;
const Q192 = 1n << 192n;

/// v4 `Pool.State` slot0 word: sqrtPriceX96 (160 bits), tick (24), protocolFee (24), lpFee (24)
export function decodeSlot0(word) {
  const v = BigInt(word);
  return { sqrtPriceX96: v & ((1n << 160n) - 1n), lpFee: Number((v >> 208n) & 0xffffffn) };
}

/// output at spot, no fee, no impact. `inIsToken0`: the input is currency0 (price = token1 per token0)
export function spotOut(amountIn, sqrtPriceX96, inIsToken0) {
  if (amountIn <= 0n || !sqrtPriceX96) return 0n;
  const s2 = sqrtPriceX96 * sqrtPriceX96;
  return inIsToken0 ? (amountIn * s2) / Q192 : (amountIn * Q192) / s2;
}

/// 1 - lp fee - baseline skim, in ppm (0 when the fees eat everything)
export function netPpm(lpFeePpm, skimPpm) {
  const n = PPM - BigInt(lpFeePpm) - BigInt(skimPpm);
  return n > 0n ? n : 0n;
}

/// spotNetOut = amountIn * price * (1 - skim - lpFee): what a swap with no price impact returns
export function spotNetOut(amountIn, m, inIsToken0) {
  return (spotOut(amountIn, m.sqrtPriceX96, inIsToken0) * netPpm(m.lpFeePpm, m.skimPpm)) / PPM;
}

/// constant liquidity swap output (no tick crossed): the impact estimate for one burn. fees come off the input
export function inRangeOut(amountIn, m, inIsToken0) {
  const L = m.liquidity ?? 0n;
  const s = m.sqrtPriceX96;
  if (amountIn <= 0n || !s || L <= 0n) return 0n;
  const net = (amountIn * netPpm(m.lpFeePpm, m.skimPpm)) / PPM;
  if (inIsToken0) {
    // token0 in, price falls: s1 = L * s * Q96 / (L * Q96 + net * s), out1 = L * (s - s1) / Q96
    const s1 = (L * s * Q96) / (L * Q96 + net * s);
    return (L * (s - s1)) / Q96;
  }
  // token1 in, price rises: s1 = s + net * Q96 / L, out0 = L * Q96 * (s1 - s) / (s * s1)
  const s1 = s + (net * Q96) / L;
  return (L * Q96 * (s1 - s)) / (s * s1);
}

/// the spot floor: spotNetOut * (1 - slippage - impact allowance)
export function spotFloor(spotNet, slippageBps, impactBps) {
  const keep = BPS - BigInt(slippageBps) - BigInt(impactBps);
  return keep > 0n ? (spotNet * keep) / BPS : 0n;
}

const max = (a, b) => (a > b ? a : b);
const min = (a, b) => (a < b ? a : b);

/// minOut = max(simulated * (1 - slippage), spotNetOut * (1 - slippage - impact)). status `ok` only when the
/// floor is positive and the simulated output clears it; `no_quote` when the independent floor is missing or 0,
/// `floor_above_quote` when the simulation returns less than the floor (rpc disagreement or too much impact)
export function floorQuote(simulated, spotNet, slippageBps, impactBps) {
  const simFloor = minOutFromSim(simulated, slippageBps);
  const sFloor = spotNet ? spotFloor(spotNet, slippageBps, impactBps) : 0n;
  const minOut = max(simFloor, sFloor);
  if (!spotNet || sFloor === 0n || minOut === 0n) return { status: 'no_quote', minOut: 0n, simFloor, spotFloor: sFloor };
  if (minOut > simulated) return { status: 'floor_above_quote', minOut, simFloor, spotFloor: sFloor };
  return { status: 'ok', minOut, simFloor, spotFloor: sFloor };
}

/// 111: coin the next convert would sell, at most: what the swapper holds plus its share of the uncollected coin,
/// capped at `maxStepIn`
export function amountIn111(preview, m) {
  const pending = preview.swapperCoin + (preview.uncollectedCoin * BigInt(m.swapperShareBps ?? 10_000)) / BPS;
  return m.maxStepIn ? min(pending, m.maxStepIn) : pending;
}

/// 111 call args from `run(true, 0)` simulated as (collected, flushed, converted) plus the market read (`m`, null
/// when it failed). doConvert true only with a positive floor the simulated output clears; never `run(true, 0)`.
/// Returns { args, status, ... }: status `ok`, `no_convert` (the simulation converted nothing), `no_quote`,
/// `floor_above_quote`.
export function args111(sim, slippageBps, m, preview, impactBps = 100) {
  const converted = sim[2];
  if (converted === 0n) return { args: [false, 0n], status: 'no_convert' };
  const spotNet = m ? spotNetOut(amountIn111(preview, m), m, m.coinIsToken0 ?? false) : 0n;
  const q = floorQuote(converted, spotNet, slippageBps, impactBps);
  return { ...q, args: q.status === 'ok' ? [true, q.minOut] : [false, 0n], simulated: converted, spotNet };
}

/// weth each router would burn in this run: router0 also receives the claims and the controller split
export function layerBurnAmounts(p, controllerWeth) {
  return [combinedLayerWeth(p, controllerWeth), p.routerWeth[1], p.routerWeth[2]];
}

/// LAYER call args from `run(true, 0, false)` simulated as (lCol, wCol, lBurn, wBurn, lBought) plus the market
/// read. The keeper applies one rate to each router's whole balance (KR-12), so the rate is quoted for the router
/// with the largest balance (the worst impact): the simulated average rate is cut to that router's constant
/// liquidity estimate, and the spot floor nets out fees, slippage and the impact allowance. A burn the estimate
/// says moves the price more than the allowance, a missing or zero floor, or a simulated rate under the floor all
/// send doBurn false. Never a rate of 0 with doBurn true.
export function argsLayer(sim, slippageBps, m, preview, impactBps = 100) {
  const [, , , wBurn, lBought] = sim;
  if (wBurn === 0n) return { args: [false, 0n, true], status: 'no_burn' };
  if (!m || !preview) return { args: [false, 0n, true], status: 'no_quote' };
  const amounts = layerBurnAmounts(preview, preview.controllerWeth ?? 0n);
  const burning = amounts.filter((a, i) => a > 0n && a >= preview.routerThreshold[i]);
  const largest = burning.reduce((a, b) => max(a, b), 0n) || wBurn;
  const wethIsToken0 = m.wethIsToken0;
  const spotNet = spotNetOut(largest, m, wethIsToken0);
  const est = inRangeOut(largest, m, wethIsToken0);
  const spotNetRate = (spotNet * E18) / largest;
  const estRate = (est * E18) / largest;
  const simRate = (lBought * E18) / wBurn;
  const impact = spotNet > 0n ? Number(((spotNet - min(est, spotNet)) * BPS) / spotNet) : null;
  const detail = { largest, simRate, estRate, spotNetRate, impactBps: impact };
  if (spotNetRate === 0n || estRate === 0n) return { args: [false, 0n, true], status: 'no_quote', ...detail };
  if (impact > impactBps) return { args: [false, 0n, true], status: 'impact_too_high', ...detail };
  const q = floorQuote(min(simRate, estRate), spotNetRate, slippageBps, impactBps);
  return { ...detail, ...q, rate: q.minOut, args: q.status === 'ok' ? [true, q.minOut, true] : [false, 0n, true] };
}

/// v2 call args from the `SwapperServiced(token, swapper, flushed, converted)` events of a simulated
/// `collectAndForward(token, true, 0)` and the per swapper market read (KR-03). The keeper passes one minOut to every
/// swapper, so each converting swapper gets its own floor (its pending coin capped at its `maxStepIn`, at its
/// pool's spot net of fees), minOut is the largest floor, and doConvert is true only when every converting swapper's
/// simulated output clears it. Otherwise doConvert false and `blockedBy` names the swapper; a later run converts
/// once the swappers' steps line up (pacing, a drained step). `null` events (no simulation) mean doConvert false.
export function argsV2(token, servicedEvents, slippageBps, m, impactBps = 100) {
  if (!servicedEvents) return { args: [token, false, 0n], status: 'no_sim' };
  const converting = servicedEvents.filter((e) => e.converted > 0n);
  if (converting.length === 0) return { args: [token, false, 0n], status: 'no_convert' };
  if (!m || !m.swappers) return { args: [token, false, 0n], status: 'no_quote' };
  const per = [];
  for (const e of converting) {
    const sw = m.swappers.find((x) => x.address.toLowerCase() === e.swapper.toLowerCase());
    const amountIn = sw ? min(sw.accruedCoin, sw.maxStepIn || sw.accruedCoin) : 0n;
    const spotNet = sw ? spotNetOut(amountIn, sw, false) : 0n; // v2 pools: eth is currency0, the coin currency1
    per.push({ swapper: e.swapper, simulated: e.converted, ...floorQuote(e.converted, spotNet, slippageBps, impactBps) });
  }
  const missing = per.find((p) => p.status === 'no_quote');
  if (missing) return { args: [token, false, 0n], status: 'no_quote', blockedBy: missing.swapper, swappers: per };
  const minOut = per.reduce((a, p) => max(a, p.minOut), 0n);
  const blocked = per.find((p) => p.simulated < minOut);
  if (blocked) return { args: [token, false, 0n], status: 'floor_above_quote', blockedBy: blocked.swapper, minOut, swappers: per };
  return { args: [token, true, minOut], status: 'ok', minOut, swappers: per };
}

// ── progress, backoff and value rules (KR-01, KR-14) ────────────────────────────────────────────────────

/// the preview metric behind each threshold reason. `weekly` has none (it never counts for progress)
export function triggerMetrics(kind, reasons, p) {
  const out = {};
  for (const r of reasons) {
    if (kind === '111') {
      if (r === 'uncollected_eth') out[r] = p.uncollectedEth;
      if (r === 'uncollected_coin') out[r] = p.uncollectedCoin;
      if (r === 'escrowed_eth') out[r] = p.escrowedEth;
    } else if (kind === 'layer') {
      const m = /^router(\d)_due$/.exec(r);
      if (m) out[r] = p.routerWeth[Number(m[1])];
      if (r === 'combined_weth') out[r] = combinedLayerWeth(p, p.controllerWeth ?? 0n);
    } else {
      if (r === 'accrued_paired') out[r] = p.accruedPaired;
      if (r === 'accrued_coin') out[r] = p.accruedCoin;
    }
  }
  return out;
}

/// progress: every threshold metric that triggered the run dropped by at least `minBps` of its value at send time.
/// returns { ok, failed: [reason...] }. no threshold metric (weekly only) is progress by definition
export function progressMade(before, after, minBps) {
  const failed = [];
  for (const [r, b] of Object.entries(before || {})) {
    const a = after[r];
    if (a === undefined) continue;
    const need = (BigInt(b) * BigInt(minBps)) / BPS;
    if (BigInt(b) - (a < BigInt(b) ? a : BigInt(b)) < need) failed.push(r);
  }
  return { ok: failed.length === 0, failed };
}

/// next backoff: doubles from `minS` up to `maxS`
export function nextBackoff(prevSeconds, minS, maxS) {
  const n = prevSeconds ? prevSeconds * 2 : minS;
  return Math.min(Math.max(n, minS), maxS);
}

/// value of what a run moves, in wei, for the value vs gas rule. 111: eth uncollected and escrowed plus the
/// coin (uncollected plus held) at spot net of fees. v2: accrued eth plus each swapper's coin at spot. LAYER: null
/// (the runbook rule is the thresholds). coin without a market read counts 0
export function pendingValueWei(kind, p, m) {
  if (kind === '111') {
    const coin = m ? spotNetOut(p.uncollectedCoin + p.swapperCoin, m, m.coinIsToken0 ?? false) : 0n;
    return p.uncollectedEth + p.escrowedEth + coin;
  }
  if (kind === 'v2') {
    let coin = 0n;
    for (const sw of m?.swappers || []) coin += spotNetOut(sw.accruedCoin, sw, false);
    return p.accruedPaired + coin;
  }
  return null;
}

/// replacement fee: +12.5%, rounded up (nodes want at least +10% on both fields)
export const bumpFee = (x) => x + (x + 7n) / 8n;
