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

// Alchemy supports ~2k blocks per getLogs call. Public RPCs (thirdweb) cap at 1000.
// Use a conservative default that works everywhere.
const BATCH_SIZE = 2_000n;

/**
 * Fetches all TokenCreated events ever emitted by the factory, newest first.
 * Batched to respect public RPC getLogs block-range limits.
 */
export async function fetchAllTokenCreatedEvents(
  client: PublicClient,
  factory: Address,
  fromBlock: bigint
): Promise<TokenCreatedEvent[]> {
  const head = await client.getBlockNumber();
  const results: TokenCreatedEvent[] = [];

  for (let start = fromBlock; start <= head; start += BATCH_SIZE) {
    const end = start + BATCH_SIZE - 1n > head ? head : start + BATCH_SIZE - 1n;
    const logs = await client.getLogs({
      address: factory,
      event: tokenCreatedEvent,
      fromBlock: start,
      toBlock: end,
    });
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
      results.push({
        tokenAddress: a.tokenAddress,
        tokenAdmin: a.tokenAdmin,
        msgSender: a.msgSender,
        tokenImage: a.tokenImage ?? '',
        tokenName: a.tokenName ?? '',
        tokenSymbol: a.tokenSymbol ?? '',
        tokenMetadata: a.tokenMetadata ?? '',
        tokenContext: a.tokenContext ?? '',
        startingTick: a.startingTick,
        poolHook: a.poolHook,
        poolId: a.poolId,
        pairedToken: a.pairedToken,
        locker: a.locker,
        mevModule: a.mevModule,
        extensionsSupply: a.extensionsSupply,
        extensions: a.extensions,
        blockNumber: log.blockNumber!,
        transactionHash: log.transactionHash!,
      });
    }
  }

  // Most recent first
  results.sort((a, b) => {
    if (b.blockNumber === a.blockNumber) return 0;
    return b.blockNumber > a.blockNumber ? 1 : -1;
  });
  return results;
}
