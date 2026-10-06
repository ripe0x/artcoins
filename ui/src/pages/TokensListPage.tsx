import TokenCard from '../components/TokenCard';
import { useTokens } from '../lib/useTokens';

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
  const { data, isLoading, error, refetch, isFetching, supported } = useTokens();

  return (
    <main className="mx-auto max-w-5xl px-4 py-8">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold">All Tokens</h1>
          <p className="text-zinc-500 mt-1">
            Tokens launched through the artcoins factories listed in the deployment registry, most recent first.
            Names, symbols and images are chosen by each token's creator. Check the contract address before you trade.
          </p>
        </div>
        <button
          type="button"
          onClick={() => refetch()}
          disabled={isFetching || !supported}
          className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-sm text-zinc-300 hover:text-white hover:border-zinc-600 disabled:opacity-50"
        >
          {isFetching ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>

      {!supported && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-10 text-center">
          <p className="text-zinc-400">No artcoins deployment is configured for this network.</p>
          <p className="text-sm text-zinc-600 mt-2">Switch to Ethereum mainnet.</p>
        </div>
      )}

      {supported && isLoading && <LoadingSkeleton />}

      {supported && error && (
        <div className="rounded-xl border border-red-900 bg-red-950/30 p-6">
          <p className="text-red-400 font-medium">Failed to load tokens</p>
          <p className="text-sm text-red-300/70 mt-1">{(error as Error).message.split('\n')[0]}</p>
          <button type="button" onClick={() => refetch()} className="mt-3 text-sm text-red-300 hover:text-red-200 underline">
            Retry
          </button>
        </div>
      )}

      {supported && data && data.length === 0 && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-10 text-center">
          <p className="text-zinc-400">No tokens launched yet.</p>
        </div>
      )}

      {supported && data && data.length > 0 && (
        <>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {data.map((ev) => (
              <TokenCard key={ev.token} event={ev} />
            ))}
          </div>
          <p className="mt-6 text-xs text-zinc-600 text-center">
            {data.length} token{data.length === 1 ? '' : 's'} total
          </p>
        </>
      )}
    </main>
  );
}
