// Pure helpers for the v2 airdrop claim path (ArtCoinsAirdropV2). No react, no wagmi: unit tested.
//
// v2 differences from the v1 airdrop the claim page was written for:
//   - tranches are keyed by (token, index), index = position in the launch's `extensions` array,
//     which is also the position in `factory.deploymentInfo(token).extensions`
//   - claims close at sweepTime = vestingEnd + 14 days, after which anyone may sweep the rest
//   - the leaf is keccak256(bytes.concat(keccak256(abi.encode(account, amount)))), the
//     OpenZeppelin StandardMerkleTree leaf over ["address","uint256"], same as lib/merkle.ts
import type { Address } from 'viem';

export interface TrancheView {
  sweepRecipient: Address;
  merkleRoot: `0x${string}`;
  supply: bigint;
  totalClaimed: bigint;
  lockupEnd: bigint;
  vestingEnd: bigint;
  sweepTime: bigint;
  swept: boolean;
}

export type TrancheState =
  | 'none' // no tranche at this (token, index)
  | 'locked' // before lockupEnd
  | 'vesting' // claims open, allocations still vesting linearly
  | 'vested' // fully vested, claims still open
  | 'closed' // past sweepTime, not swept yet, claims revert
  | 'swept'; // remainder sent to the sweep recipient

export const ZERO_ROOT = '0x0000000000000000000000000000000000000000000000000000000000000000';

/** Where a tranche is in its life. Matches the contract: claim needs lockupEnd <= now < sweepTime. */
export function trancheState(t: TrancheView, nowSec: bigint): TrancheState {
  if (t.supply === 0n) return 'none';
  if (t.swept) return 'swept';
  if (nowSec < t.lockupEnd) return 'locked';
  if (nowSec < t.vestingEnd) return 'vesting';
  if (nowSec < t.sweepTime) return 'vested';
  return 'closed';
}

/** True while `claim` can succeed on state alone (it can still revert on proof or amount). */
export function claimWindowOpen(state: TrancheState): boolean {
  return state === 'vesting' || state === 'vested';
}

export function trancheStateLabel(state: TrancheState, t: TrancheView, fmt: (sec: bigint) => string): string {
  switch (state) {
    case 'none':
      return 'airdrop not found on-chain';
    case 'locked':
      return `locked until ${fmt(t.lockupEnd)}`;
    case 'vesting':
      return `claims open, vesting until ${fmt(t.vestingEnd)}`;
    case 'vested':
      return `claims open, fully vested, window closes ${fmt(t.sweepTime)}`;
    case 'closed':
      return 'claim window closed, sweep pending (anyone can call sweep)';
    case 'swept':
      return 'swept, claims closed';
  }
}

export interface AirdropCandidate {
  index: number;
  extension: Address;
}

/**
 * The entries of `deploymentInfo(token).extensions` that can hold an airdrop tranche, with their
 * extension index. When the v2 airdrop address is configured only entries equal to it count;
 * otherwise every entry is a candidate and the caller probes `tranche()` (a non airdrop extension
 * has no such function, the read fails and the candidate is dropped).
 */
export function airdropCandidates(
  extensions: readonly Address[],
  airdrop: Address | null
): AirdropCandidate[] {
  const want = airdrop?.toLowerCase();
  const out: AirdropCandidate[] = [];
  extensions.forEach((extension, index) => {
    if (want && extension.toLowerCase() !== want) return;
    out.push({ index, extension });
  });
  return out;
}

export interface TrancheRead extends AirdropCandidate {
  tranche: TrancheView;
}

/**
 * Pick the tranche the allowlist belongs to: the file's explicit `index` if it names one that
 * exists, else the tranche whose on-chain root equals the file's root, else the first tranche.
 * Tranches with zero supply do not exist and never match.
 */
export function pickTranche(
  reads: readonly TrancheRead[],
  fileRoot: string | undefined,
  fileIndex: number | undefined
): TrancheRead | null {
  const live = reads.filter(r => r.tranche.supply !== 0n);
  if (live.length === 0) return null;
  if (fileIndex !== undefined) {
    const byIndex = live.find(r => r.index === fileIndex);
    if (byIndex) return byIndex;
  }
  if (fileRoot) {
    const byRoot = live.find(r => r.tranche.merkleRoot.toLowerCase() === fileRoot.toLowerCase());
    if (byRoot) return byRoot;
  }
  return live[0];
}
