// /healthz (json: last tick, per keeper last result) and /metrics (plain text counters) on PORT.
// /healthz answers 503 when no tick finished within 3 intervals (plus a 2 minute grace), so the fly check
// goes red when the loop is stuck. it exposes nothing that is not already public on chain.
import http from 'node:http';

const big = (_k, v) => (typeof v === 'bigint' ? v.toString() : v);

export function health(ctx, nowSeconds = Math.floor(Date.now() / 1000)) {
  const { cfg, state } = ctx;
  const limit = 3 * cfg.intervalSeconds + 120;
  const age = state.lastTickAt ? nowSeconds - state.lastTickAt : null;
  const starting = !state.lastTickAt && nowSeconds - ctx.startedAt < limit;
  const ok = starting || (age !== null && age <= limit);
  const keepers = {};
  for (const k of cfg.keepers) {
    const s = state.keepers[k.id] || {};
    keepers[k.id] = {
      address: k.address, token: k.token, lastResult: s.lastResult ?? null, lastRunAt: s.lastRunAt ?? null,
      lastTx: s.lastTx ?? null, consecutiveReverts: s.consecutiveReverts ?? 0,
      preview: ctx.lastTick?.keepers?.[k.id]?.preview ?? null, reasons: ctx.lastTick?.keepers?.[k.id]?.reasons ?? null,
    };
  }
  return {
    ok, starting, lastTickAt: state.lastTickAt, lastTickAgeSeconds: age, intervalSeconds: cfg.intervalSeconds,
    address: ctx.io?.address ?? null, balance: ctx.lastTick?.balance ?? null, dryRun: cfg.dryRun, inFlight: state.inFlight,
    lastError: ctx.lastError ?? null, keepers,
  };
}

export function startServer(ctx, port = ctx.cfg.port) {
  const server = http.createServer((req, res) => {
    const url = (req.url || '/').split('?')[0];
    if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405).end(); return; }
    if (url === '/healthz') {
      const h = health(ctx);
      res.writeHead(h.ok ? 200 : 503, { 'content-type': 'application/json' });
      res.end(JSON.stringify(h, big));
      return;
    }
    if (url === '/metrics') {
      res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' });
      res.end(ctx.metrics.render());
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' }).end('not found\n');
  });
  return new Promise((resolve) => server.listen(port, () => resolve(server)));
}
