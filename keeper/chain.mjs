// viem plumbing: reads, simulations, signing and sending, receipts. Everything the runner does on chain goes
// through the `io` object built here, so tests can swap it for a fake.
import { createPublicClient, encodeAbiParameters, encodeFunctionData, getAddress, http, keccak256, parseAbi } from 'viem';
import { mainnet } from 'viem/chains';
import { abiFor, erc20Abi, keeper111Abi, keeperLayerAbi, keeperV2Abi } from './abi.mjs';
import { decodeKeeperLogs, decodeReason, describeError, revertDataOf, servicedFrom } from './events.mjs';
import { decodeSlot0 } from './decide.mjs';

export const POOL_MANAGER = '0x000000000004444c5dc75cB358380D2e3dE08A90';
export const CANCEL_GAS = 21_000n;
// type(IFeeAutoSwapperV2).interfaceId: xor of its own selectors (supportsInterface is inherited, not counted)
export const FEE_SWAPPER_V2_INTERFACE_ID = '0x08ce5e71';

const KEY = '(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)';
export const marketAbi = parseAbi([
  'function extsload(bytes32 startSlot, uint256 nSlots) view returns (bytes32[])',
  `function poolKey() view returns (${KEY})`,
  `function canonicalPoolKey() view returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)`,
  'function maxStepIn() view returns (uint256)',
  'function accruedArtCoin() view returns (uint256)',
  'function minLayerOutPerWeth() view returns (uint256)',
  'function supportsInterface(bytes4) view returns (bool)',
  // v1 SkimFee hook (tuple) and v2 hook (struct, same field order and encoding)
  'function skimConfig(bytes32) view returns (uint24 baselineSkimBps, uint16 bountyBps, uint24 maxReferralBpsOfVolume, uint24 lpFee, address bountyRecipient, address protocolRecipient, address referralPayout, address quoteToken)',
  // legacy static fee hook (LAYER): per direction lp fee
  'function artCoinFee(bytes32) view returns (uint24)',
  'function pairedFee(bytes32) view returns (uint24)',
  `function tokenRewards(address) view returns ((address token, ${KEY} poolKey, uint256 positionId, uint256 numPositions, uint16[] rewardBps, address[] rewardAdmins, address[] rewardRecipients))`,
  'function deploymentInfo(address) view returns ((address token, address hook, address locker, address mevModule, bytes32 poolId, uint16 version, uint40 launchedAt, address[] extensions))',
  'function rewardRecipients(address) view returns (address[])',
]);

/// v4 PoolId of a key: keccak256(abi.encode(key))
export function poolIdOf(key) {
  return keccak256(encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }],
    [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
  ));
}

/// storage slot of `pools[id]` in the PoolManager (mapping at slot 6, StateLibrary.POOLS_SLOT). slot0 is at this
/// slot, liquidity 3 slots further (RUNBOOK action 5 recipe)
export function poolStateSlot(id) {
  return keccak256(encodeAbiParameters([{ type: 'bytes32' }, { type: 'uint256' }], [id, 6n]));
}

