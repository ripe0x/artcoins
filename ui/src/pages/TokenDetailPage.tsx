import { useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useChainId, usePublicClient, useReadContracts } from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import type { Address } from 'viem';

import InfoCard from '../components/InfoCard';
import InfoRow from '../components/InfoRow';
import CopyableAddress from '../components/CopyableAddress';
import SwapWidget from '../components/SwapWidget';
import TokenMetadataModal from '../components/TokenMetadataModal';
import {
  getAddresses,
  getFactoryDeploymentBlock,
  uniswapTokenUrl,
  uniswapSwapUrl,
} from '../lib/config';
import {
  tokenAbi,
  hookBaseAbi,
  staticHookAbi,
  mevLinearAbi,
  lockerAbi,
  stateViewAbi,
} from '../lib/abi';
import { fetchAllTokenCreatedEvents, type TokenCreatedEvent } from '../lib/events';
import { resolveImage, parseContractURI } from '../lib/metadata';
import {
  buildPoolKey,
  resolveTickSpacing,
  newMaterialPriceInPaired,
} from '../lib/pool';
import {
  shortAddr,
  formatSupply,
  formatFeeBps,
  formatDuration,
  formatTimestamp,
  formatPrice,
} from '../lib/format';

function explorerUrl(chainId: number, addr: string): string {
  const base = chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';
  return `${base}/address/${addr}`;
}

function pairedTokenLabel(address: string, weth: string): string {
  if (address.toLowerCase() === weth.toLowerCase()) return 'WETH';
  return shortAddr(address);
}

function CardSkeleton({ height = 'h-40' }: { height?: string }) {
  return <div className={`rounded-xl bg-zinc-900 border border-zinc-800 animate-pulse ${height}`} />;
}

