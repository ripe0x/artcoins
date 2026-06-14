import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import type { Address } from 'viem';

export interface AllowlistEntry {
  address: Address;
  /** Allocation in wei (uint256 as a decimal string for JSON-safety). */
  amount: string;
}

export interface AllowlistEntryWithProof extends AllowlistEntry {
  proof: `0x${string}`[];
}

/** Shape of the JSON blob written to ui/public/allowlists/<token>.json. */
export interface AllowlistFile {
  token: Address;
  root: `0x${string}`;
  entries: AllowlistEntryWithProof[];
}

const LEAF_TYPES = ['address', 'uint256'] as const;

export function buildTree(entries: AllowlistEntry[]): StandardMerkleTree<[string, string]> {
  const values: [string, string][] = entries.map(e => [e.address, e.amount]);
  return StandardMerkleTree.of(values, [...LEAF_TYPES]);
}

export function getRoot(tree: StandardMerkleTree<[string, string]>): `0x${string}` {
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

/** Verify an (address, amount, proof) against a root — convenience wrapper. */
export function verifyProof(
  root: `0x${string}`,
  address: Address,
  amount: string,
  proof: readonly `0x${string}`[]
): boolean {
  return StandardMerkleTree.verify(root, [...LEAF_TYPES], [address, amount], [...proof]);
}

/** Build a full allowlist file (root + per-entry proofs) ready to serialize to JSON. */
export function buildAllowlistFile(
  token: Address,
  entries: AllowlistEntry[]
): AllowlistFile {
  const tree = buildTree(entries);
  const withProofs: AllowlistEntryWithProof[] = [];
  for (const [i, value] of tree.entries()) {
    withProofs.push({
      address: value[0] as Address,
      amount: value[1],
      proof: tree.getProof(i) as `0x${string}`[],
    });
  }
  return {
    token,
    root: getRoot(tree),
    entries: withProofs,
  };
}
