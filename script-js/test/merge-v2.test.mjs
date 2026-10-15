// node --test script-js/test/merge-v2.test.mjs   (any cwd; schema check only, no rpc)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { getAddress } from 'viem';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const REG = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments/mainnet.json'), 'utf8'));
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'merge-v2-'));
const file = path.join(dir, 'mainnet.json');
const recFile = path.join(dir, 'record.json');
const merge = (...a) => spawnSync('node', [path.join(ROOT, 'script-js/merge-v2.mjs'), recFile, '--no-chain', '--file', file, ...a], { encoding: 'utf8', cwd: ROOT });
const load = () => JSON.parse(fs.readFileSync(file, 'utf8'));

// replacement record: the current v2 contracts at new addresses, deployed one day later
const oldV2 = REG.stacks.v2;
const day = '2026-10-16';
const TEMPLATE = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments/v2.template.json'), 'utf8')).contracts.filter((c) => c.stack === 'v2');
const mkRecord = () => {
  const proto = REG.contracts.find((c) => c.stack === 'v2');
  const contracts = TEMPLATE.map((t, i) => ({
    ...JSON.parse(JSON.stringify(proto)), name: t.name, role: t.role, source: { ...proto.source, repoPath: t.source.repoPath },
    address: getAddress('0x' + (i + 1).toString(16).padStart(40, 'a')), deployedAt: day, notes: 'v2 stack',
  }));
  const factory = contracts.find((c) => c.role === 'factory').address;
  return { chainId: REG.chainId, owner: REG.owner, ownershipPending: false, stacks: { v2: { ...oldV2, factory, deployedAt: day } }, contracts };
};

test('replacement keeps the previous v2 record as v2-<deployedAt>, superseded', () => {
  assert.equal(oldV2.status, 'current');
  fs.writeFileSync(file, JSON.stringify(REG, null, 2));
  fs.writeFileSync(recFile, JSON.stringify(mkRecord()));
  const r = merge();
  assert.equal(r.status, 0, r.stderr);
  const reg = load();
  const key = `v2-${oldV2.deployedAt}`;
  assert.equal(reg.stacks[key].status, 'superseded');
  assert.equal(reg.stacks[key].supersededBy, 'v2');
  assert.equal(reg.stacks[key].supersededAt, day);
  assert.equal(reg.stacks[key].factory, oldV2.factory);
  assert.equal(reg.stacks.v2.status, 'current');
  assert.notEqual(reg.stacks.v2.factory, oldV2.factory);
  const old = reg.contracts.filter((c) => c.stack === key);
  assert.equal(old.length, REG.contracts.filter((c) => c.stack === 'v2').length);
  assert.equal(reg.contracts.filter((c) => c.stack === 'v2').length, TEMPLATE.length);
  assert.ok(old.every((c) => c.status === 'superseded'));
  assert.ok(reg.contracts.filter((c) => c.stack === 'v2').every((c) => c.status === 'current'));
  assert.equal(Object.values(reg.stacks).filter((s) => s.status === 'current').length, 1);
});

test('merging the same record again changes nothing', () => {
  const before = fs.readFileSync(file, 'utf8');
  const r = merge();
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.readFileSync(file, 'utf8'), before);
  assert.equal(Object.keys(load().stacks).filter((k) => k.startsWith('v2')).length, 2);
});

test('an incomplete record (factory only) is refused and the registry is untouched', () => {
  fs.writeFileSync(file, JSON.stringify(REG, null, 2));
  const rec = mkRecord();
  rec.contracts = rec.contracts.filter((c) => c.role === 'factory');
  fs.writeFileSync(recFile, JSON.stringify(rec));
  const r = merge();
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /missing: .*ArtCoinsHookV2/);
  assert.equal(fs.readFileSync(file, 'utf8'), JSON.stringify(REG, null, 2));
});

test('a record with a duplicated name is refused', () => {
  const rec = mkRecord();
  rec.contracts.push({ ...rec.contracts[1], address: getAddress('0x' + 'b'.repeat(40)) });
  fs.writeFileSync(recFile, JSON.stringify(rec));
  const r = merge();
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, new RegExp('duplicated: .*' + rec.contracts[1].name));
});

test('the full record still merges and a repeat merge is idempotent', () => {
  fs.writeFileSync(recFile, JSON.stringify(mkRecord()));
  assert.equal(merge().status, 0);
  const before = fs.readFileSync(file, 'utf8');
  const r = merge();
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.readFileSync(file, 'utf8'), before);
});
