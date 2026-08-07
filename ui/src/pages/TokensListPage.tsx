import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useChainId, usePublicClient } from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import { PAGE_WIDTH_WIDE } from '../components/Layout';
import TokenCard from '../components/TokenCard';
import { fetchAllTokenCreatedEvents } from '../lib/events';
import { getAddresses, getFactoryDeploymentBlock } from '../lib/config';

/** Cheap ceiling on initial render — the full list can only grow over time
 *  as more tokens are deployed, and there's no pagination in the underlying
 *  query, so cap the rendered cards up front and let "Show all" opt in. */
const INITIAL_VISIBLE = 120;

function LoadingSkeleton() {
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      {Array.from({ length: 6 }).map((_, i) => (
        <div key={i} className="rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
          <div className="aspect-square bg-zinc-800 animate-pulse" />
          <div className="p-4 space-y-2">
            <div className="h-4 bg-zinc-800 rounded animate-pulse" />
            <div className="h-3 w-1/2 bg-zinc-800 rounded animate-pulse" />
          </div>
        </div>
      ))}
    </div>
  );
}

export default function TokensListPage() {
  const chainId = useChainId();
  const client = usePublicClient();
  const addresses = getAddresses(chainId);
  const [showAll, setShowAll] = useState(false);

  const factoryDeployed = addresses.factory !== '0x0000000000000000000000000000000000000000';

  const { data, isLoading, error, refetch, isFetching } = useQuery({
    queryKey: ['tokens', chainId],
    queryFn: async () => {
      if (!client) throw new Error('No public client');
      return fetchAllTokenCreatedEvents(
        client,
        addresses.factory,
        getFactoryDeploymentBlock(chainId),
        chainId
      );
    },
    enabled: !!client && factoryDeployed,
    staleTime: 60_000,
    gcTime: 5 * 60_000,
  });

  return (
    <div className={`${PAGE_WIDTH_WIDE} py-8`}>
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold">All Tokens</h1>
          <p className="text-zinc-500 mt-1">
            Every token ever deployed through the factory, most recent first.
          </p>
        </div>
        <button
          type="button"
          onClick={() => refetch()}
          disabled={isFetching}
          className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-sm text-zinc-300 hover:text-white hover:border-zinc-600 disabled:opacity-50"
        >
          {isFetching ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>

      {!factoryDeployed && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-10 text-center">
          <p className="text-zinc-400">
            The factory isn't configured for this chain.
          </p>
          <p className="text-sm text-zinc-600 mt-2">
            Switch to Ethereum Mainnet or Sepolia to see deployed tokens.
          </p>
        </div>
      )}

      {factoryDeployed && isLoading && <LoadingSkeleton />}

      {factoryDeployed && error && (
        <div className="rounded-xl border border-red-900 bg-red-950/30 p-6">
          <p className="text-red-400 font-medium">Failed to load tokens</p>
          <p className="text-sm text-red-300/70 mt-1">
            {(error as Error).message}
          </p>
          <button
            type="button"
            onClick={() => refetch()}
            className="mt-3 text-sm text-red-300 hover:text-red-200 underline"
          >
            Retry
          </button>
        </div>
      )}

      {factoryDeployed && data && data.length === 0 && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-10 text-center">
          <p className="text-zinc-400">No tokens deployed yet.</p>
          <p className="text-sm text-zinc-600 mt-2">
            Be the first — <Link to="/" className="text-violet-400 hover:text-violet-300 underline">head to the deploy page</Link> to launch one.
          </p>
        </div>
      )}

      {factoryDeployed && data && data.length > 0 && (
        <>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {(showAll ? data : data.slice(0, INITIAL_VISIBLE)).map(ev => (
              <TokenCard key={ev.tokenAddress} event={ev} />
            ))}
          </div>
          <p className="mt-6 text-xs text-zinc-600 text-center">
            {showAll
              ? `${data.length} token${data.length === 1 ? '' : 's'} total`
              : `Showing ${Math.min(INITIAL_VISIBLE, data.length)} of ${data.length} tokens`}
          </p>
          {!showAll && data.length > INITIAL_VISIBLE && (
            <div className="mt-3 text-center">
              <button
                type="button"
                onClick={() => setShowAll(true)}
                className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-1.5 text-sm text-zinc-300 hover:text-white hover:border-zinc-600"
              >
                Show all
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
