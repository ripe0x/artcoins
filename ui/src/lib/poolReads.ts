import type { Address } from 'viem';
import { BPS, FEE_DENOMINATOR } from './constants';

/** the v1 hook and mev module express skim and referral caps out of 100_000 (v2 uses bps) */
export const V1_SKIM_DENOMINATOR = 100_000;

/** One shape for the hook's per pool fee config, v1 returns 8 outputs, v2 returns a struct. */
export interface SkimView {
  /** unit of the skim fields: 100_000 for v1 hooks, BPS for v2 */
  denominator: number;
  baselineSkimBps: number;
  bountyBps: number;
  maxReferralBpsOfVolume: number;
  lpFeePips: number;
  bountyRecipient: Address;
  protocolRecipient: Address;
  /** v1 hooks only: the ledger the deployer chose */
  referralPayout?: Address;
}

export function normalizeSkim(raw: unknown): SkimView | null {
  if (!raw) return null;
  if (Array.isArray(raw)) {
    if (raw.length < 8) return null;
    const [baseline, bounty, maxRef, lp, bountyR, protocolR, payout] = raw as unknown[];
    return {
      denominator: V1_SKIM_DENOMINATOR,
      baselineSkimBps: Number(baseline),
      bountyBps: Number(bounty),
      maxReferralBpsOfVolume: Number(maxRef),
      lpFeePips: Number(lp),
      bountyRecipient: bountyR as Address,
      protocolRecipient: protocolR as Address,
      referralPayout: payout as Address,
    };
  }
  const o = raw as Record<string, unknown>;
  if (o.baselineSkimBps === undefined) return null;
  return {
    denominator: BPS,
    baselineSkimBps: Number(o.baselineSkimBps),
    bountyBps: Number(o.bountyBps),
    maxReferralBpsOfVolume: Number(o.maxReferralBpsOfVolume),
    lpFeePips: Number(o.lpFeePips ?? o.lpFee),
    bountyRecipient: o.bountyRecipient as Address,
    protocolRecipient: o.protocolRecipient as Address,
    referralPayout: o.referralPayout as Address | undefined,
  };
}

/** percent of volume for a skim value in `denominator` units */
export const skimPercent = (v: number, denominator: number = BPS): number => (v * 100) / denominator;
/** percent of the swap amount for a pips value */
export const feePercent = (v: number): number => (v * 100) / FEE_DENOMINATOR;

export function feeSummary(s: SkimView): string {
  return `${feePercent(s.lpFeePips).toFixed(2)}% lp fee + ${skimPercent(s.baselineSkimBps, s.denominator).toFixed(2)}% baseline skim`;
}
