import { useCallback, useMemo } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useAccount, useChainId, useReadContracts } from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import type { Address } from 'viem';

import InfoCard from '../components/InfoCard';
import InfoRow from '../components/InfoRow';
import CopyableAddress from '../components/CopyableAddress';
import { getAddresses } from '../lib/config';
import { airdropAbi, tokenAbi } from '../lib/abi';
import { useTokenEvent } from '../lib/useTokenEvent';
import { useTxFlow } from '../lib/useTxFlow';
import { formatSupply, formatTimestamp } from '../lib/format';
import { findEntry, verifyProof, type AllowlistFile } from '../lib/merkle';
import { explorerAddressUrl, explorerTxUrl } from '../lib/explorer';
import { decodeContractError } from '../lib/decodeError';

const CLAIM_ERROR_MESSAGES: Record<string, string> = {
  AirdropNotUnlocked: 'The airdrop is still in its lockup period.',
  InvalidProof: 'Merkle proof is invalid for this address.',
  ZeroToClaim: 'Nothing is currently claimable (still vesting or already claimed).',
  UserMaxClaimed: 'You have already claimed your full allocation.',
  TotalMaxClaimed: 'The airdrop has been fully claimed.',
  AdminClaimed: 'The airdrop admin has swept unclaimed tokens; claims are closed.',
  AirdropNotCreated: 'No airdrop exists for this token.',
};

function decodeClaimError(err: unknown): string {
  return decodeContractError(err, CLAIM_ERROR_MESSAGES);
}

