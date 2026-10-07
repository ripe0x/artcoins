import { useEffect, useMemo } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  useAccount,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import type { Address } from 'viem';
import { BaseError, ContractFunctionRevertedError, isAddress } from 'viem';

import InfoCard from '../components/InfoCard';
import InfoRow from '../components/InfoRow';
import CopyableAddress from '../components/CopyableAddress';
import { airdropAbi } from '../lib/abi';
import { airdropV2Abi } from '../lib/abi/v2/airdrop';
import { factoryV2Abi } from '../lib/abi/v2/factory';
import { tokenV1Abi as tokenAbi } from '../lib/abi/v1/token';
import { useAddressesOrNull } from '../lib/useChain';
import type { ContractAddresses } from '../lib/config';
import { formatSupply, formatTimestamp } from '../lib/format';
import { findEntry, verifyProof, type AllowlistFile } from '../lib/merkle';
import { getV2Stack } from '../lib/v2';
import {
  airdropCandidates,
  claimWindowOpen,
  pickTranche,
  trancheState,
  trancheStateLabel,
  type TrancheRead,
  type TrancheView,
} from '../lib/airdropV2';

function explorerTxUrl(chainId: number, hash: `0x${string}`): string {
  const base = chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';
  return `${base}/tx/${hash}`;
}

function explorerAddrUrl(chainId: number, addr: string): string {
  const base = chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';
  return `${base}/address/${addr}`;
}

function decodeClaimError(err: unknown): string {
  if (err instanceof BaseError) {
    const reverted = err.walk(e => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? reverted.reason ?? 'Reverted';
      switch (name) {
        case 'AirdropNotUnlocked':
          return 'The airdrop is still in its lockup period.';
        case 'InvalidProof':
          return 'Merkle proof is invalid for this address.';
        case 'ZeroToClaim':
          return 'Nothing is currently claimable (still vesting or already claimed).';
        case 'UserMaxClaimed':
          return 'You have already claimed your full allocation.';
        case 'TotalMaxClaimed':
          return 'The airdrop has been fully claimed.';
        case 'ClaimWindowClosed':
          return 'The claim window has closed. Unclaimed tokens go to the sweep recipient.';
        case 'AlreadySwept':
          return 'The unclaimed remainder has already been swept.';
        case 'ZeroClaim':
          return 'The allocated amount is zero.';
        case 'AdminClaimed':
          return 'The airdrop admin has swept unclaimed tokens; claims are closed.';
        case 'AirdropNotCreated':
          return 'No airdrop exists for this token.';
        default:
          return `Reverted: ${name}`;
      }
    }
    return err.shortMessage ?? err.message;
  }
  return err instanceof Error ? err.message : String(err);
}

/** Route wrapper: a malformed address or an unsupported chain never reaches a fetch path or a chain read. */
export default function ClaimPage() {
  const { address: param } = useParams<{ address: string }>();
  const { chainId, addresses } = useAddressesOrNull();
  if (!param || !isAddress(param, { strict: false })) {
    return <div className="mx-auto max-w-3xl px-4 py-16 text-center text-zinc-500">Not a token address.</div>;
  }
  if (!addresses) {
    return <div className="mx-auto max-w-3xl px-4 py-16 text-center text-zinc-500">Switch to Ethereum mainnet.</div>;
  }
  return <ClaimRouter tokenAddress={param.toLowerCase() as Address} chainId={chainId} addresses={addresses} />;
}

/** Load the allowlist JSON for a token from /allowlists/<token>.json (same file for v1 and v2). */
function useAllowlist(tokenAddress: Address) {
  return useQuery<AllowlistFile>({
    queryKey: ['allowlist', tokenAddress],
    queryFn: async () => {
      const res = await fetch(`/allowlists/${tokenAddress}.json`);
      if (!res.ok) throw new Error(`No allowlist found (${res.status})`);
      return (await res.json()) as AllowlistFile;
    },
    retry: false,
    staleTime: 60_000,
  });
}

/**
 * v2 coins (the v2 factory says `isArtCoin`) claim from ArtCoinsAirdropV2 with a tranche index.
 * Every other token, and every chain without a configured v2 stack, keeps the v1 claim path.
 */
