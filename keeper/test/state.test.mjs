import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { loadState, saveState, keeperState, emptyState, checkStateDir } from '../state.mjs';
import { createRuntime } from '../app.mjs';
import { tmpDir, baseEnv, realRegistry } from './helpers.mjs';

test('missing file gives empty state', () => {
  assert.deepEqual(loadState(path.join(tmpDir(), 'nope.json')), emptyState());
});

test('round trip keeps timers, bigints and the tx in flight', () => {
  const f = path.join(tmpDir(), 'sub', 'state.json');
  const s = emptyState();
  const k = keeperState(s, '111');
  k.lastRunAt = 1_790_000_000;
  k.consecutiveReverts = 1;
  s.inFlight = {
    keeper: '111', hash: '0xab', hashes: ['0xaa', '0xab'], cancelHashes: [], nonce: 7, sentAt: 1_790_000_100, lastSentAt: 1_790_002_000,
    fn: 'run', args: [true, 123456789012345678901234567890n], maxFeePerGas: 2_362_500_000n, maxPriorityFeePerGas: 112_500_000n, replacements: 1,
  };
  s.lastTickAt = 1_790_000_200;
  saveState(f, s);
  const back = loadState(f);
  assert.deepEqual(back, s);
  assert.equal(typeof back.inFlight.args[1], 'bigint');
  assert.deepEqual(fs.readdirSync(path.dirname(f)), ['state.json']); // temp file renamed away
});

test('a corrupt or foreign state file refuses to load (no silent re run)', () => {
  const d = tmpDir();
  fs.writeFileSync(path.join(d, 'bad.json'), '{not json');
  assert.throws(() => loadState(path.join(d, 'bad.json')));
  fs.writeFileSync(path.join(d, 'v9.json'), JSON.stringify({ version: 9 }));
  assert.throws(() => loadState(path.join(d, 'v9.json')), /version 9/);
});

// KR-10: a missing state dir (volume not mounted) refuses to start unless EPHEMERAL_STATE=1
test('KR-10 missing state directory refuses to start; EPHEMERAL_STATE=1 creates it', async () => {
  const gone = path.join(tmpDir(), 'not-mounted', 'state.json');
  assert.throws(() => checkStateDir(gone, false), /volume not mounted/);
  await assert.rejects(createRuntime(baseEnv(tmpDir(), { STATE_PATH: gone }), { registry: realRegistry(), io: {} }), /volume not mounted/);
  const ctx = await createRuntime(baseEnv(tmpDir(), { STATE_PATH: gone, EPHEMERAL_STATE: '1' }), { registry: realRegistry(), io: {} });
  assert.equal(ctx.state.inFlight, null);
  assert.ok(fs.existsSync(path.dirname(gone)));
});
