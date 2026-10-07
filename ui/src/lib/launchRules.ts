// Launch rules that the v2 factory enforces (ArtCoinsFactoryV2._validateFee, _validateStrings,
// _validateRestriction), as pure functions so the form, the validator and the tests share one formula.
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

// ── restriction allowlist ───────────────────────────────────────────────────────────────────────

/** Splits the allowlist input on commas and whitespace. */
export function parseAllowedInput(input: string): string[] {
  return input.split(/[\s,]+/).filter(Boolean);
}

/**
 * Entries the factory adds to every restricted launch before the user's: the owner `defaultAllowed` set, the
 * stack escrow, this launch's locker, and one per extension (`_restriction`).
 */
export function seededAllowedCount(defaultAllowedCount: number, extensionCount: number): number {
  return defaultAllowedCount + 2 + extensionCount;
}

/** Folds token `AllowedSet` events, oldest first, into the current allowlist (lowercase addresses). */
export function foldAllowed(events: { account: string; allowed: boolean }[]): string[] {
  const set = new Set<string>();
  for (const e of events) {
    if (e.allowed) set.add(e.account.toLowerCase());
    else set.delete(e.account.toLowerCase());
  }
  return [...set];
}
