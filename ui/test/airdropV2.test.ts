import { test } from 'node:test';
import assert from 'node:assert/strict';
import { concat, encodeAbiParameters, keccak256, type Address, type Hex } from 'viem';
import { buildAllowlistFile, buildTree, getRoot, verifyProof } from '../src/lib/merkle';
import {
  airdropCandidates,
  claimWindowOpen,
  pickTranche,
  trancheState,
  ZERO_ROOT,
  type TrancheRead,
  type TrancheView,
} from '../src/lib/airdropV2';

// Port of ArtCoinsAirdropV2._leaf:
//   keccak256(bytes.concat(keccak256(abi.encode(account, amount))))
function solLeaf(account: Address, amount: bigint): Hex {
  const inner = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account, amount]));
  return keccak256(concat([inner]));
}

// Port of OpenZeppelin MerkleProof.processProof (commutativeKeccak256: the pair is sorted).
function solPair(a: Hex, b: Hex): Hex {
  return BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a]));
}
function solProcessProof(proof: readonly Hex[], leaf: Hex): Hex {
  return proof.reduce<Hex>((acc, sibling) => solPair(acc, sibling), leaf);
}

const A0: Address = '0x1111111111111111111111111111111111111111';
const A1: Address = '0x2222222222222222222222222222222222222222';
const AMT0 = 1_000_000_000_000_000_000n;
const AMT1 = 2_500_000_000_000_000_000n;

// Independent vectors computed with `cast keccak` / `cast abi-encode` (not with the code under test).
const CAST_LEAF0 = '0xb38ec842db1cd54e5e5ce48491f1a404551e9726ebda349d0478e189e0996dd4';
const CAST_LEAF1 = '0xb92c48e9d7abe27fd8dfd6b5dfdbfb1c9a463f80c712b66f3a5180a090cccafc';
const CAST_ROOT = '0x5aafa111a8add43a7c11e121dc72ce8d1e138114e148625f6411b4cf96664fd7';

test('ui tree leaf hashing equals the solidity leaf for two leaves', () => {
  assert.equal(solLeaf(A0, AMT0), CAST_LEAF0);
  assert.equal(solLeaf(A1, AMT1), CAST_LEAF1);
  const tree = buildTree([
    { address: A0, amount: AMT0.toString() },
    { address: A1, amount: AMT1.toString() },
  ]);
  assert.equal(tree.leafHash([A0, AMT0.toString()]), CAST_LEAF0);
  assert.equal(tree.leafHash([A1, AMT1.toString()]), CAST_LEAF1);
});

test('ui tree root equals the solidity recomputation of the root for two leaves', () => {
  const tree = buildTree([
    { address: A0, amount: AMT0.toString() },
    { address: A1, amount: AMT1.toString() },
  ]);
  const solRoot = solPair(solLeaf(A0, AMT0), solLeaf(A1, AMT1));
  assert.equal(getRoot(tree), solRoot);
  assert.equal(getRoot(tree), CAST_ROOT);
});

test('a ui built proof verifies through the solidity MerkleProof walk, and a wrong amount does not', () => {
  const file = buildAllowlistFile('0x00000000000000000000000000000000000000aa', [
    { address: A0, amount: AMT0.toString() },
    { address: A1, amount: AMT1.toString() },
  ]);
  assert.equal(file.root, CAST_ROOT);
  for (const e of file.entries) {
    assert.equal(solProcessProof(e.proof, solLeaf(e.address, BigInt(e.amount))), file.root);
    assert.ok(verifyProof(file.root, e.address, e.amount, e.proof));
    assert.notEqual(solProcessProof(e.proof, solLeaf(e.address, BigInt(e.amount) + 1n)), file.root);
    assert.equal(verifyProof(file.root, e.address, (BigInt(e.amount) + 1n).toString(), e.proof), false);
  }
});

const T = (over: Partial<TrancheView> = {}): TrancheView => ({
  sweepRecipient: A1,
  merkleRoot: CAST_ROOT,
  supply: 100n,
  totalClaimed: 0n,
  lockupEnd: 1000n,
  vestingEnd: 2000n,
  sweepTime: 3000n,
  swept: false,
  ...over,
});

test('trancheState follows the contract windows', () => {
  assert.equal(trancheState(T({ supply: 0n }), 1500n), 'none');
  assert.equal(trancheState(T(), 999n), 'locked');
  assert.equal(trancheState(T(), 1000n), 'vesting'); // claim needs now >= lockupEnd
  assert.equal(trancheState(T(), 1999n), 'vesting');
  assert.equal(trancheState(T(), 2000n), 'vested');
  assert.equal(trancheState(T(), 2999n), 'vested');
  assert.equal(trancheState(T(), 3000n), 'closed'); // claim reverts at now >= sweepTime
  assert.equal(trancheState(T({ swept: true }), 3500n), 'swept');
  for (const s of ['none', 'locked', 'closed', 'swept'] as const) assert.equal(claimWindowOpen(s), false);
  for (const s of ['vesting', 'vested'] as const) assert.equal(claimWindowOpen(s), true);
});

test('airdropCandidates keeps extension order as the index, filtered by the configured airdrop', () => {
  const dev: Address = '0x00000000000000000000000000000000000000d0';
  const ad: Address = '0x00000000000000000000000000000000000000Ad';
  assert.deepEqual(airdropCandidates([dev, ad, ad], ad), [
    { index: 1, extension: ad },
    { index: 2, extension: ad },
  ]);
  assert.deepEqual(airdropCandidates([dev, ad], null).map(c => c.index), [0, 1]);
  assert.deepEqual(airdropCandidates([], ad), []);
});

test('pickTranche prefers the explicit index, then the matching root, skips empty tranches', () => {
  const r = (index: number, tr: TrancheView): TrancheRead => ({ index, extension: A0, tranche: tr });
  const other = ('0x' + '11'.repeat(32)) as Hex;
  const reads = [r(0, T({ merkleRoot: other })), r(1, T()), r(2, T({ supply: 0n, merkleRoot: ZERO_ROOT as Hex }))];
  assert.equal(pickTranche(reads, CAST_ROOT, undefined)?.index, 1);
  assert.equal(pickTranche(reads, CAST_ROOT.toUpperCase().replace('0X', '0x'), undefined)?.index, 1);
  assert.equal(pickTranche(reads, CAST_ROOT, 0)?.index, 0);
  assert.equal(pickTranche(reads, CAST_ROOT, 2)?.index, 1); // index 2 has no supply, falls back to the root
  assert.equal(pickTranche(reads, undefined, undefined)?.index, 0);
  assert.equal(pickTranche([r(0, T({ supply: 0n }))], CAST_ROOT, 0), null);
});
