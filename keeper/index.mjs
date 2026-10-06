#!/usr/bin/env node
// artcoins keeper runner: every INTERVAL_SECONDS reads the 111, LAYER and v2 keepers' previews, runs the due
// ones with quoted min outs and fixed gas limits, one tx at a time. See README.md.
import { createRuntime, preflight, safeTick } from './app.mjs';
import { startServer } from './server.mjs';
import { sleep } from './chain.mjs';
import * as L from './log.mjs';

let stopping = false;
let wake = null;

async function main() {
  const ctx = await createRuntime(process.env);
  const server = await startServer(ctx);
  L.info('listening', { port: ctx.cfg.port });
  const stop = (sig) => {
    L.info('stopping after the current tick', { signal: sig });
    stopping = true;
    wake?.();
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);

  for (let attempt = 0; !stopping; attempt++) {
    try {
      await preflight(ctx);
      break;
    } catch (err) {
      ctx.lastError = 'preflight: ' + (err.shortMessage || err.message);
      L.error('preflight failed, retrying', { error: ctx.lastError });
      await sleep(Math.min(300_000, 10_000 * 2 ** attempt));
    }
  }
  while (!stopping) {
    await safeTick(ctx);
    if (stopping) break;
    await new Promise((r) => {
      const t = setTimeout(r, ctx.cfg.intervalSeconds * 1000);
      wake = () => { clearTimeout(t); r(); };
    });
  }
  server.close();
  L.info('stopped');
}

main().catch((err) => {
  L.error('fatal', { error: err.message });
  process.exit(1);
});