const asKey = (k) => (Array.isArray(k) ? { currency0: k[0], currency1: k[1], fee: k[2], tickSpacing: k[3], hooks: k[4] } : k);
const SKIM_TO_PPM = 10; // SKIM_DENOMINATOR 100,000 -> ppm

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
  const marketStatic = new Map(); // keeper (and v2 token) -> immutable addresses and pool keys

  /// slot0 (and liquidity) of a v4 pool plus the hook's fees. lp fee: the largest of slot0's and the hook's
  /// answers (a larger fee only lowers the floor). skim: the hook's `skimConfig` baseline, 0 when it has none
  async function readPool(key, { liquidity = false, legacyFees = false } = {}) {
    const id = poolIdOf(key);
    const words = await R(() => client.readContract({ address: POOL_MANAGER, abi: marketAbi, functionName: 'extsload', args: [poolStateSlot(id), liquidity ? 4n : 1n] }));
    const { sqrtPriceX96, lpFee } = decodeSlot0(words[0]);
    let lpFeePpm = lpFee;
    let skimPpm = 0;
    const skim = await R(() => client.readContract({ address: key.hooks, abi: marketAbi, functionName: 'skimConfig', args: [id] })).catch(() => null);
    if (skim) {
      skimPpm = Number(skim[0]) * SKIM_TO_PPM;
      lpFeePpm = Math.max(lpFeePpm, Number(skim[3]));
    }
    if (legacyFees) {
      for (const fn of ['artCoinFee', 'pairedFee']) {
        const f = await R(() => client.readContract({ address: key.hooks, abi: marketAbi, functionName: fn, args: [id] })).catch(() => null);
        if (f !== null) lpFeePpm = Math.max(lpFeePpm, Number(f));
      }
    }
    const out = { poolId: id, sqrtPriceX96, lpFeePpm, skimPpm };
    if (liquidity) out.liquidity = BigInt(words[3]) & ((1n << 128n) - 1n);
    return out;
  }

  async function broadcast({ to, data, gas, nonce, fees }, via, onSigned) {
    const serialized = await account.signTransaction({
      chainId: cfg.chainId, type: 'eip1559', to, data, value: 0n, nonce, gas,
      maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
    });
    const hash = keccak256(serialized);
    await onSigned?.({ hash, nonce });
    try {
      await R(() => via.sendRawTransaction({ serializedTransaction: serialized }));
    } catch (err) {
      const m = String(err.details || err.shortMessage || err.message).toLowerCase();
      if (!/already known|already imported/.test(m)) {
        // after retries a transient error, or a nonce already used, may mean the bytes reached a pool
        err.ambiguous = isTransient(err) || /nonce too low/.test(m);
        throw err;
      }
    }
    return { hash, nonce, private: via === privateClient };
  }

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

    /// pool state for the independent floor (KR-02, KR-03, KR-12): spot from `PoolManager.extsload` of the pool's
    /// slot0, lp fee (slot0, the hook's config, whichever is larger) and the hook's baseline skim. Per kind:
    /// 111 adds the swapper's `maxStepIn` and its locker reward share, LAYER the liquidity, sort order and which
    /// routers have an owner floor, v2 one entry per fee swapper of the coin. Throws on rpc failure (the runner
    /// then sends without convert or burn).
    async market(k) {
      if (k.kind === '111') {
        if (!marketStatic.has(k.address)) {
          const [swapper, locker, token] = await Promise.all(['swapper', 'locker', 'token'].map((fn) =>
            R(() => client.readContract({ address: k.address, abi: keeper111Abi, functionName: fn }))));
          const [key, maxStepIn] = await Promise.all([
            R(() => client.readContract({ address: swapper, abi: marketAbi, functionName: 'poolKey' })),
            R(() => client.readContract({ address: swapper, abi: marketAbi, functionName: 'maxStepIn' })),
          ]);
          marketStatic.set(k.address, { swapper, locker, token, key: asKey(key), maxStepIn }); // v1 maxStepIn is immutable
        }
        const st = marketStatic.get(k.address);
        const pool = await readPool(st.key);
        const rewards = await R(() => client.readContract({ address: st.locker, abi: marketAbi, functionName: 'tokenRewards', args: [st.token] })).catch(() => null);
        let share = 0;
        if (rewards) rewards.rewardRecipients.forEach((r, i) => { if (getAddress(r) === getAddress(st.swapper)) share += Number(rewards.rewardBps[i]); });
        return { ...pool, maxStepIn: st.maxStepIn, swapperShareBps: share, coinIsToken0: getAddress(st.key.currency0) === getAddress(st.token) };
      }
      if (k.kind === 'layer') {
        if (!marketStatic.has(k.address)) {
          const [weth, r0, r1, r2] = await Promise.all(['weth', 'router0', 'router1', 'router2'].map((fn) =>
            R(() => client.readContract({ address: k.address, abi: keeperLayerAbi, functionName: fn }))));
          const key = asKey(await R(() => client.readContract({ address: r0, abi: marketAbi, functionName: 'canonicalPoolKey' })));
          marketStatic.set(k.address, { weth, routers: [r0, r1, r2], key });
        }
        const st = marketStatic.get(k.address);
        const pool = await readPool(st.key, { liquidity: true, legacyFees: true });
        const floors = await Promise.all(st.routers.map((r) =>
          R(() => client.readContract({ address: r, abi: marketAbi, functionName: 'minLayerOutPerWeth' })).catch(() => null)));
        return { ...pool, wethIsToken0: getAddress(st.key.currency0) === getAddress(st.weth), routerFloors: floors };
      }
      // v2: swappers are the locker's reward recipients that answer the IFeeAutoSwapperV2 erc165 probe
      const sk = `${k.address}:${k.token}`;
      if (!marketStatic.has(sk)) {
        const factory = await R(() => client.readContract({ address: k.address, abi: keeperV2Abi, functionName: 'factory' }));
        const info = await R(() => client.readContract({ address: factory, abi: marketAbi, functionName: 'deploymentInfo', args: [k.token] }));
        marketStatic.set(sk, { locker: info.locker });
      }
      const recipients = await R(() => client.readContract({ address: marketStatic.get(sk).locker, abi: marketAbi, functionName: 'rewardRecipients', args: [k.token] }));
      const unique = [...new Set(recipients.map((r) => getAddress(r)))];
      const swappers = [];
      for (const r of unique) {
        const yes = await R(() => client.readContract({ address: r, abi: marketAbi, functionName: 'supportsInterface', args: [FEE_SWAPPER_V2_INTERFACE_ID] })).catch(() => false);
        if (!yes) continue;
        const [accruedArtCoin, maxStepIn, key] = await Promise.all(['accruedArtCoin', 'maxStepIn', 'poolKey'].map((fn) =>
          R(() => client.readContract({ address: r, abi: marketAbi, functionName: fn }))));
        swappers.push({ address: r, accruedArtCoin, maxStepIn, ...(await readPool(asKey(key))) });
      }
      return { swappers };
    },

    /// signs locally and sends the raw tx (private relay for the keepers in PRIVATE_RPC_KEEPERS). `nonce` set means
    /// a same nonce replacement (KR-04); unset signs at the `latest` nonce (the runner refuses to send while the
    /// node's pending nonce is ahead of it). `onSigned({hash, nonce})` runs before the broadcast so the tx is on disk
    /// before it can reach a pool (KR-11). Resending the same signed bytes is idempotent, so transient send errors
    /// are retried safely. A failed broadcast throws with `ambiguous` true when the tx may still have reached a pool.
    async send(k, functionName, args, fees, { nonce, onSigned } = {}) {
      const data = encodeFunctionData({ abi: abiFor(k.kind), functionName, args });
      const n = nonce ?? (await io.getNonce('latest'));
      const via = privateClient && cfg.privateKeepers.has(k.kind) ? privateClient : client;
      return broadcast({ to: k.address, data, gas: k.gas, nonce: n, fees }, via, onSigned);
    },

    /// KR-04: cancels a stuck nonce with a 0 value transfer to self (21,000 gas), same route as the stuck tx
    async cancel(nonce, fees, { private: viaPrivate, onSigned } = {}) {
      const via = viaPrivate && privateClient ? privateClient : client;
      return broadcast({ to: account.address, data: '0x', gas: CANCEL_GAS, nonce, fees }, via, onSigned);
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