function ClaimRouter({ tokenAddress, chainId, addresses }: { tokenAddress: Address; chainId: number; addresses: ContractAddresses }) {
  const v2 = getV2Stack(chainId);
  const { data, isLoading } = useReadContracts({
    contracts: v2
      ? [
          { address: v2.factory, abi: factoryV2Abi, functionName: 'isArtCoin', args: [tokenAddress] } as const,
          { address: v2.factory, abi: factoryV2Abi, functionName: 'deploymentInfo', args: [tokenAddress] } as const,
        ]
      : [],
    allowFailure: true,
    query: { enabled: !!v2, staleTime: 60_000 },
  });
  if (!v2) return <ClaimV1 tokenAddress={tokenAddress} chainId={chainId} addresses={addresses} />;
  if (isLoading || !data) {
    return <div className="mx-auto max-w-3xl px-4 py-16 text-center text-zinc-500">Checking token…</div>;
  }
  const isV2 = data[0]?.status === 'success' ? (data[0].result as boolean) : undefined;
  if (isV2 === undefined) {
    return <div className="mx-auto max-w-3xl px-4 py-16 text-center text-zinc-500">Could not read the v2 factory. Reload to retry.</div>;
  }
  if (!isV2) return <ClaimV1 tokenAddress={tokenAddress} chainId={chainId} addresses={addresses} />;
  const info = data[1]?.status === 'success' ? (data[1].result as { extensions: readonly Address[] }) : undefined;
  if (!info) {
    return <div className="mx-auto max-w-3xl px-4 py-16 text-center text-zinc-500">Could not read the deployment info of this token. Reload to retry.</div>;
  }
  return (
    <ClaimV2
      tokenAddress={tokenAddress}
      chainId={chainId}
      extensions={info.extensions}
      airdropAddress={v2.airdrop === '0x0000000000000000000000000000000000000000' ? null : v2.airdrop}
    />
  );
}

