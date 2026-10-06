import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from '../config.mjs';
import { emptyState } from '../state.mjs';
import { Metrics } from '../metrics.mjs';
import { startServer } from '../server.mjs';
import { realRegistry, baseEnv, tmpDir } from './helpers.mjs';

const TOKEN = 'status-token-for-tests-0123456789';

async function serve(env = {}) {
  const cfg = loadConfig(baseEnv(tmpDir(), env), realRegistry());
  const now = Math.floor(Date.now() / 1000);
  const state = emptyState();
  state.lastTickAt = now - 5;
  state.keepers['111'] = { lastResult: 'ok', lastRunAt: now - 5, consecutiveReverts: 0 };
  state.inFlight = { keeper: '111', hash: '0x' + 'ab'.repeat(32), hashes: ['0x' + 'ab'.repeat(32)], nonce: 3, sentAt: now - 60, fn: 'run', args: [true, 123n] };
  const metrics = new Metrics();
  metrics.inc('keeper_ticks_total');
  const ctx = { cfg, state, metrics, startedAt: now - 100, io: { address: '0xabc' }, lastTick: { balance: 10n ** 16n, keepers: {} } };
  const server = await startServer(ctx, 0);
  return { ctx, now, server, base: `http://127.0.0.1:${server.address().port}` };
}

// KR-05: /healthz is public and says only ok and the tick age; detail and counters need the bearer token
test('http: /healthz {ok, lastTickAgeSeconds} only; /status and /metrics need STATUS_TOKEN; 404 elsewhere; 503 when stale', async () => {
  const { ctx, now, server, base } = await serve({ STATUS_TOKEN: TOKEN });
  try {
    const h = await fetch(base + '/healthz');
    assert.equal(h.status, 200);
    assert.deepEqual(await h.json(), { ok: true, lastTickAgeSeconds: 5 });
    assert.equal((await fetch(base + '/status')).status, 401);
    assert.equal((await fetch(base + '/metrics', { headers: { authorization: 'Bearer wrong-token-0123456789' } })).status, 401);
    const auth = { headers: { authorization: `Bearer ${TOKEN}` } };
    const st = await fetch(base + '/status', auth);
    assert.equal(st.status, 200);
    const text = await st.text();
    const body = JSON.parse(text);
    assert.equal(body.lastTickAt, now - 5);
    assert.equal(body.keepers['111'].lastResult, 'ok');
    assert.equal(body.balance, '10000000000000000');
    assert.deepEqual(body.inFlight, { keeper: '111', nonce: 3, ageSeconds: body.inFlight.ageSeconds, replacements: 0, cancelling: false });
    assert.ok(!text.includes('ab'.repeat(32)), 'no unmined tx hash on /status');
    const m = await fetch(base + '/metrics', auth);
    assert.equal(m.status, 200);
    assert.match(await m.text(), /keeper_ticks_total 1/);
    assert.equal((await fetch(base + '/nope')).status, 404);
    ctx.state.lastTickAt = now - 3 * ctx.cfg.intervalSeconds - 500;
    assert.equal((await fetch(base + '/healthz')).status, 503);
  } finally {
    server.close();
  }
});

test('http: without STATUS_TOKEN the detail routes do not exist', async () => {
  const { server, base } = await serve();
  try {
    assert.equal((await fetch(base + '/status')).status, 404);
    assert.equal((await fetch(base + '/metrics')).status, 404);
    assert.equal((await fetch(base + '/healthz')).status, 200);
  } finally {
    server.close();
  }
});
