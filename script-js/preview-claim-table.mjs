/**
 * Given an allowlist JSON and a proposed (totalSupply, allocationPct),
 * print the claim outcome for every address: what they'll successfully claim
 * vs. what gets stranded or under-filled.
 *
 * Usage (must run from ui/ or somewhere viem resolves):
 *   node ../script-js/preview-claim-table.mjs <json-path> <totalSupply> <allocationPct>
 *
 * Example:
 *   node ../script-js/preview-claim-table.mjs ./public/allowlists/liquidity-layer.json 1000000000 8
 */
import { readFileSync } from 'node:fs';
import { formatUnits, parseUnits } from 'viem';

const [, , jsonPath, totalSupplyArg, allocationPctArg] = process.argv;
if (!jsonPath || !totalSupplyArg || !allocationPctArg) {
  console.error('Usage: node preview-claim-table.mjs <json> <totalSupply> <allocationPct>');
  process.exit(1);
}

const file = JSON.parse(readFileSync(jsonPath, 'utf8'));

// totalSupply in whole tokens → wei. Allocation in bps.
const totalSupplyWei = parseUnits(totalSupplyArg, 18);
const bps = BigInt(Math.round(Number(allocationPctArg) * 100));
const escrowedWei = (totalSupplyWei * bps) / 10_000n;

const leafSum = file.entries.reduce((a, e) => a + BigInt(e.amount), 0n);

// Simulate claims in leaf order. In reality order is whoever gets the tx in
// first, but for a preview the ordering only matters to the *last* claimer.
let remaining = escrowedWei;
const rows = [];
for (const e of file.entries) {
  const want = BigInt(e.amount);
  const get = want > remaining ? remaining : want;
  remaining -= get;
  rows.push({ address: e.address, allocated: want, claimable: get, shortfall: want - get });
}

const totalClaimable = rows.reduce((a, r) => a + r.claimable, 0n);
const totalShortfall = rows.reduce((a, r) => a + r.shortfall, 0n);

const fmt = w => formatUnits(w, 18).padStart(22);
const pct = (part, whole) =>
  whole === 0n ? '  —   ' : `${(Number((part * 10000n) / whole) / 100).toFixed(2).padStart(5)}%`;

console.log(
  `Supply: ${formatUnits(totalSupplyWei, 18)}   Airdrop: ${allocationPctArg}% = ${formatUnits(escrowedWei, 18)} tokens`
);
console.log(`Leaf sum: ${formatUnits(leafSum, 18)}   (allocation ${escrowedWei >= leafSum ? '≥' : '<'} leaf sum)\n`);

console.log(
  'address'.padEnd(44),
  'allocated'.padStart(22),
  'claimable'.padStart(22),
  'shortfall'.padStart(18),
  ' % of airdrop',
  ' % of LL share'
);
console.log('─'.repeat(135));
for (const r of rows) {
  console.log(
    r.address,
    fmt(r.allocated),
    fmt(r.claimable),
    fmt(r.shortfall).slice(-18),
    pct(r.claimable, escrowedWei),
    pct(r.allocated, leafSum),
  );
}
console.log('─'.repeat(135));
console.log(
  'TOTAL'.padEnd(44),
  fmt(leafSum),
  fmt(totalClaimable),
  fmt(totalShortfall).slice(-18),
);
if (escrowedWei > leafSum) {
  console.log(
    `\nEscrow > leaf sum: ${formatUnits(escrowedWei - leafSum, 18)} tokens stranded until adminClaim (14d after vesting ends).`
  );
} else if (escrowedWei < leafSum) {
  console.log(
    `\n⚠ Escrow < leaf sum: ${formatUnits(leafSum - escrowedWei, 18)} tokens of promised allocation cannot be honored (late claimers revert with TotalMaxClaimed).`
  );
} else {
  console.log(`\n✓ Escrow == leaf sum exactly. Fully covered.`);
}
