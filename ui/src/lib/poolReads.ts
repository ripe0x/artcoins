import type { Address } from 'viem';
import { SKIM_DENOMINATOR, FEE_DENOMINATOR } from './constants';

/** One shape for the hook's per pool fee config, v1 returns 8 outputs, v2 returns a struct. */
export interface SkimView {
  baselineSkimBps: number;
  bountyBps: number;
  maxReferralBpsOfVolume: number;
  lpFee: number;
  bountyRecipient: Address;
  protocolRecipient: Address;
  referralPayout: Address;
  quoteToken: Address;
}

export function normalizeSkim(raw: unknown): SkimView | null {
  if (!raw) return null;
  if (Array.isArray(raw)) {
    if (raw.length < 8) return null;
    const [baseline, bounty, maxRef, lp, bountyR, protocolR, payout, quote] = raw as unknown[];
    return {
      baselineSkimBps: Number(baseline),
      bountyBps: Number(bounty),
      maxReferralBpsOfVolume: Number(maxRef),
      lpFee: Number(lp),
      bountyRecipient: bountyR as Address,
      protocolRecipient: protocolR as Address,
      referralPayout: payout as Address,
      quoteToken: quote as Address,
    };
  }
  const o = raw as Record<string, unknown>;
  if (o.baselineSkimBps === undefined) return null;
  return {
    baselineSkimBps: Number(o.baselineSkimBps),
    bountyBps: Number(o.bountyBps),
    maxReferralBpsOfVolume: Number(o.maxReferralBpsOfVolume),
    lpFee: Number(o.lpFee),
    bountyRecipient: o.bountyRecipient as Address,
    protocolRecipient: o.protocolRecipient as Address,
    referralPayout: o.referralPayout as Address,
    quoteToken: o.quoteToken as Address,
  };
}

/** percent of volume for a SKIM_DENOMINATOR value */
export const skimPercent = (v: number): number => (v * 100) / SKIM_DENOMINATOR;
/** percent of the swap amount for a pips value */
export const feePercent = (v: number): number => (v * 100) / FEE_DENOMINATOR;

export function feeSummary(s: SkimView): string {
  return `${feePercent(s.lpFee).toFixed(2)}% lp fee + ${skimPercent(s.baselineSkimBps).toFixed(2)}% baseline skim`;
}
