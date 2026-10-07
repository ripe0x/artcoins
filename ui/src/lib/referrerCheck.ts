import { getAddress, isAddress, type Address } from 'viem';
import { ZERO_ADDRESS } from './constants';

export type ReferrerCheck = { ok: true; address: Address } | { ok: false; reason: string };

/** Pure validation of a referrer candidate. `self` is the connected wallet. */
export function checkReferrer(raw: string | null | undefined, self?: string | null): ReferrerCheck {
  if (!raw) return { ok: false, reason: 'empty' };
  const s = raw.trim();
  if (!isAddress(s, { strict: true })) return { ok: false, reason: 'not a valid address or bad checksum' };
  const a = getAddress(s);
  if (a === ZERO_ADDRESS) return { ok: false, reason: 'the zero address is not a referrer' };
  if (self && a.toLowerCase() === self.toLowerCase()) return { ok: false, reason: 'you cannot refer yourself' };
  return { ok: true, address: a };
}