export default function TokenDetailPage() {
  const { address: tokenAddressParam } = useParams<{ address: string }>();
  const tokenAddress = (tokenAddressParam ?? '').toLowerCase() as Address;
  const chainId = useChainId();
  const client = usePublicClient();
  const addresses = getAddresses(chainId);

  // ── 1. Find the TokenCreated event for this address ──────────────
  const { data: allEvents, isLoading: eventsLoading } = useQuery({
    queryKey: ['tokens', chainId],
    queryFn: async () => {
      if (!client) throw new Error('No client');
      return fetchAllTokenCreatedEvents(
        client,
        addresses.factory,
        getFactoryDeploymentBlock(chainId)
      );
    },
    enabled:
      !!client &&
      addresses.factory !== '0x0000000000000000000000000000000000000000',
    staleTime: 60_000,
  });

  const event: TokenCreatedEvent | undefined = useMemo(() => {
    if (!allEvents) return undefined;
    return allEvents.find(e => e.tokenAddress.toLowerCase() === tokenAddress);
  }, [allEvents, tokenAddress]);

  // ── 2. Derive tickSpacing and poolKey ─────────────────────────────
  const { tickSpacing, poolKey } = useMemo(() => {
    if (!event) return { tickSpacing: 60, poolKey: null };
    const ts = resolveTickSpacing(
      event.tokenAddress,
      event.pairedToken,
      event.poolHook,
      event.poolId
    );
    return {
      tickSpacing: ts,
      poolKey: buildPoolKey(event.tokenAddress, event.pairedToken, ts, event.poolHook),
    };
  }, [event]);

  // ── 3. Multicall: token + hook + locker state ────────────────────
  const staticContracts = useMemo(() => {
    if (!event) return [];
    return [
      // Token
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'name' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'symbol' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'totalSupply' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'admin' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'imageUrl' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'metadata' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'contractURI' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'isVerified' } as const,
      { address: event.tokenAddress, abi: tokenAbi, functionName: 'metadataRenderer' } as const,
      // Hook base (present on every hook variant)
      { address: event.poolHook, abi: hookBaseAbi, functionName: 'artCoinIsToken0', args: [event.poolId] } as const,
      { address: event.poolHook, abi: hookBaseAbi, functionName: 'mevModuleEnabled', args: [event.poolId] } as const,
      { address: event.poolHook, abi: hookBaseAbi, functionName: 'poolCreationTimestamp', args: [event.poolId] } as const,
      // Hook static-fee-only (only present on ArtCoinsHookStaticFee; reads
      // fail harmlessly on other hook variants, e.g. the skim-fee hook —
      // `allowFailure: true` below means those show up as status 'failure').
      { address: event.poolHook, abi: staticHookAbi, functionName: 'artCoinFee', args: [event.poolId] } as const,
      { address: event.poolHook, abi: staticHookAbi, functionName: 'pairedFee', args: [event.poolId] } as const,
      // Locker
      { address: event.locker, abi: lockerAbi, functionName: 'tokenRewards', args: [event.tokenAddress] } as const,
    ];
  }, [event]);

  const { data: staticData, isLoading: readsLoading, refetch: refetchStatic } = useReadContracts({
    contracts: staticContracts,
    allowFailure: true,
    query: { enabled: staticContracts.length > 0, staleTime: 15_000 },
  });

  const [metadataModalOpen, setMetadataModalOpen] = useState(false);

  const name = staticData?.[0]?.result as string | undefined;
  const symbol = staticData?.[1]?.result as string | undefined;
  const totalSupply = staticData?.[2]?.result as bigint | undefined;
  const currentAdmin = staticData?.[3]?.result as Address | undefined;
  const imageUrl = staticData?.[4]?.result as string | undefined;
  const metadataText = staticData?.[5]?.result as string | undefined;
  const contractURI = staticData?.[6]?.result as string | undefined;
  const isVerified = staticData?.[7]?.result as boolean | undefined;
  const metadataRenderer = staticData?.[8]?.result as Address | undefined;
  // `artCoinIsToken0` — only treat as a real value when the read actually
  // succeeded. Coercing a failed/pending read to `false` would silently
  // tell the swap widget the wrong pool direction (see SwapWidget usage
  // below), which quotes/swaps against the wrong side of the pool.
  const isToken0 =
    staticData?.[9]?.status === 'success'
      ? (staticData[9].result as boolean)
      : undefined;
  const mevModuleEnabled = staticData?.[10]?.result as boolean | undefined;
  const poolCreationTimestamp = staticData?.[11]?.result as bigint | undefined;
  // Static-fee-only reads: undefined (status 'failure') on non-static-fee
  // hooks (e.g. the skim-fee hook), which is fine — formatFeeBps() and the
  // InfoRows below already render '—' for undefined.
  const buyFee = staticData?.[12]?.result as number | undefined;
  const sellFee = staticData?.[13]?.result as number | undefined;
  const tokenRewards = staticData?.[14]?.result as
    | {
        rewardAdmins: readonly Address[];
        rewardRecipients: readonly Address[];
        rewardBps: readonly number[];
        tickLower: readonly number[];
        tickUpper: readonly number[];
        positionBps: readonly number[];
      }
    | undefined;

  // ── 4. Live MEV state (only while enabled) ────────────────────────
  const { data: mevLiveData } = useReadContracts({
    contracts:
      event && poolKey && event.mevModule.toLowerCase() === addresses.mevLinearFees.toLowerCase()
        ? [
            {
              address: event.mevModule,
              abi: mevLinearAbi,
              functionName: 'getCurrentFee',
              args: [poolKey],
            } as const,
            {
              address: event.mevModule,
              abi: mevLinearAbi,
              functionName: 'getTimeRemaining',
              args: [poolKey],
            } as const,
            {
              address: event.mevModule,
              abi: mevLinearAbi,
              functionName: 'feeConfigs',
              args: [event.poolId],
            } as const,
          ]
        : [],
    allowFailure: true,
    query: {
      enabled: !!event && !!poolKey && mevModuleEnabled === true,
      refetchInterval: mevModuleEnabled ? 10_000 : false,
    },
  });

  const currentMevFee = mevLiveData?.[0]?.result as number | undefined;
  const mevTimeRemaining = mevLiveData?.[1]?.result as bigint | undefined;
  const mevConfig = mevLiveData?.[2]?.result as
    | readonly [number, number, number, bigint]
    | undefined;

  // ── 5. Pool slot0 (sqrtPriceX96) ──────────────────────────────────
  const { data: slot0 } = useReadContracts({
    contracts:
      event && addresses.stateView !== '0x0000000000000000000000000000000000000000'
        ? [
            {
              address: addresses.stateView,
              abi: stateViewAbi,
              functionName: 'getSlot0',
              args: [event.poolId],
            } as const,
          ]
        : [],
    allowFailure: true,
    query: { enabled: !!event, refetchInterval: 15_000 },
  });

  const slot0Result = slot0?.[0]?.result as readonly [bigint, number, number, number] | undefined;
  const sqrtPriceX96 = slot0Result?.[0];
  const currentPrice =
    sqrtPriceX96 !== undefined && isToken0 !== undefined
      ? newMaterialPriceInPaired(sqrtPriceX96, isToken0)
      : undefined;

  // ── Render ────────────────────────────────────────────────────────

  if (eventsLoading && !event) {
    return (
      <main className="mx-auto max-w-4xl px-4 py-8 space-y-6">
        <div className="h-8 w-48 bg-zinc-800 rounded animate-pulse" />
        <CardSkeleton />
        <div className="grid md:grid-cols-2 gap-4">
          <CardSkeleton />
          <CardSkeleton />
        </div>
      </main>
    );
  }

  if (!event) {
    return (
      <main className="mx-auto max-w-4xl px-4 py-16 text-center">
        <h1 className="text-xl font-semibold mb-2">Token not found</h1>
        <p className="text-zinc-500 text-sm mb-6">
          No token with address <span className="font-mono">{shortAddr(tokenAddress)}</span> was
          found in the factory's event log.
        </p>
        <Link
          to="/tokens"
          className="text-violet-400 hover:text-violet-300 text-sm"
        >
          ← Back to all tokens
        </Link>
      </main>
    );
  }

  const image = resolveImage(contractURI, imageUrl ?? event.tokenImage);
  const parsedMeta = parseContractURI(contractURI);
  const description = metadataText || parsedMeta?.description || event.tokenMetadata;

  const uniswapView = uniswapTokenUrl(chainId, event.tokenAddress);
  const uniswapSwap = uniswapSwapUrl(chainId, event.tokenAddress);
  const etherscanToken = explorerUrl(chainId, event.tokenAddress);

  return (
    <main className="mx-auto max-w-4xl px-4 py-8 space-y-6">
      {/* Breadcrumb */}
      <div className="text-sm text-zinc-500">
        <Link to="/tokens" className="hover:text-zinc-300">Tokens</Link>
        <span className="mx-2">/</span>
        <span className="text-zinc-300">{symbol ?? event.tokenSymbol}</span>
      </div>

      {/* Header */}
      <div className="flex flex-col sm:flex-row gap-6">
        <div className="flex-shrink-0">
          <button
            type="button"
            onClick={() => setMetadataModalOpen(true)}
            aria-label="View full metadata"
            className="group relative block w-48 h-48 sm:w-56 sm:h-56 rounded-2xl border border-zinc-800 hover:border-violet-500/60 overflow-hidden bg-zinc-900 transition-colors focus:outline-none focus:ring-2 focus:ring-violet-500"
          >
            {image ? (
              <img
                src={image}
                alt={symbol ?? ''}
                className="w-full h-full object-cover transition-transform duration-300 group-hover:scale-105"
                onError={e => {
                  (e.currentTarget as HTMLImageElement).style.display = 'none';
                }}
              />
            ) : (
              <div className="w-full h-full bg-gradient-to-br from-violet-900/30 to-zinc-900 flex items-center justify-center">
                <span className="font-mono text-3xl font-bold text-zinc-600">
                  {(symbol || event.tokenSymbol || '??').slice(0, 4)}
                </span>
              </div>
            )}
            {/* Hover overlay with "View details" hint */}
            <div className="absolute inset-0 bg-black/0 group-hover:bg-black/40 transition-colors flex items-end justify-center pb-3 opacity-0 group-hover:opacity-100">
              <span className="text-xs font-medium text-white bg-violet-600/90 px-3 py-1.5 rounded-full backdrop-blur-sm inline-flex items-center gap-1.5">
                <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                  <circle cx="11" cy="11" r="8" />
                  <line x1="21" y1="21" x2="16.65" y2="16.65" />
                </svg>
                View details
              </span>
            </div>
          </button>
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <h1 className="text-2xl font-bold">
              {name ?? event.tokenName}{' '}
              <span className="text-zinc-500 font-normal">({symbol ?? event.tokenSymbol})</span>
            </h1>
            {isVerified && (
              <span className="px-2 py-0.5 text-xs rounded-full bg-violet-600/20 text-violet-300 border border-violet-600/30">
                Verified
              </span>
            )}
          </div>
          <CopyableAddress
            address={event.tokenAddress}
            short={false}
            explorerUrl={explorerUrl(chainId, event.tokenAddress)}
            className="mt-1 text-zinc-400"
          />
          {description && (
            <p className="text-sm text-zinc-400 mt-3 line-clamp-3">{description}</p>
          )}
        </div>
        <div className="flex flex-col gap-2 self-start">
          <a
            href={etherscanToken}
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-xl border border-zinc-700 hover:border-zinc-500 px-5 py-2 text-xs font-medium text-zinc-300 hover:text-white flex items-center justify-center gap-2"
          >
            Etherscan
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6" />
              <polyline points="15 3 21 3 21 9" />
              <line x1="10" y1="14" x2="21" y2="3" />
            </svg>
          </a>
          <a
            href={uniswapView}
            target="_blank"
            rel="noopener noreferrer"
            className="rounded-xl border border-zinc-700 hover:border-zinc-500 px-5 py-2 text-xs font-medium text-zinc-300 hover:text-white flex items-center justify-center gap-2"
          >
            Uniswap
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6" />
              <polyline points="15 3 21 3 21 9" />
              <line x1="10" y1="14" x2="21" y2="3" />
            </svg>
          </a>
          <Link
            to={`/tokens/${event.tokenAddress}/claim`}
            className="rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 px-5 py-2 text-xs font-medium text-violet-200 hover:text-white flex items-center justify-center gap-2"
          >
            Claim airdrop
          </Link>
          <Link
            to={`/tokens/${event.tokenAddress}/referrals`}
            className="rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 px-5 py-2 text-xs font-medium text-violet-200 hover:text-white flex items-center justify-center gap-2"
          >
            Referral earnings
          </Link>
        </div>
      </div>

      {/* Swap widget — primary action. Only render when we have a poolKey and the
          paired token is WETH (the widget assumes ETH<->Token via WETH). */}
      {poolKey && event.pairedToken.toLowerCase() === addresses.weth.toLowerCase() && (
        <SwapWidget
          tokenAddress={event.tokenAddress}
          tokenSymbol={symbol ?? event.tokenSymbol}
          poolKey={poolKey}
          isToken0={isToken0}
          mevActive={!!mevModuleEnabled && (mevTimeRemaining ?? 0n) > 0n}
        />
      )}

      {/* MEV banner */}
      {mevModuleEnabled && mevTimeRemaining !== undefined && mevTimeRemaining > 0n && (
        <div className="rounded-xl border border-violet-600/40 bg-violet-950/20 p-4 flex items-center justify-between">
          <div>
            <p className="text-sm font-medium text-violet-200">Anti-sniper protection active</p>
            <p className="text-xs text-violet-300/80 mt-1">
              Current buy fee: <strong>{formatFeeBps(currentMevFee)}</strong>. Decaying to normal
              fees in {formatDuration(mevTimeRemaining)}.
            </p>
          </div>
          <div className="text-right">
            <div className="text-2xl font-bold text-violet-100">{formatFeeBps(currentMevFee)}</div>
            <div className="text-xs text-violet-300/60">{formatDuration(mevTimeRemaining)}</div>
          </div>
        </div>
      )}

      {/* Info cards */}
      <div className="grid md:grid-cols-2 gap-4">
        <InfoCard title="Token">
          <InfoRow label="Name" value={name ?? event.tokenName} />
          <InfoRow label="Symbol" value={symbol ?? event.tokenSymbol} />
          <InfoRow
            label="Supply"
            value={
              totalSupply !== undefined
                ? `${formatSupply(totalSupply)} ${symbol ?? ''}`
                : readsLoading
                ? '…'
                : '—'
            }
          />
          <InfoRow
            label="Admin"
            value={
              currentAdmin ? (
                <CopyableAddress
                  address={currentAdmin}
                  explorerUrl={explorerUrl(chainId, currentAdmin)}
                />
              ) : (
                '—'
              )
            }
          />
          <InfoRow
            label="Deployer"
            value={
              <CopyableAddress
                address={event.tokenAdmin}
                explorerUrl={explorerUrl(chainId, event.tokenAdmin)}
              />
            }
          />
          <InfoRow
            label="Renderer"
            value={
              metadataRenderer &&
              metadataRenderer !== '0x0000000000000000000000000000000000000000' ? (
                <CopyableAddress
                  address={metadataRenderer}
                  explorerUrl={explorerUrl(chainId, metadataRenderer)}
                />
              ) : (
                <span className="text-zinc-500">default (on-chain)</span>
              )
            }
          />
          <InfoRow label="Verified" value={isVerified ? 'Yes' : 'No'} />
        </InfoCard>

        <InfoCard title="Pool">
          <InfoRow
            label="Paired Token"
            value={pairedTokenLabel(event.pairedToken, addresses.weth)}
          />
          <InfoRow
            label="Current Price"
            value={
              currentPrice !== undefined
                ? `${formatPrice(currentPrice)} ${pairedTokenLabel(event.pairedToken, addresses.weth)}`
                : 'loading…'
            }
          />
          <InfoRow label="Buy Fee (total)" value={formatFeeBps(buyFee)} />
          <InfoRow label="Sell Fee (total)" value={formatFeeBps(sellFee)} />
          <InfoRow label="Starting Tick" value={event.startingTick.toLocaleString()} />
          <InfoRow label="Tick Spacing" value={tickSpacing} />
          <InfoRow
            label="Hook"
            value={
              <CopyableAddress
                address={event.poolHook}
                explorerUrl={explorerUrl(chainId, event.poolHook)}
              />
            }
          />
          <InfoRow
            label="Pool ID"
            value={<span className="font-mono text-xs">{shortAddr(event.poolId)}</span>}
          />
          <InfoRow
            label="Created"
            value={formatTimestamp(poolCreationTimestamp)}
          />
        </InfoCard>

        <InfoCard title="Anti-Sniper (MEV)">
          <InfoRow
            label="Module"
            value={
              <CopyableAddress
                address={event.mevModule}
                explorerUrl={explorerUrl(chainId, event.mevModule)}
              />
            }
          />
          <InfoRow
            label="Status"
            value={
              mevModuleEnabled === undefined
                ? '…'
                : mevModuleEnabled
                ? 'Active'
                : 'Completed / inactive'
            }
          />
          {mevConfig && (
            <>
              <InfoRow label="Starting Fee" value={formatFeeBps(mevConfig[0])} />
              <InfoRow label="Ending Fee" value={formatFeeBps(mevConfig[1])} />
              <InfoRow label="Duration" value={formatDuration(mevConfig[2])} />
            </>
          )}
          {mevModuleEnabled && currentMevFee !== undefined && (
            <InfoRow label="Current Fee" value={formatFeeBps(currentMevFee)} />
          )}
          {mevModuleEnabled && mevTimeRemaining !== undefined && (
            <InfoRow label="Time Remaining" value={formatDuration(mevTimeRemaining)} />
          )}
        </InfoCard>

        {/* "Fee Distribution" (protocol vs. LP split) previously read
            `protocolFeeNumerator`, which does not exist on any current hook
            (`ArtCoinsHook`, `ArtCoinsHookStaticFee`, `ArtCoinsHookSkimFee`) —
            it only ever existed on the legacy `ArtCoinsHookV2`. There is no
            replacement read that exposes an equivalent protocol/LP split, so
            the card is omitted rather than showing invented numbers. */}

        <InfoCard title="LP Positions">
          <InfoRow
            label="Locker"
            value={
              <CopyableAddress
                address={event.locker}
                explorerUrl={explorerUrl(chainId, event.locker)}
              />
            }
          />
          {tokenRewards && tokenRewards.rewardRecipients.length > 0 ? (
            <>
              {tokenRewards.rewardRecipients.map((recipient, i) => (
                <InfoRow
                  key={i}
                  label={`Recipient ${i + 1}`}
                  value={
                    <span>
                      <CopyableAddress
                        address={recipient}
                        explorerUrl={explorerUrl(chainId, recipient)}
                      />{' '}
                      <span className="text-zinc-500">({tokenRewards.rewardBps[i] / 100}%)</span>
                    </span>
                  }
                />
              ))}
              {tokenRewards.tickLower.map((tl, i) => (
                <InfoRow
                  key={`pos-${i}`}
                  label={`Position ${i + 1}`}
                  value={`${tl.toLocaleString()} → ${tokenRewards.tickUpper[i].toLocaleString()} (${tokenRewards.positionBps[i] / 100}%)`}
                />
              ))}
            </>
          ) : (
            <p className="text-sm text-zinc-500 py-2">
              {readsLoading ? 'Loading…' : 'No reward data available.'}
            </p>
          )}
        </InfoCard>
      </div>

      {/* Trading note */}
      <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4 text-xs text-zinc-500 space-y-2">
        <p>
          <strong className="text-zinc-400">About this pool:</strong> Swaps go directly through
          Uniswap V4's Universal Router with this token's custom hook (
          <span className="font-mono">{shortAddr(event.poolHook)}</span>). Uniswap's default
          frontend doesn't auto-discover custom-hook pools, so use the in-app swap above or the{' '}
          <a
            href={uniswapSwap}
            target="_blank"
            rel="noopener noreferrer"
            className="text-violet-400 hover:text-violet-300 underline"
          >
            Uniswap swap page
          </a>{' '}
          (which may require pasting the pool info).
        </p>
      </div>

      {/* Deployment tx */}
      <div className="text-center text-xs text-zinc-600">
        Deployed in{' '}
        <a
          href={`${chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io'}/tx/${event.transactionHash}`}
          target="_blank"
          rel="noopener noreferrer"
          className="text-zinc-500 hover:text-zinc-300 underline"
        >
          block {event.blockNumber.toString()}
        </a>
      </div>

      {/* Full-metadata modal */}
      <TokenMetadataModal
        open={metadataModalOpen}
        onClose={() => setMetadataModalOpen(false)}
        image={image}
        name={name ?? event.tokenName}
        symbol={symbol ?? event.tokenSymbol}
        description={description}
        parsedMeta={parsedMeta}
        contractURI={contractURI}
        onRefresh={() => {
          refetchStatic();
        }}
      />
    </main>
  );
}
