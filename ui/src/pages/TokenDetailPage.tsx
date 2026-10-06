import { useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useReadContract, useReadContracts } from 'wagmi';
import type { Address, Hex } from 'viem';

import InfoCard from '../components/InfoCard';
import InfoRow from '../components/InfoRow';
import CopyableAddress from '../components/CopyableAddress';
import SwapWidget from '../components/SwapWidget';
import TokenMetadataModal from '../components/TokenMetadataModal';
import OfficialBadge from '../components/OfficialBadge';
import { uniswapTokenUrl } from '../lib/config';
import { stateViewAbi } from '../lib/abi';
import { tokenV1Abi } from '../lib/abi/v1/token';
import { tokenV2Abi } from '../lib/abi/v2/token';
import { hookV1Abi } from '../lib/abi/v1/hook';
import { hookV2Abi } from '../lib/abi/v2/hook';
import { lockerV1Abi } from '../lib/abi/v1/locker';
import { lockerV2Abi } from '../lib/abi/v2/locker';
import { mevLinearSkimV1Abi } from '../lib/abi/v1/mevLinearSkim';
import { mevSkimV2Abi } from '../lib/abi/v2/mevSkim';
import { factoryV2Abi } from '../lib/abi/v2/factory';
import { parseContractURI, resolveImage } from '../lib/metadata';
import { computePoolId, priceFromSqrtX96, type PoolKey } from '../lib/pool';
import { cleanText, MAX_DESCRIPTION, MAX_NAME, MAX_SYMBOL } from '../lib/security';
import { feeSummary, normalizeSkim, skimPercent, feePercent } from '../lib/poolReads';
import { shortAddr, formatSupply, formatDuration, formatPrice } from '../lib/format';
import { useToken } from '../lib/useTokens';
import { useAddressesOrNull } from '../lib/useChain';
import { getV2Stack } from '../lib/v2';
import { impliedFdvEth } from '../lib/curve';

const ZERO = '0x0000000000000000000000000000000000000000';

function explorerUrl(chainId: number, addr: string): string {
  const base = chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';
  return `${base}/address/${addr}`;
}

function CardSkeleton({ height = 'h-40' }: { height?: string }) {
  return <div className={`rounded-xl bg-zinc-900 border border-zinc-800 animate-pulse ${height}`} />;
}

