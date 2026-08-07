import type { Address, PublicClient } from 'viem';
import { parseAbiItem } from 'viem';

export interface TokenCreatedEvent {
  tokenAddress: Address;
  tokenAdmin: Address;
  msgSender: Address;
  tokenImage: string;
  tokenName: string;
  tokenSymbol: string;
  tokenMetadata: string;
  tokenContext: string;
  startingTick: number;
  poolHook: Address;
  poolId: `0x${string}`;
  pairedToken: Address;
  locker: Address;
  mevModule: Address;
  extensionsSupply: bigint;
  extensions: readonly Address[];
  blockNumber: bigint;
  transactionHash: `0x${string}`;
}

// Reconstruct the event from the human-readable signature so viem can decode args.
const tokenCreatedEvent = parseAbiItem(
  'event TokenCreated(address msgSender, address indexed tokenAddress, address indexed tokenAdmin, string tokenImage, string tokenName, string tokenSymbol, string tokenMetadata, string tokenContext, int24 startingTick, address poolHook, bytes32 poolId, address pairedToken, address locker, address mevModule, uint256 extensionsSupply, address[] extensions)'
);

// Public RPCs (e.g. thirdweb's free tier) cap getLogs at ~1000 blocks per
// call; Alchemy allows more, but 1000 is the conservative value that works
// everywhere, including the public-RPC fallback path.
const BATCH_SIZE = 1_000n;

// ── Raw-log parsing ──────────────────────────────────────────────────────

interface RawTokenCreatedLog {
  args?: Record<string, unknown>;
  blockNumber: bigint | null;
  transactionHash: `0x${string}` | null;
}

/**
 * Decode raw getLogs() results into TokenCreatedEvent objects, dropping any
 * log that's missing a required field (defensive against partially-indexed
 * RPC responses).
 */
function parseTokenCreatedLogs(logs: readonly RawTokenCreatedLog[]): TokenCreatedEvent[] {
  const out: TokenCreatedEvent[] = [];
  for (const log of logs) {
    const a = log.args;
    if (
      !a ||
      !a.tokenAddress ||
      !a.tokenAdmin ||
      !a.msgSender ||
      !a.poolHook ||
      !a.pairedToken ||
      !a.locker ||
      !a.mevModule ||
      !a.poolId ||
      a.startingTick === undefined ||
      a.extensionsSupply === undefined ||
      !a.extensions
    ) {
      continue;
    }
    out.push({
      tokenAddress: a.tokenAddress as Address,
      tokenAdmin: a.tokenAdmin as Address,
      msgSender: a.msgSender as Address,
      tokenImage: (a.tokenImage as string | undefined) ?? '',
      tokenName: (a.tokenName as string | undefined) ?? '',
      tokenSymbol: (a.tokenSymbol as string | undefined) ?? '',
      tokenMetadata: (a.tokenMetadata as string | undefined) ?? '',
      tokenContext: (a.tokenContext as string | undefined) ?? '',
      startingTick: a.startingTick as number,
      poolHook: a.poolHook as Address,
      poolId: a.poolId as `0x${string}`,
      pairedToken: a.pairedToken as Address,
      locker: a.locker as Address,
      mevModule: a.mevModule as Address,
      extensionsSupply: a.extensionsSupply as bigint,
      extensions: a.extensions as readonly Address[],
      blockNumber: log.blockNumber as bigint,
      transactionHash: log.transactionHash as `0x${string}`,
    });
  }
  return out;
}

function dedupeEvents(events: readonly TokenCreatedEvent[]): TokenCreatedEvent[] {
  const map = new Map<string, TokenCreatedEvent>();
  for (const e of events) {
    map.set(`${e.transactionHash}-${e.tokenAddress.toLowerCase()}`, e);
  }
  return Array.from(map.values());
}

/** Newest first. Uses bigint comparisons directly to avoid precision loss. */
function sortNewestFirst(events: readonly TokenCreatedEvent[]): TokenCreatedEvent[] {
  return [...events].sort((a, b) => {
    if (b.blockNumber === a.blockNumber) return 0;
    return b.blockNumber > a.blockNumber ? 1 : -1;
  });
}

