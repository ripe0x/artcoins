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
  if (p.accruedArtCoin > t.accruedArtCoin) reasons.push('accrued_coin');
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

/// 111 call args from `run(true, 0)` simulated as (collected, flushed, converted). A simulation that converts
/// nothing sends doConvert false: an unquoted convert would rely only on the swapper's 80% of spot floor.
export function args111(sim, slippageBps) {
  const converted = sim[2];
  return converted > 0n ? [true, minOutFromSim(converted, slippageBps)] : [false, 0n];
}

/// LAYER call args from `run(true, 0, false)` simulated as (lCol, wCol, lBurn, wBurn, lBought). No weth burn
/// in the simulation means doBurn false, so no burn is ever sent without a quote. unwrap is always true.
export function argsLayer(sim, slippageBps) {
  const [, , , wBurn, lBought] = sim;
  return wBurn > 0n ? [true, rateFromSim(wBurn, lBought, slippageBps), true] : [false, 0n, true];
}

/// v2 call args from the `SwapperServiced(token, swapper, flushed, converted)` events of a simulated
/// `collectAndForward(token, true, 0)`. The keeper passes one minOut to every swapper, so the quote is the
/// smallest nonzero convert. `null` events (no simulation available) mean doConvert false.
export function argsV2(token, servicedEvents, slippageBps) {
  if (!servicedEvents) return [token, false, 0n];
  const outs = servicedEvents.map((e) => e.converted).filter((c) => c > 0n);
  if (outs.length === 0) return [token, false, 0n];
  const least = outs.reduce((a, b) => (b < a ? b : a));
  return [token, true, minOutFromSim(least, slippageBps)];
}
