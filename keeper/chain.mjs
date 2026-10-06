// viem plumbing: reads, simulations, signing and sending, receipts. Everything the runner does on chain goes
// through the `io` object built here, so tests can swap it for a fake.
import { createPublicClient, encodeFunctionData, http, keccak256 } from 'viem';
import { mainnet } from 'viem/chains';
import { abiFor, erc20Abi, keeper111Abi, keeperLayerAbi, keeperV2Abi } from './abi.mjs';
import { decodeKeeperLogs, decodeReason, describeError, revertDataOf, servicedFrom } from './events.mjs';

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// 429, 5xx, rate limit and network errors are transient. A revert is never transient.
export function isTransient(err) {
  for (let e = err; e; e = e.cause) {
    const m = String(e.details || e.shortMessage || e.message || '').toLowerCase();
    if (/revert/.test(m) || e.name === 'ContractFunctionRevertedError') return false;
  }
  for (let e = err; e; e = e.cause) {
    const status = e.status ?? e.statusCode;
    if (status === 429 || status === 408 || (status >= 500 && status < 600)) return true;
    if (e.code === -32005 || e.code === -32603 || ['ECONNRESET', 'ETIMEDOUT', 'ECONNREFUSED', 'UND_ERR_SOCKET'].includes(e.code)) return true;
    const m = String(e.details || e.shortMessage || e.message || '').toLowerCase();
    if (/rate limit|too many requests|timed? ?out|fetch failed|socket hang up|econnreset|service unavailable|bad gateway/.test(m)) return true;
  }
  return false;
}

/// retries `fn` on transient errors with exponential backoff and jitter
export async function withRetry(fn, { retries = 4, baseMs = 1000, maxMs = 30_000, onRetry } = {}) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt >= retries || !isTransient(err)) throw err;
      const wait = Math.min(maxMs, baseMs * 2 ** attempt) * (0.75 + Math.random() * 0.5);
      onRetry?.(err, attempt + 1, wait);
      await sleep(wait);
    }
  }
}

export class SimRevert extends Error {
  constructor(kind, decoded) {
    super(`simulation reverted: ${describeError(decoded, kind)}`);
    this.decoded = decoded;
    this.description = describeError(decoded, kind);
  }
}

const transport = (url) => http(url, { retryCount: 3, retryDelay: 1000, timeout: 60_000 });

