import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from '../config.mjs';
import { emptyState } from '../state.mjs';
import { Metrics } from '../metrics.mjs';
import { startServer } from '../server.mjs';
import { realRegistry, baseEnv, tmpDir } from './helpers.mjs';

test('http: /healthz json, /metrics text, 404 elsewhere, 503 when stale', async () => {
  const cfg = loadConfig(baseEnv(tmpDir()), realRegistry());
  const now = Math.floor(Date.now() / 1000);
  const state = emptyState();
  state.lastTickAt = now - 5;
  state.keepers['111'] = { lastResult: 'ok', lastRunAt: now - 5, consecutiveReverts: 0 };
  const metrics = new Metrics();
  metrics.inc('keeper_ticks_total');
  const ctx = { cfg, state, metrics, startedAt: now - 100, io: { address: '0xabc' }, lastTick: { balance: 10n ** 16n, keepers: {} } };
  const server = await startServer(ctx, 0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const h = await fetch(base + '/healthz');
    assert.equal(h.status, 200);
    const body = await h.json();
    assert.equal(body.lastTickAt, now - 5);
    assert.equal(body.keepers['111'].lastResult, 'ok');
    assert.equal(body.balance, '10000000000000000');
    const m = await fetch(base + '/metrics');
    assert.equal(m.status, 200);
    assert.match(await m.text(), /keeper_ticks_total 1/);
    assert.equal((await fetch(base + '/nope')).status, 404);
    state.lastTickAt = now - 3 * cfg.intervalSeconds - 500;
    assert.equal((await fetch(base + '/healthz')).status, 503);
  } finally {
    server.close();
  }
});
