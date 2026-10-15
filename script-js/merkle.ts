import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import type { Address } from 'viem';

export interface AllowlistEntry {
  address: Address;
  /** Allocation in wei (uint256 as a decimal string for JSON-safety). */
  amount: string;
}

export interface AllowlistEntryWithProof extends AllowlistEntry {
  /** Leaf index: position in the input entries, the first field of the leaf. Claims are tracked per index. */
  index: number;
  proof: `0x${string}`[];
}

/** Shape of the JSON blob written to script-js/data/allowlists/<token>.json. */
export interface AllowlistFile {
  token: Address;
  root: `0x${string}`;
  /**
   * v2 only: the airdrop extension index (position in the launch's extensions array) this tree
   * belongs to. Optional, the claim page falls back to the tranche whose on-chain root matches.
   */
  index?: number;
  entries: AllowlistEntryWithProof[];
}

/** Leaf = (leaf index, recipient, amount); matches ArtCoinsAirdropV2 `leafHash`. */
const LEAF_TYPES = ['uint256', 'address', 'uint256'] as const;
type Leaf = [string, string, string];

export function buildTree(entries: AllowlistEntry[]): StandardMerkleTree<Leaf> {
  const values: Leaf[] = entries.map((e, i) => [String(i), e.address, e.amount]);
  return StandardMerkleTree.of(values, [...LEAF_TYPES]);
}

export function getRoot(tree: StandardMerkleTree<Leaf>): `0x${string}` {
  return tree.root as `0x${string}`;
}

/** Look up an entry by address (case-insensitive); return the amount + proof, or null. */
export function findEntry(
  file: AllowlistFile,
  address: Address
): AllowlistEntryWithProof | null {
  const target = address.toLowerCase();
  return file.entries.find(e => e.address.toLowerCase() === target) ?? null;
}

/** Verify an (index, address, amount, proof) against a root, convenience wrapper. */
export function verifyProof(
  root: `0x${string}`,
  index: number,
  address: Address,
  amount: string,
  proof: readonly `0x${string}`[]
): boolean {
  return StandardMerkleTree.verify(root, [...LEAF_TYPES], [String(index), address, amount], [...proof]);
}

/**
 * Build a full allowlist file (root + per-entry proofs) ready to serialize to JSON.
 * `supply` (coin base units) is the airdrop tranche supply; the build throws when the
 * allocations sum above it.
 */
export function buildAllowlistFile(
  token: Address,
  entries: AllowlistEntry[],
  supply?: bigint
): AllowlistFile {
  if (supply !== undefined) {
    const total = entries.reduce((s, e) => s + BigInt(e.amount), 0n);
    if (total > supply) throw new Error(`allocations ${total} exceed supply ${supply}`);
  }
  const tree = buildTree(entries);
  const withProofs: AllowlistEntryWithProof[] = [];
  for (const [i, value] of tree.entries()) {
    withProofs.push({
      index: Number(value[0]),
      address: value[1] as Address,
      amount: value[2],
      proof: tree.getProof(i) as `0x${string}`[],
    });
  }
  withProofs.sort((a, b) => a.index - b.index);
  return {
    token,
    root: getRoot(tree),
    entries: withProofs,
  };
}
