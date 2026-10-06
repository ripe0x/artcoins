import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { loadState, saveState, keeperState, emptyState } from '../state.mjs';
import { tmpDir } from './helpers.mjs';

test('missing file gives empty state', () => {
  assert.deepEqual(loadState(path.join(tmpDir(), 'nope.json')), emptyState());
});

test('round trip keeps timers, bigints and the tx in flight', () => {
  const f = path.join(tmpDir(), 'sub', 'state.json');
  const s = emptyState();
  const k = keeperState(s, '111');
  k.lastRunAt = 1_790_000_000;
  k.consecutiveReverts = 1;
  s.inFlight = { keeper: '111', hash: '0xab', nonce: 7, sentAt: 1_790_000_100, fn: 'run', args: [true, 123456789012345678901234567890n] };
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
