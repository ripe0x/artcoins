// Token discovery from the launch events of every factory in play: the current (v1) factory and the legacy
// factory (LAYER) from the registry, and the v2 factory when one is configured. Scans start at the registry deploy block, never
// block 0, and shrink the range on rpc errors instead of walking 2000 block pages (UI-12).
import { getAbiItem, type Address, type Hex, type PublicClient } from 'viem';
import { factoryV1Abi } from './abi/v1/factory';
import { factoryV2Abi } from './abi/v2/factory';
import { STACKS } from './deployments.generated';
import { getV2Stack } from './v2';
import { cleanText, MAX_NAME, MAX_SYMBOL, MAX_DESCRIPTION, lookalikeKey } from './security';
import type { DeploymentConfigV2 } from './encodeV2';

const tokenCreatedV1 = getAbiItem({ abi: factoryV1Abi, name: 'TokenCreated' });
const tokenCreatedV2 = getAbiItem({ abi: factoryV2Abi, name: 'TokenCreatedV2' });

export interface TokenRecord {
  version: 1 | 2;
  /** the registry factory whose log announced this token. The only trust signal the list carries */
  factory: Address;
  /** announced by the frozen legacy factory (its hook has no skim config, its pool may pair with weth) */
  legacy: boolean;
  token: Address;
  admin: Address;
  sender: Address;
  name: string;
  symbol: string;
  image: string;
  metadata: string;
  context: string;
  poolId: Hex;
  hook: Address;
  locker: Address;
  mevModule: Address;
  tickSpacing: number | null;
  startingTick: number | null;
  extensionsSupply: bigint;
  blockNumber: bigint;
  transactionHash: Hex;
  /** v2 only: the full launch config from the event */
  config?: DeploymentConfigV2;
  /** another token in the list has the same normalised name or symbol */
  lookalike: boolean;
}

export interface FactorySource {
  version: 1 | 2;
  factory: Address;
  fromBlock: bigint;
  /** the registry's legacy stack: same TokenCreated event as the current factory, older hook and locker */
  legacy?: boolean;
}

/** The factories to scan on a chain: the current stack, the legacy stack (LAYER), plus v2 when configured.
 *  The legacy factory emits the same TokenCreated event as the current one, so it is scanned as a v1 source.
 *  The open stack launched no coin and is not scanned. */
export function factorySources(chainId: number): FactorySource[] {
  if (chainId !== 1) return [];
  const out: FactorySource[] = [
    { version: 1, factory: STACKS.current.factory, fromBlock: STACKS.current.deployBlock },
    { version: 1, factory: STACKS.legacy.factory, fromBlock: STACKS.legacy.deployBlock, legacy: true },
  ];
  const v2 = getV2Stack(chainId);
  if (v2) out.push({ version: 2, factory: v2.factory, fromBlock: v2.deployBlock });
  return out;
}

const MIN_SPAN = 2_000n;

/** getLogs over [from, to], halving the range when the rpc refuses it. Starts with the whole range. */
async function getLogsAdaptive<T>(fetch: (from: bigint, to: bigint) => Promise<T[]>, from: bigint, to: bigint): Promise<T[]> {
  try {
    return await fetch(from, to);
  } catch (e) {
    if (to - from + 1n <= MIN_SPAN) throw e;
    const mid = from + (to - from) / 2n;
    const left = await getLogsAdaptive(fetch, from, mid);
    const right = await getLogsAdaptive(fetch, mid + 1n, to);
    return [...left, ...right];
  }
}

