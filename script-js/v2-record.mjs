#!/usr/bin/env node
// Builds the deployments record of a v2 broadcast: the registry fragment {chainId, repoCommit, owner, stacks,
// contracts} with deployTxHash, deployBlock, deployedAt and source.commit filled from the forge broadcast file.
//   node script-js/v2-record.mjs <tmp/v2-deploy-1.json> <broadcast/DeployV2Stack.s.sol/1/run-latest.json> <out.json> [--verified]
// --verified records source.bytecodeMatch verified (the verify-v2.sh chain check passed).
import fs from 'node:fs';
import { execSync } from 'node:child_process';

const [deployJson, broadcastJson, out, opt] = process.argv.slice(2);
if (!out) { console.error('usage: node script-js/v2-record.mjs <deploy.json> <broadcast run-latest.json> <out.json>'); process.exit(2); }
const d = JSON.parse(fs.readFileSync(deployJson, 'utf8'));
const b = JSON.parse(fs.readFileSync(broadcastJson, 'utf8'));
const die = (m) => { console.error('v2-record: ' + m); process.exit(1); };
const low = (a) => String(a).toLowerCase();
const commit = execSync('git rev-parse HEAD').toString().trim();
const date = new Date(b.timestamp).toISOString().slice(0, 10);
const blockOf = Object.fromEntries(b.receipts.map((r) => [low(r.transactionHash), Number(BigInt(r.blockNumber))]));

const find = (addr) => b.transactions.find((t) => low(t.contractAddress) === low(addr))
  ?? b.transactions.find((t) => (t.additionalContracts ?? []).some((x) => low(x.address) === low(addr)));
const contracts = d.contracts.map((c) => {
  const t = find(c.address) ?? die('no broadcast tx creates ' + c.name + ' ' + c.address);
  const block = blockOf[low(t.hash)] ?? die('no receipt for ' + t.hash);
  return { ...c, deployBlock: block, deployTxHash: t.hash, deployedAt: date, source: { ...c.source, commit, bytecodeMatch: opt === '--verified' ? 'verified' : c.source.bytecodeMatch, profile: 'ci', metadata: 'none' } };
});
const factory = contracts.find((c) => c.role === 'factory');
const stacks = Object.fromEntries(Object.entries(d.stack).map(([id, s]) => [id, { ...s, deployedAt: date }]));
fs.writeFileSync(out, JSON.stringify({ chainId: d.chainId, repoCommit: commit, owner: d.owner, stacks, contracts }, null, 2) + '\n');
console.log(`v2-record: ${out} (${contracts.length} contracts, factory block ${factory.deployBlock})`);
