// KR-05: the public route is `/healthz` and answers only {ok, lastTickAgeSeconds} (200, or 503 when no tick finished
// within 3 intervals plus 2 minutes, so the fly check goes red when the loop is stuck). Everything else (previews,
// results, balance, alerts, the tx in flight without its hash) is on `/status`, and the counters on `/metrics`, both
// behind `authorization: Bearer <STATUS_TOKEN>`. Without STATUS_TOKEN both answer 404. A tx hash appears only once
// it is mined (`lastTx`); the tx in flight shows keeper, nonce, age and replacement count, never its hash or args.
import http from 'node:http';
import crypto from 'node:crypto';

const big = (_k, v) => (typeof v === 'bigint' ? v.toString() : v);

/// public liveness: nothing but ok and the age of the last finished tick
export function health(ctx, nowSeconds = Math.floor(Date.now() / 1000)) {
  const { cfg, state } = ctx;
  const limit = 3 * cfg.intervalSeconds + 120;
  const age = state.lastTickAt ? nowSeconds - state.lastTickAt : null;
  const starting = !state.lastTickAt && nowSeconds - ctx.startedAt < limit;
  const ok = starting || (age !== null && age <= limit);
  return { ok, lastTickAgeSeconds: age };
}

/// operator detail (token guarded). no unmined tx hash, no quoted args
export function status(ctx, nowSeconds = Math.floor(Date.now() / 1000)) {
  const { cfg, state } = ctx;
  const alerts = [];
  const keepers = {};
  for (const k of cfg.keepers) {
    const s = state.keepers[k.id] || {};
    const t = ctx.lastTick?.keepers?.[k.id] || {};
    keepers[k.id] = {
      address: k.address, token: k.token, lastResult: s.lastResult ?? null, lastRunAt: s.lastRunAt ?? null,
      lastTx: s.lastTx ?? null, consecutiveReverts: s.consecutiveReverts ?? 0, nextCheckAt: s.nextCheckAt ?? null,
      backoffUntil: s.backoffUntil ?? null, noProgress: s.noProgress ?? null, outcomes: s.outcomes ?? {},
      lastOutcome: s.lastOutcome ? { outcome: s.lastOutcome.outcome, at: s.lastOutcome.at, nonce: s.lastOutcome.nonce } : null,
      preview: t.preview ?? null, reasons: t.reasons ?? null, quote: t.quote ?? null,
    };
    if (s.noProgress) alerts.push({ keeper: k.id, alert: 'no_progress', ...s.noProgress });
    if ((s.consecutiveReverts ?? 0) >= 2) alerts.push({ keeper: k.id, alert: 'consecutive_reverts', count: s.consecutiveReverts });
  }
  const f = state.inFlight;
  const inFlight = f
    ? { keeper: f.keeper, nonce: f.nonce, ageSeconds: nowSeconds - f.sentAt, replacements: f.replacements ?? 0, cancelling: Boolean(f.cancel) }
    : null;
  if (f && (f.replacements || f.cancel)) alerts.push({ alert: 'stuck_tx', keeper: f.keeper, nonce: f.nonce });
  const balance = ctx.lastTick?.balance ?? null;
  if (balance !== null && balance < cfg.lowBalanceWei) alerts.push({ alert: 'low_balance', balance, needWei: cfg.lowBalanceWei });
  return {
    ...health(ctx, nowSeconds), lastTickAt: state.lastTickAt, intervalSeconds: cfg.intervalSeconds,
    address: ctx.io?.address ?? null, balance, dryRun: cfg.dryRun, inFlight, lastError: ctx.lastError ?? null, alerts, keepers,
  };
}

/// constant time bearer check. false when no token is configured
export function authorized(cfg, header) {
  if (!cfg.statusToken) return false;
  const m = /^Bearer\s+(.+)$/i.exec(String(header || ''));
  if (!m) return false;
  const a = crypto.createHash('sha256').update(m[1].trim()).digest();
  const b = crypto.createHash('sha256').update(cfg.statusToken).digest();
  return crypto.timingSafeEqual(a, b);
}

export function startServer(ctx, port = ctx.cfg.port) {
  const server = http.createServer((req, res) => {
    const url = (req.url || '/').split('?')[0];
    if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405).end(); return; }
    if (url === '/healthz') {
      const h = health(ctx);
      res.writeHead(h.ok ? 200 : 503, { 'content-type': 'application/json' });
      res.end(JSON.stringify(h));
      return;
    }
    if (url === '/status' || url === '/metrics') {
      if (!ctx.cfg.statusToken) { res.writeHead(404, { 'content-type': 'text/plain' }).end('not found\n'); return; }
      if (!authorized(ctx.cfg, req.headers.authorization)) {
        res.writeHead(401, { 'content-type': 'text/plain', 'www-authenticate': 'Bearer' }).end('unauthorized\n');
        return;
      }
      if (url === '/status') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify(status(ctx), big));
      } else {
        res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4' });
        res.end(ctx.metrics.render());
      }
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' }).end('not found\n');
  });
  return new Promise((resolve) => server.listen(port, () => resolve(server)));
}