export default function ClaimPage() {
  const { address: tokenAddressParam } = useParams<{ address: string }>();
  const tokenAddress = (tokenAddressParam ?? '').toLowerCase() as Address;
  const chainId = useChainId();
  const { address: wallet, isConnected } = useAccount();
  const addresses = getAddresses(chainId);

  // TokenCreated event — used only as an instant name/symbol fallback while
  // the direct on-chain reads below resolve (reuses the cached tokens list
  // when navigating from a token detail page, so this is usually free).
  const { event: tokenEvent } = useTokenEvent(tokenAddress);

  // Load allowlist JSON for this token from /allowlists/<token>.json
  const {
    data: allowlist,
    isLoading: allowlistLoading,
    error: allowlistError,
  } = useQuery<AllowlistFile>({
    queryKey: ['allowlist', tokenAddress],
    queryFn: async () => {
      const res = await fetch(`/allowlists/${tokenAddress}.json`);
      if (!res.ok) throw new Error(`No allowlist found (${res.status})`);
      return (await res.json()) as AllowlistFile;
    },
    retry: false,
    staleTime: 60_000,
  });

  const entry = useMemo(() => {
    if (!allowlist || !wallet) return null;
    return findEntry(allowlist, wallet);
  }, [allowlist, wallet]);

  const proofVerified = useMemo(() => {
    if (!allowlist || !entry || !wallet) return false;
    return verifyProof(allowlist.root, wallet, entry.amount, entry.proof);
  }, [allowlist, entry, wallet]);

  // Read airdrop state + token metadata
  const { data: reads, refetch: refetchReads } = useReadContracts({
    contracts: [
      {
        address: addresses.airdrop,
        abi: airdropAbi,
        functionName: 'airdrops',
        args: [tokenAddress],
      } as const,
      {
        address: tokenAddress,
        abi: tokenAbi,
        functionName: 'symbol',
      } as const,
      {
        address: tokenAddress,
        abi: tokenAbi,
        functionName: 'name',
      } as const,
    ],
    allowFailure: true,
    query: {
      enabled:
        addresses.airdrop !== '0x0000000000000000000000000000000000000000' &&
        tokenAddress.length === 42,
      refetchInterval: 15_000,
    },
  });

  const airdropState = reads?.[0]?.result as
    | readonly [Address, `0x${string}`, bigint, bigint, bigint, bigint, bigint, boolean]
    | undefined;
  const symbol = (reads?.[1]?.result as string | undefined) ?? tokenEvent?.tokenSymbol;
  const name = (reads?.[2]?.result as string | undefined) ?? tokenEvent?.tokenName;

  // Separate read for the per-wallet claimable amount (depends on wallet + entry).
  const { data: availableReads, refetch: refetchAvailable } = useReadContracts({
    contracts:
      wallet && entry
        ? [
            {
              address: addresses.airdrop,
              abi: airdropAbi,
              functionName: 'amountAvailableToClaim',
              args: [tokenAddress, wallet, BigInt(entry.amount)],
            } as const,
          ]
        : [],
    allowFailure: true,
    query: {
      enabled: !!wallet && !!entry,
      refetchInterval: 15_000,
    },
  });
  const available = availableReads?.[0]?.result as bigint | undefined;

  const onChainRoot = airdropState?.[1];
  const totalSupply = airdropState?.[2];
  const totalClaimed = airdropState?.[3];
  const lockupEndTime = airdropState?.[4];
  const vestingEndTime = airdropState?.[5];
  const adminClaimed = airdropState?.[7];

  const rootMismatch =
    !!allowlist && !!onChainRoot && onChainRoot !== '0x0000000000000000000000000000000000000000000000000000000000000000' && onChainRoot.toLowerCase() !== allowlist.root.toLowerCase();

  const airdropExists =
    !!onChainRoot &&
    onChainRoot !== '0x0000000000000000000000000000000000000000000000000000000000000000';

  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const lockupActive = lockupEndTime !== undefined && nowSec < lockupEndTime;

  // Write path
  const onConfirmed = useCallback(() => {
    refetchReads();
    refetchAvailable();
  }, [refetchReads, refetchAvailable]);

  const { submit, status, hash: txHash, error: writeError, reset } = useTxFlow({ onConfirmed });
  const isPending = status === 'confirming';
  const confirming = status === 'pending';
  const confirmed = status === 'confirmed';

  const onClaim = () => {
    if (!wallet || !entry) return;
    reset();
    submit({
      address: addresses.airdrop,
      abi: airdropAbi,
      functionName: 'claim',
      args: [tokenAddress, wallet, BigInt(entry.amount), entry.proof],
    });
  };

  return (
    <main className="mx-auto max-w-3xl px-4 py-8 space-y-6">
      <div className="text-sm text-zinc-500">
        <Link to={`/tokens/${tokenAddress}`} className="hover:text-zinc-300">
          ← Back to token
        </Link>
      </div>

      <div>
        <h1 className="text-2xl font-bold">
          Claim airdrop{' '}
          {symbol && (
            <span className="text-zinc-500 font-normal">
              ({name ?? symbol})
            </span>
          )}
        </h1>
        <CopyableAddress
          address={tokenAddress}
          explorerUrl={explorerAddressUrl(chainId, tokenAddress)}
          className="mt-1 text-zinc-400"
        />
      </div>

      {/* Allowlist status */}
      {allowlistLoading ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-sm text-zinc-500">
          Loading allowlist…
        </div>
      ) : allowlistError || !allowlist ? (
        <div className="rounded-xl border border-amber-700/40 bg-amber-950/20 p-6 text-sm text-amber-200">
          <p className="font-medium mb-1">No allowlist found</p>
          <p className="text-amber-200/70">
            Could not load{' '}
            <code className="font-mono text-xs">/allowlists/{tokenAddress}.json</code>. Generate
            it with <code className="font-mono text-xs">script-js/build-allowlist.ts</code> and
            place the resulting file in <code className="font-mono text-xs">ui/public/allowlists/</code>.
          </p>
        </div>
      ) : rootMismatch ? (
        <div className="rounded-xl border border-red-700/40 bg-red-950/20 p-6 text-sm text-red-200">
          <p className="font-medium mb-1">Allowlist does not match the on-chain root</p>
          <p className="text-red-200/70 break-all">
            Local root: <span className="font-mono">{allowlist.root}</span>
            <br />
            On-chain root: <span className="font-mono">{onChainRoot}</span>
          </p>
        </div>
      ) : null}

      {/* Connection */}
      {!isConnected && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 flex flex-col items-start gap-3">
          <p className="text-sm text-zinc-300">Connect a wallet to check eligibility.</p>
          <ConnectButton />
        </div>
      )}

      {/* Eligibility + claim */}
      {isConnected && allowlist && !rootMismatch && (
        <div className="space-y-4">
          {!entry ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-sm">
              <p className="font-medium text-white mb-1">Not eligible</p>
              <p className="text-zinc-400">
                The connected address{' '}
                <CopyableAddress address={wallet!} explorerUrl={explorerAddressUrl(chainId, wallet!)} />{' '}
                is not in the allowlist for this token.
              </p>
            </div>
          ) : !proofVerified ? (
            <div className="rounded-xl border border-red-700/40 bg-red-950/20 p-6 text-sm text-red-200">
              <p className="font-medium mb-1">Proof verification failed locally</p>
              <p className="text-red-200/70">
                The proof for your address does not verify against the root. The allowlist JSON may
                be corrupt — regenerate it.
              </p>
            </div>
          ) : (
            <InfoCard title="Your allocation">
              <InfoRow
                label="Allocated"
                value={
                  <span>
                    {formatSupply(BigInt(entry.amount))} {symbol ?? ''}
                  </span>
                }
              />
              <InfoRow
                label="Available to claim now"
                value={
                  available !== undefined ? (
                    <span className="font-medium text-violet-300">
                      {formatSupply(available)} {symbol ?? ''}
                    </span>
                  ) : (
                    '…'
                  )
                }
              />
              <InfoRow
                label="Status"
                value={
                  !airdropExists
                    ? 'airdrop not found on-chain'
                    : adminClaimed
                    ? 'admin swept — claims closed'
                    : lockupActive
                    ? `locked until ${formatTimestamp(lockupEndTime)}`
                    : 'unlocked'
                }
              />

              <div className="pt-4">
                <button
                  type="button"
                  onClick={onClaim}
                  disabled={
                    !airdropExists ||
                    lockupActive ||
                    adminClaimed === true ||
                    (available !== undefined && available === 0n) ||
                    isPending ||
                    confirming
                  }
                  className="rounded-xl bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 disabled:text-zinc-500 px-6 py-2.5 text-sm font-medium text-white"
                >
                  {isPending
                    ? 'Confirm in wallet…'
                    : confirming
                    ? 'Waiting for confirmation…'
                    : confirmed
                    ? 'Claim again'
                    : 'Claim'}
                </button>
                {txHash && (
                  <div className="mt-3 text-xs text-zinc-400">
                    Tx:{' '}
                    <a
                      href={explorerTxUrl(chainId, txHash)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="font-mono text-violet-400 hover:text-violet-300 underline break-all"
                    >
                      {txHash}
                    </a>{' '}
                    {confirmed && <span className="text-emerald-400">✓ confirmed</span>}
                  </div>
                )}
                {writeError && (
                  <p className="mt-3 text-xs text-red-300">{decodeClaimError(writeError)}</p>
                )}
              </div>
            </InfoCard>
          )}

          {/* Airdrop state panel */}
          <InfoCard title="Airdrop state">
            <InfoRow
              label="Contract"
              value={
                <CopyableAddress
                  address={addresses.airdrop}
                  explorerUrl={explorerAddressUrl(chainId, addresses.airdrop)}
                />
              }
            />
            <InfoRow
              label="Merkle root"
              value={
                onChainRoot ? (
                  <span className="font-mono text-xs break-all">{onChainRoot}</span>
                ) : (
                  '—'
                )
              }
            />
            <InfoRow
              label="Total supply"
              value={
                totalSupply !== undefined
                  ? `${formatSupply(totalSupply)} ${symbol ?? ''}`
                  : '—'
              }
            />
            <InfoRow
              label="Total claimed"
              value={
                totalClaimed !== undefined
                  ? `${formatSupply(totalClaimed)} ${symbol ?? ''}`
                  : '—'
              }
            />
            <InfoRow
              label="Lockup ends"
              value={formatTimestamp(lockupEndTime)}
            />
            <InfoRow
              label="Vesting ends"
              value={formatTimestamp(vestingEndTime)}
            />
          </InfoCard>
        </div>
      )}
    </main>
  );
}
