// Wires config, state, io and metrics into a runtime the entry point (index.mjs) and the tests share.
import { getAddress } from 'viem';
import { loadConfig, readRegistry, DEFAULT_REGISTRY } from './config.mjs';
import { createIo } from './chain.mjs';
import { loadState, checkStateDir } from './state.mjs';
import { Metrics } from './metrics.mjs';
import { tick } from './runner.mjs';
import * as L from './log.mjs';

export async function createRuntime(env = process.env, { io: ioOverride, registry } = {}) {
  const reg = registry ?? readRegistry(env.REGISTRY_PATH || DEFAULT_REGISTRY);
  const cfg = loadConfig(env, reg);
  // KR-13: the key lives in the viem account from here on, not in the process environment
  if (env === process.env) delete process.env.KEEPER_PRIVATE_KEY;
  // KR-10: refuse a missing volume instead of starting from empty state
  checkStateDir(cfg.statePath, cfg.ephemeralState);
  const metrics = new Metrics();
  const io = ioOverride ?? createIo(cfg, {
    onRetry: (err, attempt, wait) => {
      metrics.inc('keeper_rpc_retries_total');
      L.warn('rpc retry', { attempt, waitMs: Math.round(wait), error: err.shortMessage || err.message });
    },
  });
  const state = loadState(cfg.statePath);
  return { cfg, io, state, metrics, startedAt: Math.floor(Date.now() / 1000), lastTick: null, lastError: null };
}

/// startup checks against the chain: chain id, keeper code present
export async function preflight(ctx) {
  const { cfg, io } = ctx;
  const id = await io.chainId();
  if (id !== cfg.chainId) throw new Error(`rpc chain id ${id}, registry chain id ${cfg.chainId}`);
  for (const k of cfg.keepers) {
    if (!k.address) continue;
    const code = await io.getCode(k.address);
    if (!code || code === '0x') throw new Error(`keeper ${k.id} at ${getAddress(k.address)} has no code on this chain`);
  }
  L.info('preflight ok', {
    address: io.address, rpc: new URL(cfg.rpcUrl).host, privateRpc: cfg.privateRpcUrl ? new URL(cfg.privateRpcUrl).host : null,
    keepers: cfg.keepers.map((k) => ({ id: k.id, address: k.address, token: k.token, gas: k.gas, slippageBps: k.slippageBps })),
    v2: cfg.v2.live ? `v2 stack live, ${cfg.v2.coins.length} coins` : 'no v2 stack in the registry, v2 keeper skipped',
    dryRun: cfg.dryRun, intervalSeconds: cfg.intervalSeconds, maxGasWei: cfg.maxGasWei, requiredBalanceWei: cfg.requiredBalanceWei,
    privateKeepers: [...cfg.privateKeepers], publicMempool: cfg.allowPublicMempool, statusRoutes: Boolean(cfg.statusToken),
    cadence: cfg.keepers.map((k) => ({ id: k.id, checkIntervalSeconds: k.checkIntervalSeconds, minRunIntervalSeconds: k.minRunIntervalSeconds })),
  });
  if (!cfg.privateRpcUrl) L.warn('no PRIVATE_RPC_URL: every send goes through the public mempool', { allowPublicMempool: cfg.allowPublicMempool });
}

export async function safeTick(ctx) {
  try {
    const s = await tick(ctx);
    ctx.lastError = null;
    return s;
  } catch (err) {
    ctx.lastError = err.shortMessage || err.message;
    ctx.metrics.inc('keeper_tick_errors_total');
    L.error('tick failed', { error: ctx.lastError });
    return null;
  }
}
