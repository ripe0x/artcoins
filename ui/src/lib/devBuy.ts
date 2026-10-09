import { parseEther } from 'viem';
import { BPS, DEFAULT_TOKEN_SUPPLY, FEE_DENOMINATOR } from './constants';
import { quoteBuyFromFreshPool } from './curve';
import { percentToBps, percentToPips, supplyToWei } from './encodeV2';
import type { LaunchForm } from './types';

export interface DevBuyEstimate {
  /** coin the pool curve gives for the eth after lp fee and baseline skim, wei */
  coinOut: bigint;
  /** coinOut minus the tolerance, the value to put in `minTokenOut` */
  minOut: bigint;
  /** the buy would drain the whole pool */
  exhausted: boolean;
  /** average price paid, eth per coin */
  avgEthPerCoin: number;
}

/**
 * Estimate of what the launch dev buy receives, from the exact pool curve (single sided positions
 * seeded with the pool supply) with fees approximated as lp fee + baseline skim taken off the eth in.
 * The dev buy runs before the anti sniper window starts, so only the baseline skim applies. It is an
 * estimate for choosing `minTokenOut`, the contract enforces the floor.
 */
export function estimateDevBuy(form: LaunchForm): DevBuyEstimate | null {
  const d = form.extensions.devBuy;
  try {
    const eth = parseEther(d.ethAmount.trim() || '0');
    if (eth <= 0n) return null;
    let supply = supplyToWei(form.token.totalSupply);
    if (supply === 0n) supply = DEFAULT_TOKEN_SUPPLY;
    const bpsOf = (e: { enabled: boolean; allocationPercent: number }) => (e.enabled ? percentToBps(e.allocationPercent) : 0);
    const extSupply =
      (BigInt(bpsOf(form.extensions.vault)) * supply) / BigInt(BPS) + (BigInt(bpsOf(form.extensions.airdrop)) * supply) / BigInt(BPS);
    const poolSupply = supply - extSupply;
    const feeFrac = BigInt(percentToPips(form.pool.lpFeePercent)) * BigInt(BPS) + BigInt(percentToBps(form.pool.baselineSkimPercent)) * BigInt(FEE_DENOMINATOR);
    const net = (eth * (BigInt(FEE_DENOMINATOR) * BigInt(BPS) - feeFrac)) / (BigInt(FEE_DENOMINATOR) * BigInt(BPS));
    const positions = form.rewards.positions.map((p) => ({
      tickLower: p.tickLower,
      tickUpper: p.tickUpper,
      coinAmount: (poolSupply * BigInt(p.bps)) / BigInt(BPS),
    }));
    const q = quoteBuyFromFreshPool(form.pool.startingTick, positions, net);
    if (q.coinOut === 0n) return null;
    const tol = BigInt(Math.max(0, Math.min(9_999, Math.round(d.toleranceBps))));
    return {
      coinOut: q.coinOut,
      minOut: (q.coinOut * (10_000n - tol)) / 10_000n,
      exhausted: q.exhausted,
      avgEthPerCoin: Number(eth) / Number(q.coinOut),
    };
  } catch {
    return null;
  }
}