async function scanV1(client: PublicClient, src: FactorySource, head: bigint): Promise<TokenRecord[]> {
  const logs = await getLogsAdaptive(
    (from, to) => client.getLogs({ address: src.factory, event: tokenCreatedV1, fromBlock: from, toBlock: to }),
    src.fromBlock,
    head
  );
  const out: TokenRecord[] = [];
  for (const log of logs) {
    const a = log.args;
    if (!a.tokenAddress || !a.tokenAdmin || !a.poolHook || !a.poolId || !a.locker || !a.mevModule || !a.msgSender) continue;
    out.push({
      version: 1,
      factory: src.factory,
      legacy: !!src.legacy,
      token: a.tokenAddress,
      admin: a.tokenAdmin,
      sender: a.msgSender,
      name: cleanText(a.tokenName, MAX_NAME),
      symbol: cleanText(a.tokenSymbol, MAX_SYMBOL),
      image: a.tokenImage ?? '',
      metadata: cleanText(a.tokenMetadata, MAX_DESCRIPTION),
      context: cleanText(a.tokenContext, MAX_DESCRIPTION),
      poolId: a.poolId,
      hook: a.poolHook,
      locker: a.locker,
      mevModule: a.mevModule,
      tickSpacing: null,
      startingTick: a.startingTick ?? null,
      extensionsSupply: a.extensionsSupply ?? 0n,
      blockNumber: log.blockNumber,
      transactionHash: log.transactionHash,
      lookalike: false,
    });
  }
  return out;
}

async function scanV2(client: PublicClient, src: FactorySource, head: bigint): Promise<TokenRecord[]> {
  const logs = await getLogsAdaptive(
    (from, to) => client.getLogs({ address: src.factory, event: tokenCreatedV2, fromBlock: from, toBlock: to }),
    src.fromBlock,
    head
  );
  const out: TokenRecord[] = [];
  for (const log of logs) {
    const a = log.args;
    if (!a.token || !a.poolId || !a.config || !a.sender) continue;
    const c = a.config as unknown as DeploymentConfigV2;
    out.push({
      version: 2,
      factory: src.factory,
      legacy: false,
      token: a.token,
      admin: c.token.tokenAdmin,
      sender: a.sender,
      name: cleanText(c.token.name, MAX_NAME),
      symbol: cleanText(c.token.symbol, MAX_SYMBOL),
      image: c.token.image,
      metadata: cleanText(c.token.metadata, MAX_DESCRIPTION),
      context: cleanText(c.token.context, MAX_DESCRIPTION),
      poolId: a.poolId,
      hook: c.pool.hook,
      locker: c.locker.locker,
      mevModule: c.mev.module,
      tickSpacing: c.pool.tickSpacing,
      startingTick: c.pool.tickIfToken0IsArtCoin,
      extensionsSupply: a.extensionsSupply ?? 0n,
      blockNumber: log.blockNumber,
      transactionHash: log.transactionHash,
      config: c,
      lookalike: false,
    });
  }
  return out;
}

/** Marks tokens whose normalised name or symbol also appears on another token. */
export function flagLookalikes(records: TokenRecord[]): TokenRecord[] {
  const names = new Map<string, number>();
  const symbols = new Map<string, number>();
  for (const r of records) {
    const n = lookalikeKey(r.name);
    const s = lookalikeKey(r.symbol);
    if (n) names.set(n, (names.get(n) ?? 0) + 1);
    if (s) symbols.set(s, (symbols.get(s) ?? 0) + 1);
  }
  return records.map((r) => ({
    ...r,
    lookalike: (names.get(lookalikeKey(r.name)) ?? 0) > 1 || (symbols.get(lookalikeKey(r.symbol)) ?? 0) > 1,
  }));
}

/** All tokens from every configured factory, newest first. */
export async function fetchAllTokens(client: PublicClient, chainId: number): Promise<TokenRecord[]> {
  const sources = factorySources(chainId);
  if (sources.length === 0) return [];
  const head = await client.getBlockNumber();
  const batches = await Promise.all(
    sources.map((s) => (s.version === 1 ? scanV1(client, s, head) : scanV2(client, s, head)))
  );
  const all = batches.flat();
  all.sort((a, b) => (a.blockNumber === b.blockNumber ? 0 : a.blockNumber < b.blockNumber ? 1 : -1));
  return flagLookalikes(all);
}