export default function TokenDetailPage() {
  const { address: param } = useParams<{ address: string }>();
  const { token: record, validAddress, isLoading, supported } = useToken(param);
  const { chainId, addresses } = useAddressesOrNull();
  const [metadataModalOpen, setMetadataModalOpen] = useState(false);

  const version = record?.version ?? 1;
  const coin = record?.token;

  // ── 1. the pool key comes from the locker record, not from guessing a tick spacing ──
  const lockerAbi = version === 2 ? lockerV2Abi : lockerV1Abi;
  const { data: rewards, isLoading: rewardsLoading } = useReadContract({
    address: record?.locker,
    abi: lockerAbi,
    functionName: 'tokenRewards',
    args: coin ? [coin] : undefined,
    query: { enabled: !!record, staleTime: 60_000 },
  });
  const rewardsView = rewards as
    | {
        token: Address;
        poolKey: PoolKey;
        rewardBps: readonly number[];
        rewardRecipients: readonly Address[];
        numPositions: bigint;
      }
    | undefined;
  const poolKey = rewardsView?.poolKey ?? null;
  const poolId: Hex | undefined = useMemo(() => (poolKey ? computePoolId(poolKey) : undefined), [poolKey]);
  // the pool this record announced must be the pool the locker holds, else do not trade it
  const poolMatches = !!poolKey && !!record && poolId?.toLowerCase() === record.poolId.toLowerCase();

  // ── 2. token, hook and mev reads ──
  const v2 = getV2Stack(chainId);
  const contracts = useMemo(() => {
    if (!record || !poolId) return [];
    const t = record.token;
    const list = [
      { address: t, abi: tokenV1Abi, functionName: 'name' },
      { address: t, abi: tokenV1Abi, functionName: 'symbol' },
      { address: t, abi: tokenV1Abi, functionName: 'totalSupply' },
      { address: t, abi: tokenV1Abi, functionName: 'admin' },
      { address: t, abi: tokenV1Abi, functionName: 'imageUrl' },
      { address: t, abi: tokenV1Abi, functionName: 'metadata' },
      { address: t, abi: tokenV1Abi, functionName: 'contractURI' },
      { address: t, abi: tokenV1Abi, functionName: 'isVerified' },
      { address: t, abi: tokenV1Abi, functionName: 'metadataRenderer' },
      { address: record.hook, abi: record.version === 2 ? hookV2Abi : hookV1Abi, functionName: 'skimConfig', args: [poolId] },
    ] as const;
    return list;
  }, [record, poolId]);

  const { data: staticData, isLoading: readsLoading, refetch: refetchStatic } = useReadContracts({
    contracts: contracts as never,
    allowFailure: true,
    query: { enabled: contracts.length > 0, staleTime: 15_000 },
  });
  const sd = staticData as readonly { result?: unknown }[] | undefined;
  const r = (i: number) => sd?.[i]?.result;
  const name = r(0) as string | undefined;
  const symbol = r(1) as string | undefined;
  const totalSupply = r(2) as bigint | undefined;
  const currentAdmin = r(3) as Address | undefined;
  const imageUrl = r(4) as string | undefined;
  const metadataText = r(5) as string | undefined;
  const contractURI = r(6) as string | undefined;
  const creatorConfirmed = r(7) as boolean | undefined;
  const metadataRenderer = r(8) as Address | undefined;
  const skim = normalizeSkim(r(9));

  // v2: independent confirmation from the factory, v2 token tax config
  const { data: v2Data } = useReadContracts({
    contracts:
      record && record.version === 2
        ? ([
            { address: record.factory, abi: factoryV2Abi, functionName: 'isArtCoin', args: [record.token] },
            { address: record.token, abi: tokenV2Abi, functionName: 'taxMode' },
            { address: record.token, abi: tokenV2Abi, functionName: 'taxBps' },
            { address: record.token, abi: tokenV2Abi, functionName: 'taxBpsMax' },
            { address: record.token, abi: tokenV2Abi, functionName: 'taxSink' },
          ] as const)
        : [],
    allowFailure: true,
    query: { enabled: !!record && record.version === 2 },
  });
  const isArtCoin = v2Data?.[0]?.result as boolean | undefined;
  const taxMode = v2Data?.[1]?.result as number | undefined;
  const taxBps = v2Data?.[2]?.result as number | undefined;
  const taxBpsMax = v2Data?.[3]?.result as number | undefined;
  const taxSink = v2Data?.[4]?.result as Address | undefined;

  // ── 3. anti sniper state ──
  const mevAddr = record && record.mevModule !== ZERO ? record.mevModule : undefined;
  const { data: mevData } = useReadContracts({
    contracts:
      record && poolId && mevAddr
        ? record.version === 2
          ? ([
              { address: mevAddr, abi: mevSkimV2Abi, functionName: 'currentSkimBps', args: [poolId] },
              { address: mevAddr, abi: mevSkimV2Abi, functionName: 'windowEnd', args: [poolId] },
            ] as const)
          : ([
              { address: mevAddr, abi: mevLinearSkimV1Abi, functionName: 'currentSkimBps', args: [poolId] },
              { address: mevAddr, abi: mevLinearSkimV1Abi, functionName: 'skimConfigs', args: [poolId] },
              { address: mevAddr, abi: mevLinearSkimV1Abi, functionName: 'operational', args: [poolId] },
            ] as const)
        : [],
    allowFailure: true,
    query: { enabled: !!mevAddr && !!poolId, refetchInterval: 10_000 },
  });
  const md = mevData as readonly { result?: unknown }[] | undefined;
  let mevSkimBps: number | undefined;
  let mevActive = false;
  let mevEnd: number | undefined;
  if (record?.version === 2) {
    const cur = md?.[0]?.result as readonly [number, boolean] | undefined;
    mevSkimBps = cur ? Number(cur[0]) : undefined;
    mevActive = cur ? !!cur[1] : false;
    mevEnd = md?.[1]?.result ? Number(md[1].result as bigint) : undefined;
  } else if (record) {
    mevSkimBps = md?.[0]?.result !== undefined ? Number(md[0].result as number) : undefined;
    const cfg = md?.[1]?.result as readonly [number, number, number, bigint] | undefined;
    mevActive = !!(md?.[2]?.result as boolean | undefined);
    mevEnd = cfg ? Number(cfg[3]) + Number(cfg[2]) : undefined;
  }
  const mevRemaining = mevEnd !== undefined ? Math.max(0, mevEnd - Math.floor(Date.now() / 1000)) : undefined;

  // ── 4. pool price ──
  const { data: slot0 } = useReadContract({
    address: addresses?.stateView,
    abi: stateViewAbi,
    functionName: 'getSlot0',
    args: poolId ? [poolId] : undefined,
    query: { enabled: !!poolId && !!addresses && addresses.stateView !== ZERO, refetchInterval: 15_000 },
  });
  const coinPerEth = slot0 && slot0[0] > 0n ? priceFromSqrtX96(slot0[0]) : undefined;
  const ethPerCoin = coinPerEth ? 1 / coinPerEth : undefined;
  const supplyWhole = totalSupply !== undefined ? Number(totalSupply / 10n ** 18n) : undefined;

  // ── render ──
  if (!validAddress) {
    return (
      <main className="mx-auto max-w-4xl px-4 py-16 text-center">
        <h1 className="text-xl font-semibold mb-2">Not a token address</h1>
        <Link to="/tokens" className="text-violet-400 hover:text-violet-300 text-sm">← Back to all tokens</Link>
      </main>
    );
  }
  if (!supported) {
    return (
      <main className="mx-auto max-w-4xl px-4 py-16 text-center text-zinc-400">
        No artcoins deployment is configured for this network. Switch to Ethereum mainnet.
      </main>
    );
  }
  if (isLoading && !record) {
    return (
      <main className="mx-auto max-w-4xl px-4 py-8 space-y-6">
        <div className="h-8 w-48 bg-zinc-800 rounded animate-pulse" />
        <CardSkeleton />
        <div className="grid md:grid-cols-2 gap-4"><CardSkeleton /><CardSkeleton /></div>
      </main>
    );
  }
  if (!record) {
    return (
      <main className="mx-auto max-w-4xl px-4 py-16 text-center">
        <h1 className="text-xl font-semibold mb-2">Token not found</h1>
        <p className="text-zinc-500 text-sm mb-6">
          <span className="font-mono">{shortAddr(param)}</span> was not launched by a factory in the deployment registry, so
          this ui does not show it.
        </p>
        <Link to="/tokens" className="text-violet-400 hover:text-violet-300 text-sm">← Back to all tokens</Link>
      </main>
    );
  }

  const shownName = cleanText(name ?? record.name, MAX_NAME);
  const shownSymbol = cleanText(symbol ?? record.symbol, MAX_SYMBOL);
  const image = resolveImage(contractURI, imageUrl ?? record.image);
  const parsedMeta = parseContractURI(contractURI);
  const description = cleanText(metadataText || (typeof parsedMeta?.description === 'string' ? parsedMeta.description : '') || record.metadata, MAX_DESCRIPTION);
  const etherscanToken = explorerUrl(chainId, record.token);

  return (
    <main className="mx-auto max-w-4xl px-4 py-8 space-y-6">
      <div className="text-sm text-zinc-500">
        <Link to="/tokens" className="hover:text-zinc-300">Tokens</Link>
        <span className="mx-2">/</span>
        <span className="text-zinc-300">{shownSymbol}</span>
      </div>

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
                alt={shownSymbol}
                referrerPolicy="no-referrer"
                decoding="async"
                className="w-full h-full object-cover transition-transform duration-300 group-hover:scale-105"
                onError={(e) => {
                  (e.currentTarget as HTMLImageElement).style.display = 'none';
                }}
              />
            ) : (
              <div className="w-full h-full bg-gradient-to-br from-violet-900/30 to-zinc-900 flex items-center justify-center">
                <span className="font-mono text-3xl font-bold text-zinc-600">{shownSymbol.slice(0, 4) || '??'}</span>
              </div>
            )}
          </button>
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <h1 className="text-2xl font-bold">
              {shownName} <span className="text-zinc-500 font-normal">({shownSymbol})</span>
            </h1>
            <OfficialBadge version={record.version} />
            {record.version === 2 && isArtCoin === false && (
              <span className="px-2 py-0.5 text-xs rounded-full bg-red-600/20 text-red-300 border border-red-600/30">factory does not list this token</span>
            )}
            {record.lookalike && (
              <span className="px-2 py-0.5 text-xs rounded-full bg-amber-500/10 text-amber-300 border border-amber-500/30">another token has a similar name or symbol</span>
            )}
          </div>
          <CopyableAddress address={record.token} short={false} explorerUrl={etherscanToken} className="mt-1 text-zinc-400" />
          <p className="text-xs text-amber-300/80 mt-2">
            Always compare this contract address with the one you meant to trade. Anyone can launch a token with any name.
          </p>
          {description && <p className="text-sm text-zinc-400 mt-3 line-clamp-3 whitespace-pre-wrap">{description}</p>}
        </div>
        <div className="flex flex-col gap-2 self-start">
          <a href={etherscanToken} target="_blank" rel="noopener noreferrer" className="rounded-xl border border-zinc-700 hover:border-zinc-500 px-5 py-2 text-xs font-medium text-zinc-300 hover:text-white text-center">Etherscan</a>
          <a href={uniswapTokenUrl(chainId, record.token)} target="_blank" rel="noopener noreferrer" className="rounded-xl border border-zinc-700 hover:border-zinc-500 px-5 py-2 text-xs font-medium text-zinc-300 hover:text-white text-center">Uniswap</a>
          <Link to={`/tokens/${record.token}/claim`} className="rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 px-5 py-2 text-xs font-medium text-violet-200 hover:text-white text-center">Claim airdrop</Link>
          <Link to={`/tokens/${record.token}/referrals`} className="rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 px-5 py-2 text-xs font-medium text-violet-200 hover:text-white text-center">Referral earnings</Link>
        </div>
      </div>

      {rewardsLoading && <CardSkeleton height="h-64" />}
      {!rewardsLoading && poolKey && poolMatches && (
        <SwapWidget
          tokenAddress={record.token}
          tokenSymbol={shownSymbol}
          poolKey={poolKey}
          feeSummary={skim ? feeSummary(skim) : undefined}
          mevActive={mevActive}
          mevSkimPercent={mevSkimBps !== undefined ? skimPercent(mevSkimBps) : undefined}
        />
      )}
      {!rewardsLoading && poolKey && !poolMatches && (
        <div className="rounded-xl border border-red-900 bg-red-950/30 p-4 text-sm text-red-300">
          The locker's pool for this token does not match the pool announced at launch. Trading is disabled in this ui.
        </div>
      )}
      {!rewardsLoading && !poolKey && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-sm text-zinc-400">Could not read the pool from the locker, trading is disabled.</div>
      )}

      {mevActive && mevSkimBps !== undefined && (
        <div className="rounded-xl border border-violet-600/40 bg-violet-950/20 p-4 flex items-center justify-between">
          <div>
            <p className="text-sm font-medium text-violet-200">Anti-sniper skim active</p>
            <p className="text-xs text-violet-300/80 mt-1">
              Current skim: <strong>{skimPercent(mevSkimBps).toFixed(2)}%</strong> of volume, decaying to the baseline{mevRemaining !== undefined ? ` in ${formatDuration(mevRemaining)}` : ''}.
            </p>
          </div>
          <div className="text-2xl font-bold text-violet-100">{skimPercent(mevSkimBps).toFixed(2)}%</div>
        </div>
      )}

      <div className="grid md:grid-cols-2 gap-4">
        <InfoCard title="Token">
          <InfoRow label="Name" value={shownName} />
          <InfoRow label="Symbol" value={shownSymbol} />
          <InfoRow label="Supply" value={totalSupply !== undefined ? `${formatSupply(totalSupply)} ${shownSymbol}` : readsLoading ? '…' : '—'} />
          <InfoRow label="Admin" value={currentAdmin ? <CopyableAddress address={currentAdmin} explorerUrl={explorerUrl(chainId, currentAdmin)} /> : '—'} />
          <InfoRow label="Launched by" value={<CopyableAddress address={record.sender} explorerUrl={explorerUrl(chainId, record.sender)} />} />
          <InfoRow label="Factory" value={<CopyableAddress address={record.factory} explorerUrl={explorerUrl(chainId, record.factory)} />} />
          <InfoRow
            label="Renderer"
            value={metadataRenderer && metadataRenderer !== ZERO ? <CopyableAddress address={metadataRenderer} explorerUrl={explorerUrl(chainId, metadataRenderer)} /> : <span className="text-zinc-500">default (on-chain)</span>}
          />
          <InfoRow
            label="Creator flag"
            value={<span title="Set by the token's own admin. It is not a trust signal.">{creatorConfirmed ? 'admin set the verified flag' : 'not set'}</span>}
          />
          {record.version === 2 && taxMode !== undefined && (
            <InfoRow
              label="Tax"
              value={
                taxMode === 0
                  ? 'none'
                  : taxMode === 1
                    ? `venue tax ${((taxBps ?? 0) / 100).toFixed(2)}% (max ${((taxBpsMax ?? 0) / 100).toFixed(2)}%) to ${taxSink ? shortAddr(taxSink) : '?'}`
                    : 'hard mode, canonical flows only'
              }
            />
          )}
        </InfoCard>

        <InfoCard title="Pool">
          <InfoRow label="Pair" value="native ETH" />
          <InfoRow label="Price" value={ethPerCoin !== undefined ? `${formatPrice(ethPerCoin)} ETH` : 'loading…'} />
          <InfoRow label="Implied fdv" value={ethPerCoin !== undefined && supplyWhole !== undefined ? `${(ethPerCoin * supplyWhole).toLocaleString(undefined, { maximumFractionDigits: 2 })} ETH` : '—'} />
          {record.startingTick !== null && supplyWhole !== undefined && (
            <InfoRow label="Launch fdv" value={`${impliedFdvEth(record.startingTick, supplyWhole).toLocaleString(undefined, { maximumFractionDigits: 2 })} ETH`} />
          )}
          {skim && <InfoRow label="Fees" value={`${feePercent(skim.lpFee).toFixed(2)}% lp + ${skimPercent(skim.baselineSkimBps).toFixed(2)}% skim`} />}
          {poolKey && <InfoRow label="Tick spacing" value={poolKey.tickSpacing} />}
          <InfoRow label="Hook" value={<CopyableAddress address={record.hook} explorerUrl={explorerUrl(chainId, record.hook)} />} />
          <InfoRow label="Pool ID" value={<span className="font-mono text-xs">{shortAddr(record.poolId)}</span>} />
          <InfoRow label="Locker" value={<CopyableAddress address={record.locker} explorerUrl={explorerUrl(chainId, record.locker)} />} />
          {v2 && record.version === 2 && <InfoRow label="Stack" value="v2" />}
        </InfoCard>

        <InfoCard title="Fee distribution">
          {skim ? (
            <div className="space-y-3 text-sm">
              <div className="flex justify-between"><span className="text-zinc-400">LP fee</span><span>{feePercent(skim.lpFee).toFixed(2)}% of the swap</span></div>
              <div className="flex justify-between"><span className="text-zinc-400">Baseline skim</span><span>{skimPercent(skim.baselineSkimBps).toFixed(2)}% of volume</span></div>
              <div className="flex justify-between"><span className="text-zinc-400">Bounty share of skim</span><span>{(skim.bountyBps / 100).toFixed(2)}%</span></div>
              <div className="flex justify-between"><span className="text-zinc-400">Protocol share of skim</span><span>{(100 - skim.bountyBps / 100).toFixed(2)}%</span></div>
              <div className="flex justify-between"><span className="text-zinc-400">Referral cap</span><span>{skimPercent(skim.maxReferralBpsOfVolume).toFixed(2)}% of volume, paid from the protocol share</span></div>
              <div className="flex justify-between"><span className="text-zinc-400">Bounty recipient</span><CopyableAddress address={skim.bountyRecipient} explorerUrl={explorerUrl(chainId, skim.bountyRecipient)} /></div>
            </div>
          ) : (
            <p className="text-sm text-zinc-500 py-2">{readsLoading ? 'Loading…' : 'Fee config unavailable.'}</p>
          )}
        </InfoCard>

        <InfoCard title="LP rewards split">
          {rewardsView && rewardsView.rewardRecipients.length > 0 ? (
            rewardsView.rewardRecipients.map((recipient, i) => (
              <InfoRow
                key={i}
                label={`Recipient ${i + 1}`}
                value={
                  <span>
                    <CopyableAddress address={recipient} explorerUrl={explorerUrl(chainId, recipient)} />{' '}
                    <span className="text-zinc-500">({rewardsView.rewardBps[i] / 100}%)</span>
                    {skim && recipient.toLowerCase() === skim.protocolRecipient.toLowerCase() && <span className="text-zinc-500"> protocol</span>}
                  </span>
                }
              />
            ))
          ) : (
            <p className="text-sm text-zinc-500 py-2">{readsLoading || rewardsLoading ? 'Loading…' : 'No reward data available.'}</p>
          )}
          {record.config && (
            record.config.locker.tickLower.map((tl, i) => (
              <InfoRow key={`pos-${i}`} label={`Position ${i + 1}`} value={`${tl.toLocaleString()} → ${record.config!.locker.tickUpper[i].toLocaleString()} (${record.config!.locker.positionBps[i] / 100}%)`} />
            ))
          )}
        </InfoCard>

        {mevAddr && (
          <InfoCard title="Anti-sniper">
            <InfoRow label="Module" value={<CopyableAddress address={mevAddr} explorerUrl={explorerUrl(chainId, mevAddr)} />} />
            <InfoRow label="Status" value={md ? (mevActive ? 'Active' : 'Completed') : '…'} />
            {mevSkimBps !== undefined && <InfoRow label="Current skim" value={`${skimPercent(mevSkimBps).toFixed(2)}% of volume`} />}
            {mevRemaining !== undefined && mevActive && <InfoRow label="Time remaining" value={formatDuration(mevRemaining)} />}
          </InfoCard>
        )}
      </div>

      <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4 text-xs text-zinc-500 space-y-2">
        <p>
          <strong className="text-zinc-400">About this pool:</strong> swaps go through Uniswap V4's Universal Router with this
          token's hook (<span className="font-mono">{shortAddr(record.hook)}</span>). Uniswap's default frontend does not
          discover custom hook pools, use the swap above.
        </p>
      </div>

      <div className="text-center text-xs text-zinc-600">
        Launched in{' '}
        <a href={`${chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io'}/tx/${record.transactionHash}`} target="_blank" rel="noopener noreferrer" className="text-zinc-500 hover:text-zinc-300 underline">
          block {record.blockNumber.toString()}
        </a>
      </div>

      <TokenMetadataModal
        open={metadataModalOpen}
        onClose={() => setMetadataModalOpen(false)}
        image={image}
        name={shownName}
        symbol={shownSymbol}
        description={description}
        parsedMeta={parsedMeta}
        contractURI={contractURI}
        onRefresh={() => {
          void refetchStatic();
        }}
      />
    </main>
  );
}