/// io for the runner. `cfg` from config.mjs. `onRetry(err, attempt, waitMs)` for logging and metrics.
export function createIo(cfg, { onRetry } = {}) {
  const chain = { ...mainnet, id: cfg.chainId };
  const client = createPublicClient({ chain, transport: transport(cfg.rpcUrl) });
  const privateClient = cfg.privateRpcUrl ? createPublicClient({ chain, transport: transport(cfg.privateRpcUrl) }) : null;
  const account = cfg.account;
  const R = (fn) => withRetry(fn, { onRetry });
  const layerStatic = new Map(); // keeper address -> { weth, controller }

  const io = {
    client,
    address: account.address,
    now: () => Math.floor(Date.now() / 1000),
    chainId: () => R(() => client.getChainId()),
    getBlock: () => R(() => client.getBlock({ blockTag: 'latest' })),
    priorityEstimate: () => R(() => client.estimateMaxPriorityFeePerGas()).catch(() => 1_000_000_000n),
    getBalance: () => R(() => client.getBalance({ address: account.address })),
    getNonce: (blockTag = 'latest') => R(() => client.getTransactionCount({ address: account.address, blockTag })),
    getReceipt: (hash) => R(() => client.getTransactionReceipt({ hash })).catch((e) => {
      if (e?.name === 'TransactionReceiptNotFoundError') return null;
      throw e;
    }),
    getCode: (address) => R(() => client.getCode({ address })),

    /// preview of one keeper, as named fields. LAYER adds the controller's weth balance (combined rule)
    async read(k) {
      if (k.kind === '111') {
        const [uncollectedEth, uncollectedCoin, escrowedEth, swapperEth, swapperCoin] = await R(() =>
          client.readContract({ address: k.address, abi: keeper111Abi, functionName: 'preview' }));
        return { uncollectedEth, uncollectedCoin, escrowedEth, swapperEth, swapperCoin };
      }
      if (k.kind === 'layer') {
        if (!layerStatic.has(k.address)) {
          const [weth, controller] = await Promise.all(['weth', 'controller'].map((fn) =>
            R(() => client.readContract({ address: k.address, abi: keeperLayerAbi, functionName: fn }))));
          layerStatic.set(k.address, { weth, controller });
        }
        const { weth, controller } = layerStatic.get(k.address);
        const [[uncollectedLayer, uncollectedWeth, claimable, routerWeth, routerThreshold], controllerWeth] = await Promise.all([
          R(() => client.readContract({ address: k.address, abi: keeperLayerAbi, functionName: 'preview' })),
          R(() => client.readContract({ address: weth, abi: erc20Abi, functionName: 'balanceOf', args: [controller] })),
        ]);
        return { uncollectedLayer, uncollectedWeth, claimable: [...claimable], routerWeth: [...routerWeth], routerThreshold: [...routerThreshold], controllerWeth };
      }
      const [swappers, accruedPaired, accruedArtCoin, nextConvertibleBlock] = await R(() =>
        client.readContract({ address: k.address, abi: keeperV2Abi, functionName: 'preview', args: [k.token] }));
      return { swappers, accruedPaired, accruedArtCoin, nextConvertibleBlock };
    },

    /// simulates the run with minOut / rate 0 at the fixed gas limit. 111 and LAYER: `simulateContract`
    /// (return values). v2 returns nothing, so its convert outputs come from the `SwapperServiced` logs of an
    /// `eth_simulateV1` call; `null` when the rpc does not support it (the runner then skips convert).
    async simulateZero(k) {
      const abi = abiFor(k.kind);
      if (k.kind !== 'v2') {
        const fn = 'run';
        const args = k.kind === '111' ? [true, 0n] : [true, 0n, false];
        try {
          const { result } = await R(() => client.simulateContract({ account, address: k.address, abi, functionName: fn, args, gas: k.gas }));
          return result;
        } catch (err) {
          if (isTransient(err)) throw err;
          throw new SimRevert(k.kind, decodeReason(revertDataOf(err), k.kind));
        }
      }
      const data = encodeFunctionData({ abi, functionName: 'collectAndForward', args: [k.token, true, 0n] });
      let res;
      try {
        res = await R(() => client.simulateCalls({ account: account.address, calls: [{ to: k.address, data, gas: k.gas }] }));
      } catch (err) {
        if (isTransient(err)) throw err;
        // method not supported (or the node refused the shape): fall back to a plain eth_call for the revert
        // check and report no quote
        try {
          await R(() => client.call({ account: account.address, to: k.address, data, gas: k.gas }));
        } catch (e2) {
          if (isTransient(e2)) throw e2;
          throw new SimRevert(k.kind, decodeReason(revertDataOf(e2), k.kind));
        }
        return null;
      }
      const r = res.results[0];
      if (r.status !== 'success') throw new SimRevert(k.kind, decodeReason(r.data ?? revertDataOf(r.error), k.kind));
      return servicedFrom(decodeKeeperLogs(r.logs || [], 'v2', k.address));
    },

    /// signs locally and sends the raw tx (private relay for the keepers in PRIVATE_RPC_KEEPERS). Resending
    /// the same signed bytes is idempotent, so transient send errors are retried safely.
    async send(k, functionName, args, fees) {
      const data = encodeFunctionData({ abi: abiFor(k.kind), functionName, args });
      const nonce = await io.getNonce('pending');
      const serialized = await account.signTransaction({
        chainId: cfg.chainId, type: 'eip1559', to: k.address, data, value: 0n, nonce, gas: k.gas,
        maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
      });
      const hash = keccak256(serialized);
      const via = privateClient && cfg.privateKeepers.has(k.kind) ? privateClient : client;
      try {
        await R(() => via.sendRawTransaction({ serializedTransaction: serialized }));
      } catch (err) {
        const m = String(err.details || err.shortMessage || err.message).toLowerCase();
        if (!/already known|already imported/.test(m)) throw err;
      }
      return { hash, nonce, private: via === privateClient };
    },

    /// null on timeout (tx still in flight)
    async waitReceipt(hash, timeoutMs) {
      try {
        return await client.waitForTransactionReceipt({ hash, timeout: timeoutMs, pollingInterval: 4_000, retryCount: 10 });
      } catch (err) {
        if (err?.name === 'WaitForTransactionReceiptTimeoutError') return null;
        throw err;
      }
    },

    /// replays a reverted tx on the parent block state for its revert reason (best effort: state at the parent
    /// block is not the exact pre tx state when other txs in the block came first)
    async replayRevert(k, functionName, args, blockNumber) {
      const data = encodeFunctionData({ abi: abiFor(k.kind), functionName, args });
      try {
        await client.call({ account: account.address, to: k.address, data, gas: k.gas, blockNumber: blockNumber - 1n });
        return { name: null, note: 'replay at the parent block succeeded (state changed inside the block)' };
      } catch (err) {
        return decodeReason(revertDataOf(err), k.kind);
      }
    },
  };
  return io;
}

export const runCall = (k, args) => (k.kind === 'v2' ? ['collectAndForward', args] : ['run', args]);