function ClaimV1({ tokenAddress, chainId, addresses }: { tokenAddress: Address; chainId: number; addresses: ContractAddresses }) {
  const { address: wallet, isConnected } = useAccount();

  const {
    data: allowlist,
    isLoading: allowlistLoading,
    error: allowlistError,
  } = useAllowlist(tokenAddress);

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
  const symbol = reads?.[1]?.result as string | undefined;
  const name = reads?.[2]?.result as string | undefined;

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
  const { writeContract, data: txHash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const onClaim = () => {
    if (!wallet || !entry) return;
    reset();
    writeContract({
      address: addresses.airdrop,
      abi: airdropAbi,
      functionName: 'claim',
      args: [tokenAddress, wallet, BigInt(entry.amount), entry.proof],
    });
  };

  useEffect(() => {
    if (confirmed) {
      refetchReads();
      refetchAvailable();
    }
  }, [confirmed, refetchReads, refetchAvailable]);

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
          explorerUrl={explorerAddrUrl(chainId, tokenAddress)}
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
                <CopyableAddress address={wallet!} explorerUrl={explorerAddrUrl(chainId, wallet!)} />{' '}
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
                  explorerUrl={explorerAddrUrl(chainId, addresses.airdrop)}
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

/** v2 claim: ArtCoinsAirdropV2, tranche keyed by (token, extension index). */
function ClaimV2({
  tokenAddress,
  chainId,
  extensions,
  airdropAddress,
}: {
  tokenAddress: Address;
  chainId: number;
  extensions: readonly Address[];
  airdropAddress: Address | null;
}) {
  const { address: wallet, isConnected } = useAccount();
  const { data: allowlist, isLoading: allowlistLoading, error: allowlistError } = useAllowlist(tokenAddress);

  const entry = useMemo(() => {
    if (!allowlist || !wallet) return null;
    return findEntry(allowlist, wallet);
  }, [allowlist, wallet]);

  const proofVerified = useMemo(() => {
    if (!allowlist || !entry || !wallet) return false;
    return verifyProof(allowlist.root, wallet, entry.amount, entry.proof);
  }, [allowlist, entry, wallet]);

  // One tranche read per candidate extension entry; a non airdrop extension has no `tranche()` and fails.
  const candidates = useMemo(() => airdropCandidates(extensions, airdropAddress), [extensions, airdropAddress]);
  const { data: reads, refetch: refetchReads } = useReadContracts({
    contracts: [
      ...candidates.map(
        c =>
          ({
            address: c.extension,
            abi: airdropV2Abi,
            functionName: 'tranche',
            args: [tokenAddress, BigInt(c.index)],
          }) as const
      ),
      { address: tokenAddress, abi: tokenAbi, functionName: 'symbol' } as const,
      { address: tokenAddress, abi: tokenAbi, functionName: 'name' } as const,
    ],
    allowFailure: true,
    query: { refetchInterval: 15_000 },
  });

  const trancheReads: TrancheRead[] = useMemo(() => {
    const out: TrancheRead[] = [];
    candidates.forEach((c, i) => {
      const r = reads?.[i];
      if (r?.status === 'success') out.push({ ...c, tranche: r.result as TrancheView });
    });
    return out;
  }, [candidates, reads]);
  const symbol = reads?.[candidates.length]?.result as string | undefined;
  const name = reads?.[candidates.length + 1]?.result as string | undefined;

  const picked = useMemo(
    () => pickTranche(trancheReads, allowlist?.root, allowlist?.index),
    [trancheReads, allowlist]
  );
  const tranche = picked?.tranche;
  const airdropContract = picked?.extension;
  const trancheIndex = picked ? BigInt(picked.index) : undefined;

  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const state = tranche ? trancheState(tranche, nowSec) : 'none';
  const open = claimWindowOpen(state);

  const rootMismatch =
    !!allowlist && !!tranche && tranche.merkleRoot.toLowerCase() !== allowlist.root.toLowerCase();

  const perWallet = !!wallet && !!entry && !!airdropContract && trancheIndex !== undefined;
  const { data: walletReads, refetch: refetchWallet } = useReadContracts({
    contracts: perWallet
      ? [
          {
            address: airdropContract,
            abi: airdropV2Abi,
            functionName: 'amountAvailableToClaim',
            args: [tokenAddress, trancheIndex, wallet, BigInt(entry.amount)],
          } as const,
          {
            address: airdropContract,
            abi: airdropV2Abi,
            functionName: 'leafClaimed',
            args: [tokenAddress, trancheIndex, wallet, BigInt(entry.amount)],
          } as const,
        ]
      : [],
    allowFailure: true,
    query: { enabled: perWallet, refetchInterval: 15_000 },
  });
  const available = walletReads?.[0]?.result as bigint | undefined;
  const claimedByYou = walletReads?.[1]?.result as bigint | undefined;

  const { writeContract, data: txHash, isPending, error: writeError, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess: confirmed } = useWaitForTransactionReceipt({ hash: txHash });

  const onClaim = () => {
    if (!wallet || !entry || !airdropContract || trancheIndex === undefined) return;
    reset();
    writeContract({
      address: airdropContract,
      abi: airdropV2Abi,
      functionName: 'claim',
      args: [tokenAddress, trancheIndex, wallet, BigInt(entry.amount), entry.proof],
    });
  };

  useEffect(() => {
    if (confirmed) {
      refetchReads();
      refetchWallet();
    }
  }, [confirmed, refetchReads, refetchWallet]);

  const unit = symbol ?? '';

  return (
    <main className="mx-auto max-w-3xl px-4 py-8 space-y-6">
      <div className="text-sm text-zinc-500">
        <Link to={`/tokens/${tokenAddress}`} className="hover:text-zinc-300">
          ← Back to token
        </Link>
      </div>

      <div>
        <h1 className="text-2xl font-bold">
          Claim airdrop {symbol && <span className="text-zinc-500 font-normal">({name ?? symbol})</span>}
        </h1>
        <CopyableAddress
          address={tokenAddress}
          explorerUrl={explorerAddrUrl(chainId, tokenAddress)}
          className="mt-1 text-zinc-400"
        />
      </div>

      {allowlistLoading ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-sm text-zinc-500">Loading allowlist…</div>
      ) : allowlistError || !allowlist ? (
        <div className="rounded-xl border border-amber-700/40 bg-amber-950/20 p-6 text-sm text-amber-200">
          <p className="font-medium mb-1">No allowlist found</p>
          <p className="text-amber-200/70">
            Could not load <code className="font-mono text-xs">/allowlists/{tokenAddress}.json</code>. Generate it
            with <code className="font-mono text-xs">script-js/build-allowlist.ts</code> and place the resulting file
            in <code className="font-mono text-xs">ui/public/allowlists/</code>.
          </p>
        </div>
      ) : !tranche ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-sm text-zinc-400">
          This token has no airdrop tranche on the v2 airdrop contract.
        </div>
      ) : rootMismatch ? (
        <div className="rounded-xl border border-red-700/40 bg-red-950/20 p-6 text-sm text-red-200">
          <p className="font-medium mb-1">Allowlist does not match the on-chain root</p>
          <p className="text-red-200/70 break-all">
            Local root: <span className="font-mono">{allowlist.root}</span>
            <br />
            On-chain root (tranche {String(trancheIndex)}): <span className="font-mono">{tranche.merkleRoot}</span>
          </p>
        </div>
      ) : null}

      {!isConnected && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 flex flex-col items-start gap-3">
          <p className="text-sm text-zinc-300">Connect a wallet to check eligibility.</p>
          <ConnectButton />
        </div>
      )}

      {isConnected && allowlist && tranche && !rootMismatch && (
        <div className="space-y-4">
          {!entry ? (
            <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-sm">
              <p className="font-medium text-white mb-1">Not eligible</p>
              <p className="text-zinc-400">
                The connected address{' '}
                <CopyableAddress address={wallet!} explorerUrl={explorerAddrUrl(chainId, wallet!)} /> is not in the
                allowlist for this token.
              </p>
            </div>
          ) : !proofVerified ? (
            <div className="rounded-xl border border-red-700/40 bg-red-950/20 p-6 text-sm text-red-200">
              <p className="font-medium mb-1">Proof verification failed locally</p>
              <p className="text-red-200/70">
                The proof for your address does not verify against the root. The allowlist JSON may be corrupt,
                regenerate it.
              </p>
            </div>
          ) : (
            <InfoCard title="Your allocation">
              <InfoRow label="Allocated" value={`${formatSupply(BigInt(entry.amount))} ${unit}`} />
              <InfoRow
                label="Already claimed"
                value={claimedByYou !== undefined ? `${formatSupply(claimedByYou)} ${unit}` : '…'}
              />
              <InfoRow
                label="Available to claim now"
                value={
                  available !== undefined ? (
                    <span className="font-medium text-violet-300">
                      {formatSupply(available)} {unit}
                    </span>
                  ) : (
                    '…'
                  )
                }
              />
              <InfoRow label="Status" value={trancheStateLabel(state, tranche, formatTimestamp)} />

              <div className="pt-4">
                <button
                  type="button"
                  onClick={onClaim}
                  disabled={!open || (available !== undefined && available === 0n) || isPending || confirming}
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
                {writeError && <p className="mt-3 text-xs text-red-300">{decodeClaimError(writeError)}</p>}
              </div>
            </InfoCard>
          )}

          <InfoCard title="Airdrop state">
            {airdropContract && (
              <InfoRow
                label="Contract"
                value={<CopyableAddress address={airdropContract} explorerUrl={explorerAddrUrl(chainId, airdropContract)} />}
              />
            )}
            <InfoRow label="Tranche index" value={String(trancheIndex)} />
            <InfoRow label="Merkle root" value={<span className="font-mono text-xs break-all">{tranche.merkleRoot}</span>} />
            <InfoRow label="Total supply" value={`${formatSupply(tranche.supply)} ${unit}`} />
            <InfoRow label="Total claimed" value={`${formatSupply(tranche.totalClaimed)} ${unit}`} />
            <InfoRow label="Lockup ends" value={formatTimestamp(tranche.lockupEnd)} />
            <InfoRow label="Vesting ends" value={formatTimestamp(tranche.vestingEnd)} />
            <InfoRow label="Claim window closes" value={formatTimestamp(tranche.sweepTime)} />
            <InfoRow
              label="Sweep"
              value={
                tranche.swept
                  ? 'swept'
                  : state === 'closed'
                  ? 'due, anyone can sweep the unclaimed remainder'
                  : 'not due'
              }
            />
            <InfoRow
              label="Sweep recipient"
              value={<CopyableAddress address={tranche.sweepRecipient} explorerUrl={explorerAddrUrl(chainId, tranche.sweepRecipient)} />}
            />
          </InfoCard>
        </div>
      )}
    </main>
  );
}
