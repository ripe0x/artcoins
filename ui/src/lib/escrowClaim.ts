// On a v2 coin the hook pushes each referral fee straight to the referrer (D59). Only a push the referrer could
// not receive is credited to it in the v2 fee escrow (D57, the factory's default `referralPayout`), as native
// eth (token address(0)). That fallback balance is claimed with
// `claim(referrer, address(0))`. Anyone may send that call, the eth always goes to the referrer, unless
// the referrer turned on `selfClaimOnly`, then only the referrer may.
import type { Address } from 'viem';
import { escrowV2Abi } from './abi/v2/escrow';
import { ZERO_ADDRESS } from './constants';

/** wagmi / viem call parameters for claiming `referrer`'s native eth balance from `escrow` */
export function escrowClaimCall(escrow: Address, referrer: Address) {
  return {
    address: escrow,
    abi: escrowV2Abi,
    functionName: 'claim' as const,
    args: [referrer, ZERO_ADDRESS] as const,
  };
}

/** why a claim would revert before it is simulated, null when nothing blocks it client side */
export function escrowClaimBlock(opts: {
  balance: bigint;
  selfClaimOnly: boolean;
  /** the connected wallet */
  caller: Address | undefined;
  referrer: Address;
}): string | null {
  if (opts.balance === 0n) return 'No referral earnings to claim for this address.';
  if (opts.selfClaimOnly && opts.caller?.toLowerCase() !== opts.referrer.toLowerCase()) {
    return 'This referrer turned on self claim only. Only that address can trigger the claim.';
  }
  return null;
}
