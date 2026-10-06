#!/usr/bin/env node
// Merges the record written by script/v2/deploy.sh into the registry, then runs verify-registry on the result.
//   node script-js/merge-v2.mjs <deployments/1.v2.json> [--cutover] [--build] [--file deployments/mainnet.json]
//   node script-js/merge-v2.mjs --rollback [--build] [--file deployments/mainnet.json]
// The record's stack (id v2) is merged over the registry entry (fields the record does not set stay) and its contracts
// replace the stack's contracts. Status: deployed (the stack with status current is untouched), or current when it is
// already current. --cutover sets v2 to current, the previous current stack and its contracts to superseded, and
// stores the previous id in stacks.v2.replaces. It needs a record with every contract bytecode verified and no pending
// ownership. A repeated --cutover changes nothing. --rollback restores the stack named in stacks.v2.replaces and sets
// v2 to deployed. --build makes verify-registry build every artifact variant first (default: use the foundry-out-*
// dirs as they are). The target file is replaced only after the schema check and verify-registry both pass.
// Then run: cd script-js && npm run gen:addresses
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const argv = process.argv.slice(2);
const fi = argv.indexOf('--file');
const file = fi >= 0 ? argv[fi + 1] : 'deployments/mainnet.json';
if (fi >= 0 && (!file || file.startsWith('--'))) { console.error('merge-v2: --file needs a path'); process.exit(2); }
const rest = argv.filter((a, i) => !(fi >= 0 && (i === fi || i === fi + 1)));
const cutover = rest.includes('--cutover');
const rollback = rest.includes('--rollback');
const build = rest.includes('--build');
const record = rest.find((a) => !a.startsWith('--'));
if (rollback ? record || cutover : !record) {
  console.error('usage: node script-js/merge-v2.mjs <record.json> [--cutover] [--build] [--file registry.json]\n       node script-js/merge-v2.mjs --rollback [--build] [--file registry.json]');
  process.exit(2);
}
const die = (m) => { console.error('merge-v2: ' + m); process.exit(1); };
const reg = JSON.parse(fs.readFileSync(file, 'utf8'));
const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

const setContracts = (id, from, to) => { for (const c of reg.contracts) if (c.stack === id && c.status === from) c.status = to; };
const setStatus = (id, to) => { // stack and the contracts that carry the stack's status
  const from = reg.stacks[id].status;
  reg.stacks[id].status = to;
  setContracts(id, from, to);
};

if (rollback) {
  const v2 = reg.stacks.v2 ?? die('registry has no stack v2');
  if (v2.status !== 'current' || !v2.replaces) die('stack v2 is not current with a recorded predecessor');
  const prev = v2.replaces;
  reg.stacks[prev] ?? die('registry has no stack ' + prev);
  setStatus('v2', 'deployed');
  delete v2.replaces;
  setContracts(prev, 'superseded', 'current');
  reg.stacks[prev].status = 'current';
} else {
  const rec = JSON.parse(fs.readFileSync(record, 'utf8'));
  if (rec.chainId !== reg.chainId) die(`record chain ${rec.chainId}, registry chain ${reg.chainId}`);
  if (!eq(rec.owner, reg.owner)) die(`record owner ${rec.owner}, registry owner ${reg.owner}`);
  const ids = Object.keys(rec.stacks);
  if (ids.length !== 1 || ids[0] !== 'v2') die('record must hold exactly the stack v2, got ' + ids);
  const bad = rec.contracts.filter((c) => c.stack !== 'v2');
  if (bad.length) die('record contracts outside stack v2: ' + bad.map((c) => c.name));
  if (cutover && (rec.ownershipPending !== false || rec.contracts.some((c) => c.source.bytecodeMatch !== 'verified'))) {
    die('--cutover needs a record with bytecode verified and ownership accepted (run verify-v2.sh after the accepts, then v2-record.mjs --verified)');
  }
  const old = reg.stacks.v2;
  const was = old?.status;
  const oldContracts = Object.fromEntries(reg.contracts.filter((c) => c.stack === 'v2').map((c) => [c.name, c]));
  reg.stacks.v2 = { ...(old ?? {}), ...rec.stacks.v2 };
  reg.contracts = [
    ...reg.contracts.filter((c) => c.stack !== 'v2'),
    ...rec.contracts.map((c) => (c.notes === 'v2 stack' && oldContracts[c.name]?.notes ? { ...c, notes: oldContracts[c.name].notes } : c)),
  ];
  if (cutover || was === 'current') {
    if (was !== 'current') {
      const prev = Object.keys(reg.stacks).find((id) => id !== 'v2' && reg.stacks[id].status === 'current');
      if (prev) { setStatus(prev, 'superseded'); reg.stacks.v2.replaces = prev; }
    }
    setStatus('v2', 'current');
  } else {
    setStatus('v2', 'deployed');
  }
}

const tmp = file + '.merge-tmp';
fs.writeFileSync(tmp, JSON.stringify(reg, null, 2) + '\n');
const run = (flags) => spawnSync('node', ['script-js/verify-registry.mjs', '--file', tmp, ...flags], { stdio: 'inherit' }).status;
const st = run(['--shape']) || run([build ? '--build' : '--no-build']);
if (st) { fs.rmSync(tmp, { force: true }); console.error(`merge-v2: verification failed (exit ${st}), ${file} unchanged`); process.exit(st); }
fs.renameSync(tmp, file);
console.log(`merge-v2: ${file} now has stack v2 (${reg.stacks.v2.status})${reg.stacks.v2.replaces ? ', replaces ' + reg.stacks.v2.replaces : ''}`);
