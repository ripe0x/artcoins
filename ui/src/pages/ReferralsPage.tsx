import { useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  useAccount,
  useChainId,
  usePublicClient,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { useQuery } from '@tanstack/react-query';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import {
  BaseError,
  ContractFunctionRevertedError,
  formatEther,
  type Address,
} from 'viem';

import InfoCard from '../components/InfoCard';
import InfoRow from '../components/InfoRow';
import CopyableAddress from '../components/CopyableAddress';
import { getAddresses, getFactoryDeploymentBlock } from '../lib/config';
import { hookAbi, referralPayoutAbi } from '../lib/abi';
import { fetchAllTokenCreatedEvents } from '../lib/events';
import { buildPoolKey, computePoolId, resolveTickSpacing } from '../lib/pool';
import { shortAddr } from '../lib/format';

function explorerTxUrl(chainId: number, hash: `0x${string}`): string {
  const base = chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';
  return `${base}/tx/${hash}`;
}

function decodeClaimError(err: unknown): string {
  if (err instanceof BaseError) {
    const reverted = err.walk(e => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? reverted.reason ?? 'Reverted';
      switch (name) {
        case 'NothingToClaim':
          return 'No balance to claim — your wallet has no accrued referral fees for this pool yet.';
        case 'TransferFailed':
          return 'Claim transfer reverted. Your balance has been reinstated; try again or check whether your address is contract-restricted.';
        default:
          return `Reverted: ${name}`;
      }
    }
    return err.shortMessage ?? err.message;
  }
  return err instanceof Error ? err.message : String(err);
}

type TxState =
  | { kind: 'idle' }
  | { kind: 'awaitingSig' }
  | { kind: 'pending'; hash: `0x${string}` }
  | { kind: 'confirmed'; hash: `0x${string}` }
  | { kind: 'error'; message: string };

export default function ReferralsPage() {
  const { address: tokenAddressParam } = useParams<{ address: string }>();
  const tokenAddress = (tokenAddressParam ?? '').toLowerCase() as Address;
  const chainId = useChainId();
  const client = usePublicClient();
  const { address: wallet, isConnected } = useAccount();
  const addresses = getAddresses(chainId);

  // 1. Find the TokenCreated event so we can build the poolKey + poolId.
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

  const event = useMemo(
    () => allEvents?.find(e => e.tokenAddress.toLowerCase() === tokenAddress),
    [allEvents, tokenAddress]
  );

  const { poolKey, poolId } = useMemo(() => {
    if (!event) return { poolKey: null, poolId: null };
    const ts = resolveTickSpacing(
      event.tokenAddress,
      event.pairedToken,
      event.poolHook,
      event.poolId
    );
    const key = buildPoolKey(event.tokenAddress, event.pairedToken, ts, event.poolHook);
    return { poolKey: key, poolId: computePoolId(key) };
  }, [event]);

  // 2. Read the hook's skimConfig to discover the per-pool ReferralPayout.
  const { data: skimConfig, isLoading: skimLoading } = useReadContracts({
    contracts:
      poolId && event
        ? [
            {
              address: event.poolHook as Address,
              abi: hookAbi,
              functionName: 'skimConfig',
              args: [poolId],
            },
          ]
        : [],
    query: { enabled: !!poolId && !!event },
  });

  const referralPayoutAddr =
    skimConfig?.[0]?.status === 'success'
      ? (skimConfig[0].result as readonly [
          number, number, number, number, number,
          Address, Address, Address, Address, Address, Address, Address,
        ])[9]
      : undefined;
  const maxReferralBps =
    skimConfig?.[0]?.status === 'success'
      ? (skimConfig[0].result as readonly [
          number, number, number, number, number,
          Address, Address, Address, Address, Address, Address, Address,
        ])[3]
      : undefined;

  // 3. Read the connected wallet's balance + hook-held + hook-accrued amounts.
  const balanceContracts = useMemo(() => {
    if (!wallet || !referralPayoutAddr || !poolId || !event) return [];
    return [
      {
        address: referralPayoutAddr,
        abi: referralPayoutAbi,
        functionName: 'balances' as const,
        args: [wallet] as const,
      },
      {
        address: event.poolHook as Address,
        abi: hookAbi,
        functionName: 'accruedReferral' as const,
        args: [poolId, wallet] as const,
      },
      {
        address: event.poolHook as Address,
        abi: hookAbi,
        functionName: 'heldReferral' as const,
        args: [poolId, wallet] as const,
      },
    ];
  }, [wallet, referralPayoutAddr, poolId, event]);

  const { data: balanceData, refetch: refetchBalances } = useReadContracts({
    contracts: balanceContracts,
    query: { enabled: balanceContracts.length > 0 },
  });

  const ledgerBalance =
    balanceData?.[0]?.status === 'success' ? (balanceData[0].result as bigint) : 0n;
  const hookAccrued =
    balanceData?.[1]?.status === 'success' ? (balanceData[1].result as bigint) : 0n;
  const hookHeld =
    balanceData?.[2]?.status === 'success' ? (balanceData[2].result as bigint) : 0n;

  // 4. Claim + flush write paths.
  const { writeContractAsync } = useWriteContract();
  const [tx, setTx] = useState<TxState>({ kind: 'idle' });
  const waitFor =
    tx.kind === 'pending' || tx.kind === 'confirmed' ? (tx.hash as `0x${string}`) : undefined;
  useWaitForTransactionReceipt({ hash: waitFor, query: { enabled: !!waitFor } });

  const onClaim = async () => {
    if (!referralPayoutAddr) return;
    setTx({ kind: 'awaitingSig' });
    try {
      const hash = await writeContractAsync({
        address: referralPayoutAddr,
        abi: referralPayoutAbi,
        functionName: 'claim',
        args: [],
      });
      setTx({ kind: 'pending', hash });
      // Background-refetch after the tx lands. wagmi's
      // useWaitForTransactionReceipt above will mark it confirmed; we
      // just trigger the re-read here.
      setTimeout(() => {
        refetchBalances();
        setTx({ kind: 'confirmed', hash });
      }, 1500);
    } catch (e) {
      setTx({ kind: 'error', message: decodeClaimError(e) });
    }
  };

  const onFlush = async () => {
    if (!poolKey || !wallet || !event) return;
    setTx({ kind: 'awaitingSig' });
    try {
      const hash = await writeContractAsync({
        address: event.poolHook as Address,
        abi: hookAbi,
        functionName: 'flushReferral',
        args: [poolKey, wallet],
      });
      setTx({ kind: 'pending', hash });
      setTimeout(() => {
        refetchBalances();
        setTx({ kind: 'confirmed', hash });
      }, 1500);
    } catch (e) {
      setTx({ kind: 'error', message: decodeClaimError(e) });
    }
  };

  // 5. UI
  if (eventsLoading || skimLoading) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-12">
        <div className="h-40 rounded-xl bg-zinc-900 border border-zinc-800 animate-pulse" />
      </div>
    );
  }

  if (!event) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-12 text-center">
        <p className="text-zinc-400">Token not found.</p>
        <Link to="/tokens" className="mt-4 inline-block text-violet-300 hover:text-violet-200">
          ← All tokens
        </Link>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-3xl px-4 py-12 space-y-6">
      <div>
        <Link
          to={`/tokens/${event.tokenAddress}`}
          className="text-sm text-zinc-400 hover:text-zinc-200"
        >
          ← {event.tokenSymbol}
        </Link>
        <h1 className="mt-2 text-3xl font-bold text-zinc-100">Referral earnings</h1>
        <p className="mt-2 text-sm text-zinc-400">
          Anyone can route swaps through this pool with an attribution{' '}
          <code className="text-xs">hookData</code> payload naming a referrer
          address. The hook routes up to{' '}
          {maxReferralBps !== undefined ? (
            <strong className="text-zinc-200">
              {(Number(maxReferralBps) / 1000).toFixed(2)}%
            </strong>
          ) : (
            '...'
          )}{' '}
          of swap volume to that address, pulled exclusively from the protocol
          fee leg. URL parameter <code className="text-xs">?ref=0x...</code> on
          the swap page sets the referrer; or build your own UI and pass{' '}
          <Link to="/" className="text-violet-300 hover:text-violet-200">
            attribution hookData
          </Link>{' '}
          directly.
        </p>
      </div>

      <InfoCard title="Your balance">
        <InfoRow
          label="Pool ReferralPayout"
          value={
            referralPayoutAddr ? (
              <CopyableAddress address={referralPayoutAddr} />
            ) : (
              <span className="text-zinc-500">unknown</span>
            )
          }
        />
        {wallet && (
          <InfoRow
            label="Your address"
            value={<CopyableAddress address={wallet} />}
          />
        )}
        <InfoRow
          label="Claimable balance"
          value={
            <span className="font-mono text-zinc-100">
              {formatEther(ledgerBalance)} ETH
            </span>
          }
        />
        {hookHeld > 0n && (
          <InfoRow
            label="Held on hook"
            value={
              <span className="font-mono text-amber-300" title="A prior forward failed. Use Flush to retry.">
                {formatEther(hookHeld)} ETH
              </span>
            }
          />
        )}
        {hookAccrued > 0n && (
          <InfoRow
            label="Accrued (in-tx, rare)"
            value={
              <span className="font-mono text-zinc-400">
                {formatEther(hookAccrued)} ETH
              </span>
            }
          />
        )}
      </InfoCard>

      {!isConnected ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 flex items-center justify-between">
          <p className="text-sm text-zinc-400">
            Connect to view your balance and claim.
          </p>
          <ConnectButton />
        </div>
      ) : (
        <div className="flex flex-col gap-3 sm:flex-row">
          <button
            type="button"
            onClick={onClaim}
            disabled={ledgerBalance === 0n || tx.kind === 'awaitingSig' || tx.kind === 'pending'}
            className="flex-1 rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 hover:bg-violet-900/30 disabled:opacity-50 disabled:cursor-not-allowed px-5 py-3 text-sm font-medium text-violet-200 hover:text-white"
          >
            {tx.kind === 'awaitingSig'
              ? 'Confirm in wallet...'
              : tx.kind === 'pending'
                ? 'Claiming...'
                : `Claim ${formatEther(ledgerBalance)} ETH`}
          </button>
          {hookHeld > 0n && (
            <button
              type="button"
              onClick={onFlush}
              disabled={tx.kind === 'awaitingSig' || tx.kind === 'pending'}
              className="rounded-xl border border-amber-600/40 bg-amber-950/20 hover:border-amber-500 hover:bg-amber-900/30 disabled:opacity-50 disabled:cursor-not-allowed px-5 py-3 text-sm font-medium text-amber-200 hover:text-white"
              title="A prior forward failed. Flush retries it via the hook, then the balance will appear in ReferralPayout."
            >
              Flush held → ledger
            </button>
          )}
        </div>
      )}

      {tx.kind === 'pending' && (
        <p className="text-xs text-zinc-500">
          Tx pending —{' '}
          <a
            href={explorerTxUrl(chainId, tx.hash)}
            target="_blank"
            rel="noreferrer"
            className="text-violet-300 hover:text-violet-200"
          >
            {shortAddr(tx.hash)}
          </a>
        </p>
      )}
      {tx.kind === 'confirmed' && (
        <p className="text-xs text-emerald-300">
          Confirmed —{' '}
          <a
            href={explorerTxUrl(chainId, tx.hash)}
            target="_blank"
            rel="noreferrer"
            className="text-emerald-200 hover:text-emerald-100"
          >
            {shortAddr(tx.hash)}
          </a>
        </p>
      )}
      {tx.kind === 'error' && (
        <p className="text-xs text-red-400">{tx.message}</p>
      )}
    </div>
  );
}
