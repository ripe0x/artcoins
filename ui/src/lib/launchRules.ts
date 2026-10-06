// Launch rules that the v2 factory enforces (ArtCoinsFactoryV2._validateFee, _validateStrings,
// _validateTax), as pure functions so the form, the validator and the tests share one formula.
// Units: skim and referral cap are SKIM_DENOMINATOR (1e5 = 100% of volume), bounty and shares are BPS (1e4).
import {
  BPS,
  MAX_CONTEXT_BYTES,
  MAX_IMAGE_BYTES,
  MAX_METADATA_BYTES,
  MAX_NAME_BYTES,
  MAX_REFERRAL_CAP_OF_VOLUME,
  MAX_SYMBOL_BYTES,
} from './constants';

// ── string caps ─────────────────────────────────────────────────────────────────────────────────

export type StringField = 'name' | 'symbol' | 'image' | 'metadata' | 'context';

/** the cap in utf8 bytes per token string field, same as ArtCoinsTokenV2.MAX_*_BYTES */
export const STRING_CAPS: Record<StringField, number> = {
  name: MAX_NAME_BYTES,
  symbol: MAX_SYMBOL_BYTES,
  image: MAX_IMAGE_BYTES,
  metadata: MAX_METADATA_BYTES,
  context: MAX_CONTEXT_BYTES,
};

const encoder = new TextEncoder();

/** utf8 byte length, what Solidity `bytes(s).length` counts. Not `s.length` (utf16 units). */
export function utf8ByteLength(s: string): number {
  return encoder.encode(s).length;
}

/** null when within the cap, else a readable reason */
export function stringCapIssue(field: StringField, value: string): string | null {
  const len = utf8ByteLength(value);
  const cap = STRING_CAPS[field];
  return len > cap ? `${field} is ${len} bytes, the cap is ${cap} (utf8 bytes, not characters)` : null;
}

// ── referral cap ────────────────────────────────────────────────────────────────────────────────

/**
 * The factory's check (`ReferralCapAboveProtocolFloor`), verbatim:
 *   maxReferralBpsOfVolume * BPS <= baselineSkimBps * (BPS - bountyBps - minProtocolSkimShareBps)
 * The referral leg is carved from the protocol leg and may never take it below
 * `minProtocolSkimShareBps` of the baseline skim (D52). Both sides share the skim unit, so no
 * denominator factor appears. Integers only, no rounding.
 */
export function referralCapWithinFloor(
  maxReferralBpsOfVolume: number,
  baselineSkimBps: number,
  bountyBps: number,
  minProtocolSkimShareBps: number
): boolean {
  const room = BPS - bountyBps - minProtocolSkimShareBps;
  if (room < 0) return false;
  return maxReferralBpsOfVolume * BPS <= baselineSkimBps * room;
}

/**
 * Largest `maxReferralBpsOfVolume` (skim units) the factory accepts for a fee config:
 * `baselineSkimBps * (BPS - bountyBps - minProtocolSkimShareBps) / BPS`, rounded down, and never above
 * `Constants.MAX_REFERRAL_CAP_OF_VOLUME`. Zero when the bounty already leaves no room above the floor.
 */
export function maxReferralCapSkim(baselineSkimBps: number, bountyBps: number, minProtocolSkimShareBps: number): number {
  const room = BPS - bountyBps - minProtocolSkimShareBps;
  if (room <= 0 || baselineSkimBps <= 0) return 0;
  const byFloor = Math.floor((baselineSkimBps * room) / BPS);
  return Math.min(byFloor, MAX_REFERRAL_CAP_OF_VOLUME);
}

// ── tax exempt allowlist ────────────────────────────────────────────────────────────────────────

/** per entry, keyed by lowercase address. 'unknown' = not read yet or the read failed */
export type ExemptStatus = 'allowed' | 'not-allowed' | 'unknown';
export type ExemptStatusMap = Record<string, ExemptStatus>;

export interface ExemptReads {
  /** factory.exemptAllowed(a), undefined when the read has not succeeded */
  exemptAllowed: boolean | undefined;
  /** factory.enabledEscrows(a) */
  enabledEscrow: boolean | undefined;
  /** factory.enabledExtensions(a) */
  enabledExtension: boolean | undefined;
}

/**
 * Mirrors the factory: an exempt entry passes when `exemptAllowed[a]`, or it is this launch's locker or
 * hook, an enabled escrow or an enabled extension (ExemptNotAllowed otherwise, D47).
 */
export function classifyExempt(reads: ExemptReads, a: string, locker: string, hook: string): ExemptStatus {
  const l = a.toLowerCase();
  if (l === locker.toLowerCase() || l === hook.toLowerCase()) return 'allowed';
  if (reads.exemptAllowed || reads.enabledEscrow || reads.enabledExtension) return 'allowed';
  if (reads.exemptAllowed === false && reads.enabledEscrow === false && reads.enabledExtension === false) return 'not-allowed';
  return 'unknown';
}

export const EXEMPT_NOT_ALLOWED = 'not allowed by the launcher owner';
