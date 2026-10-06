#!/usr/bin/env node
// Merges the record written by script/v2/deploy.sh into the registry, then runs verify-registry on the result.
//   node script-js/merge-v2.mjs <deployments/1.v2.json> [--cutover] [--build] [--file deployments/mainnet.json]
// --build makes verify-registry build every artifact variant first (default: use the foundry-out-* dirs as they are).
// The record's stack (id v2) replaces any entry with that id and its contracts replace the stack's contracts.
// Without --cutover the stack and its contracts get status superseded and the stack with status current is
// untouched. --cutover sets the record's stack to current and the previous current stack and its contracts to
// superseded. Then run: cd script-js && npm run gen:addresses
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const argv = process.argv.slice(2);
const record = argv.find((a) => !a.startsWith('--') && a !== argv[argv.indexOf('--file') + 1]);
const cutover = argv.includes('--cutover');
const file = argv.includes('--file') ? argv[argv.indexOf('--file') + 1] : 'deployments/mainnet.json';
if (!record) { console.error('usage: node script-js/merge-v2.mjs <record.json> [--cutover] [--file registry.json]'); process.exit(2); }
const rec = JSON.parse(fs.readFileSync(record, 'utf8'));
const reg = JSON.parse(fs.readFileSync(file, 'utf8'));
const die = (m) => { console.error('merge-v2: ' + m); process.exit(1); };
if (rec.chainId !== reg.chainId) die(`record chain ${rec.chainId}, registry chain ${reg.chainId}`);
const ids = Object.keys(rec.stacks);
if (ids.length !== 1 || ids[0] !== 'v2') die('record must hold exactly the stack v2, got ' + ids);

const setStatus = (id, status) => {
  reg.stacks[id].status = status;
  for (const c of reg.contracts) if (c.stack === id) c.status = status;
};
reg.stacks.v2 = rec.stacks.v2;
reg.contracts = [...reg.contracts.filter((c) => c.stack !== 'v2'), ...rec.contracts];
if (cutover) for (const [id, s] of Object.entries(reg.stacks)) if (id !== 'v2' && s.status === 'current') setStatus(id, 'superseded');
setStatus('v2', cutover ? 'current' : 'superseded');
fs.writeFileSync(file, JSON.stringify(reg, null, 2) + '\n');
console.log(`merge-v2: ${file} now has stack v2 (${cutover ? 'current' : 'superseded'}), ${rec.contracts.length} contracts`);

for (const flags of [['--shape'], ['--file', file, argv.includes('--build') ? '--build' : '--no-build']]) {
  const r = spawnSync('node', ['script-js/verify-registry.mjs', ...(flags[0] === '--shape' ? ['--shape', '--file', file] : flags)], { stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status ?? 1);
}
