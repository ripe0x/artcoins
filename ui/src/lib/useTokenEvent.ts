import { useMemo } from 'react';
import { useChainId, usePublicClient } from 'wagmi';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import type { Address } from 'viem';

import { getAddresses, getFactoryDeploymentBlock } from './config';
import { fetchTokenCreatedEvent, type TokenCreatedEvent } from './events';
import { buildPoolKey, resolveTickSpacing, type PoolKey } from './pool';

const ZERO: Address = '0x0000000000000000000000000000000000000000';

export interface UseTokenEventResult {
  event: TokenCreatedEvent | undefined;
  /** The on-chain poolId from the event itself — always available once `event` is. */
  poolId: `0x${string}` | undefined;
  /**
   * `undefined` when `resolveTickSpacing` couldn't match any candidate
   * tickSpacing against the event's poolId — in that case there's no
   * trustworthy PoolKey, so callers must pass `poolKey={undefined}` through
   * (e.g. to SwapWidget) rather than substituting a fallback.
   */
  poolKey: PoolKey | undefined;
  tickSpacing: number | undefined;
  isLoading: boolean;
  error: Error | null;
}

/**
 * Resolves a single token's TokenCreated event plus its derived poolKey /
 * tickSpacing. Prefers the already-fetched `['tokens', chainId]` list from
 * react-query's cache (populated by TokensListPage) so navigating from the
 * list to a detail page is instant; only falls back to an indexed-topic
 * single-event fetch when that list isn't in cache.
 */
export function useTokenEvent(address: string | undefined): UseTokenEventResult {
  const chainId = useChainId();
  const client = usePublicClient();
  const queryClient = useQueryClient();
  const addresses = getAddresses(chainId);
  const tokenAddress = (address ?? '').toLowerCase() as Address;

  const factoryDeployed = addresses.factory !== ZERO;

  // Instant path: reuse the full list if TokensListPage (or a previous visit)
  // already populated it.
  const cachedList = queryClient.getQueryData<TokenCreatedEvent[]>(['tokens', chainId]);
  const cachedEvent = useMemo(
    () => cachedList?.find(e => e.tokenAddress.toLowerCase() === tokenAddress),
    [cachedList, tokenAddress]
  );

  const {
    data: fetchedEvent,
    isLoading: fetchLoading,
    error,
  } = useQuery({
    queryKey: ['tokenEvent', chainId, tokenAddress],
    queryFn: async () => {
      if (!client) throw new Error('No public client');
      return fetchTokenCreatedEvent(
        client,
        addresses.factory,
        getFactoryDeploymentBlock(chainId),
        tokenAddress
      );
    },
    enabled: !!client && factoryDeployed && !cachedEvent && tokenAddress.length === 42,
    staleTime: 60_000,
  });

  const event = cachedEvent ?? fetchedEvent ?? undefined;

  const { tickSpacing, poolKey } = useMemo(() => {
    if (!event) return { tickSpacing: undefined, poolKey: undefined };
    const ts = resolveTickSpacing(event.tokenAddress, event.pairedToken, event.poolHook, event.poolId);
    if (ts === null) return { tickSpacing: undefined, poolKey: undefined };
    return {
      tickSpacing: ts,
      poolKey: buildPoolKey(event.tokenAddress, event.pairedToken, ts, event.poolHook),
    };
  }, [event]);

  return {
    event,
    poolId: event?.poolId,
    poolKey,
    tickSpacing,
    isLoading: cachedEvent ? false : fetchLoading,
    error: (error as Error | null) ?? null,
  };
}