// ── Persistent cache (localStorage) ─────────────────────────────────────
//
// TokenCreated events are immutable history, so once a block range has been
// scanned it never needs to be scanned again. We persist the scanned events
// plus how far we've scanned, per chain, and only scan the delta on
// subsequent loads.

const CACHE_VERSION = 1;

interface SerializedTokenEvent extends Omit<TokenCreatedEvent, 'blockNumber' | 'extensionsSupply'> {
  blockNumber: string;
  extensionsSupply: string;
}

interface TokenEventCache {
  version: number;
  factory: string;
  lastScannedBlock: string;
  events: SerializedTokenEvent[];
}

function cacheKey(chainId: number): string {
  return `artcoins:tokenEvents:v1:${chainId}`;
}

function serializeEvent(e: TokenCreatedEvent): SerializedTokenEvent {
  return {
    ...e,
    blockNumber: e.blockNumber.toString(),
    extensionsSupply: e.extensionsSupply.toString(),
  };
}

function isSerializedTokenEvent(v: unknown): v is SerializedTokenEvent {
  if (!v || typeof v !== 'object') return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.tokenAddress === 'string' &&
    typeof o.tokenAdmin === 'string' &&
    typeof o.msgSender === 'string' &&
    typeof o.tokenImage === 'string' &&
    typeof o.tokenName === 'string' &&
    typeof o.tokenSymbol === 'string' &&
    typeof o.tokenMetadata === 'string' &&
    typeof o.tokenContext === 'string' &&
    typeof o.startingTick === 'number' &&
    typeof o.poolHook === 'string' &&
    typeof o.poolId === 'string' &&
    typeof o.pairedToken === 'string' &&
    typeof o.locker === 'string' &&
    typeof o.mevModule === 'string' &&
    typeof o.extensionsSupply === 'string' &&
    Array.isArray(o.extensions) &&
    typeof o.blockNumber === 'string' &&
    typeof o.transactionHash === 'string'
  );
}

/** Returns null on any malformed field — never throws. */
function deserializeEvent(e: SerializedTokenEvent): TokenCreatedEvent | null {
  try {
    return {
      ...e,
      blockNumber: BigInt(e.blockNumber),
      extensionsSupply: BigInt(e.extensionsSupply),
    };
  } catch {
    return null;
  }
}

/**
 * Reads the persisted cache for a chain/factory pair. Returns null on any
 * failure (storage unavailable, corrupt JSON, version mismatch, factory
 * mismatch) so the caller can transparently fall back to a full rescan from
 * the deployment block. Never throws.
 */
function readCache(
  chainId: number,
  factory: Address
): { lastScannedBlock: bigint; events: TokenCreatedEvent[] } | null {
  try {
    if (typeof localStorage === 'undefined') return null;
    const raw = localStorage.getItem(cacheKey(chainId));
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<TokenEventCache> | null;
    if (
      !parsed ||
      parsed.version !== CACHE_VERSION ||
      typeof parsed.lastScannedBlock !== 'string' ||
      typeof parsed.factory !== 'string' ||
      parsed.factory.toLowerCase() !== factory.toLowerCase() ||
      !Array.isArray(parsed.events)
    ) {
      return null;
    }
    const lastScannedBlock = BigInt(parsed.lastScannedBlock);
    const events: TokenCreatedEvent[] = [];
    for (const rawEvent of parsed.events) {
      if (!isSerializedTokenEvent(rawEvent)) continue;
      const ev = deserializeEvent(rawEvent);
      if (ev) events.push(ev);
    }
    return { lastScannedBlock, events };
  } catch {
    // Corrupt JSON, BigInt() throwing on a garbage string, storage denied
    // (private browsing), etc. — discard and let the caller rescan.
    return null;
  }
}

