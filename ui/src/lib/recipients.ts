import { getAddress, type Address } from 'viem';
import { parseAddress } from './encodeV2';
import { ZERO_ADDRESS } from './constants';

/** Addresses a new recipient may not be, the same set the hook and locker revert on. */
export interface RecipientForbidden {
  coin: Address;
  hook: Address;
  locker: Address;
  escrow: Address;
  poolManager: Address;
}

export type RecipientCheck = { ok: true; address: Address } | { ok: false; error: string };

/** Client side mirror of the contract checks: valid checksum, nonzero, not a contract that cannot receive fees. */
export function validateRecipient(raw: string, f: RecipientForbidden): RecipientCheck {
  if (!raw.trim()) return { ok: false, error: 'enter an address' };
  const a = parseAddress(raw);
  if (!a) return { ok: false, error: 'not a valid address (check the checksum)' };
  if (a === ZERO_ADDRESS) return { ok: false, error: 'the zero address cannot receive fees' };
  const names: [string, Address][] = [
    ['the coin', f.coin],
    ['the hook', f.hook],
    ['the locker', f.locker],
    ['the fee escrow', f.escrow],
    ['the PoolManager', f.poolManager],
  ];
  for (const [label, addr] of names) {
    if (addr !== ZERO_ADDRESS && getAddress(addr) === a) return { ok: false, error: `${label} cannot receive fees` };
  }
  return { ok: true, address: a };
}

export interface RewardRow {
  index: number;
  recipient: Address;
  bps: number;
  /** the slot the launcher appended; the locker rejects changes to it */
  protocolSlot: boolean;
}

/** Reward rows for display. `protocolSlotIndex` is the locker's `protocolSlotIndex(token)` result. */
export function deriveRewardRows(
  bps: readonly number[],
  recipients: readonly Address[],
  protocolSlot: { exists: boolean; index: bigint } | undefined
): RewardRow[] {
  const protocolIndex = protocolSlot?.exists ? Number(protocolSlot.index) : -1;
  return recipients.map((recipient, index) => ({ index, recipient, bps: Number(bps[index] ?? 0), protocolSlot: index === protocolIndex }));
}

/** Whether the connected wallet can edit recipients, and why not. */
export function recipientEditState(isAdmin: boolean, locked: boolean | undefined): 'editable' | 'locked' | 'not-admin' | 'unknown' {
  if (locked === undefined) return 'unknown';
  if (locked) return 'locked';
  return isAdmin ? 'editable' : 'not-admin';
}