/** Best-effort persist. Never throws — storage failures degrade to no-cache. */
function writeCache(
  chainId: number,
  factory: Address,
  lastScannedBlock: bigint,
  events: readonly TokenCreatedEvent[]
): void {
  try {
    if (typeof localStorage === 'undefined') return;
    const payload: TokenEventCache = {
      version: CACHE_VERSION,
      factory,
      lastScannedBlock: lastScannedBlock.toString(),
      events: events.map(serializeEvent),
    };
    localStorage.setItem(cacheKey(chainId), JSON.stringify(payload));
  } catch {
    // Quota exceeded, storage disabled, private browsing, etc. — degrade
    // gracefully to the no-cache behavior (rescans next time).
  }
}

/**
 * Fetches all TokenCreated events ever emitted by the factory, newest first.
 * Batched to respect public RPC getLogs block-range limits, and backed by a
 * per-chain localStorage cache so only the blocks since the last successful
 * scan are re-fetched. Progress is persisted after each batch so an
 * interrupted/retried scan resumes instead of restarting from the
 * deployment block.
 */
export async function fetchAllTokenCreatedEvents(
  client: PublicClient,
  factory: Address,
  fromBlock: bigint,
  chainId: number
): Promise<TokenCreatedEvent[]> {
  const head = await client.getBlockNumber();

  const cached = readCache(chainId, factory);
  let events: TokenCreatedEvent[] = cached ? dedupeEvents(cached.events) : [];
  let lastScannedBlock = cached ? cached.lastScannedBlock : fromBlock - 1n;
  const resumeFrom = lastScannedBlock + 1n;
  let start = resumeFrom > fromBlock ? resumeFrom : fromBlock;

  for (; start <= head; start += BATCH_SIZE) {
    const end = start + BATCH_SIZE - 1n > head ? head : start + BATCH_SIZE - 1n;
    let logs;
    try {
      logs = await client.getLogs({
        address: factory,
        event: tokenCreatedEvent,
        fromBlock: start,
        toBlock: end,
      });
    } catch (err) {
      // Preserve everything scanned so far. react-query's default retry (or
      // a manual refetch) resumes from `lastScannedBlock + 1` instead of
      // rescanning from the deployment block.
      writeCache(chainId, factory, lastScannedBlock, events);
      throw err;
    }
    events = dedupeEvents([...events, ...parseTokenCreatedLogs(logs)]);
    lastScannedBlock = end;
    writeCache(chainId, factory, lastScannedBlock, events);
  }

  return sortNewestFirst(events);
}

/**
 * Fetches the TokenCreated event for a single token, using the indexed
 * `tokenAddress` topic so we don't need to scan/decode unrelated tokens.
 * Tries one wide query first; some RPCs reject wide block ranges even when
 * topic-filtered, so on failure this falls back to a batched scan (still
 * topic-filtered, so each request stays cheap). Never throws — returns
 * undefined if the event can't be found or every attempt fails.
 */
export async function fetchTokenCreatedEvent(
  client: PublicClient,
  factory: Address,
  fromBlock: bigint,
  tokenAddress: Address
): Promise<TokenCreatedEvent | undefined> {
  try {
    const logs = await client.getLogs({
      address: factory,
      event: tokenCreatedEvent,
      args: { tokenAddress },
      fromBlock,
      toBlock: 'latest',
    });
    const parsed = parseTokenCreatedLogs(logs);
    if (parsed.length > 0) return parsed[0];
    return undefined;
  } catch {
    // Wide-range topic-filtered query rejected — fall through to batched scan.
  }

  try {
    const head = await client.getBlockNumber();
    for (let start = fromBlock; start <= head; start += BATCH_SIZE) {
      const end = start + BATCH_SIZE - 1n > head ? head : start + BATCH_SIZE - 1n;
      try {
        const logs = await client.getLogs({
          address: factory,
          event: tokenCreatedEvent,
          args: { tokenAddress },
          fromBlock: start,
          toBlock: end,
        });
        const parsed = parseTokenCreatedLogs(logs);
        if (parsed.length > 0) return parsed[0];
      } catch {
        // Skip this batch and keep going — best-effort single-token lookup.
        continue;
      }
    }
  } catch {
    // getBlockNumber() itself failed — nothing more we can do.
  }
  return undefined;
}
