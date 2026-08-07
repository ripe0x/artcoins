import { useCallback, useMemo } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useAccount, useChainId, useReadContracts } from 'wagmi';
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
import { skimHookAbi, referralPayoutAbi } from '../lib/abi';
import { useTokenEvent } from '../lib/useTokenEvent';
import { useTxFlow } from '../lib/useTxFlow';
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

export default function ReferralsPage() {
  const { address: tokenAddressParam } = useParams<{ address: string }>();
  const tokenAddress = (tokenAddressParam ?? '').toLowerCase() as Address;
  const chainId = useChainId();
  const { address: wallet, isConnected } = useAccount();

  // 1. Find the TokenCreated event; poolId comes straight from the event
  // (it's the authoritative on-chain value — no need to re-derive it via
  // tickSpacing resolution, which can fail to match and would otherwise
  // silently produce a poolId that doesn't correspond to the real pool).
  const { event, poolId, isLoading: eventsLoading } = useTokenEvent(tokenAddress);

  // 2. Read the hook's skimConfig to discover the per-pool ReferralPayout.
  const { data: skimConfig, isLoading: skimLoading } = useReadContracts({
    contracts:
      poolId && event
        ? [
            {
              address: event.poolHook as Address,
              abi: skimHookAbi,
              functionName: 'skimConfig',
              args: [poolId],
            },
          ]
        : [],
    query: { enabled: !!poolId && !!event },
  });

  // skimConfig() returns (baselineSkimBps, bountyBps, maxReferralBpsOfVolume,
  // lpFee, bountyRecipient, protocolRecipient, referralPayout, quoteToken).
  const cfg =
    skimConfig?.[0]?.status === 'success' ? skimConfig[0].result : undefined;
  const maxReferralBps = cfg?.[2]; // maxReferralBpsOfVolume
  const referralPayoutAddr = cfg?.[6]; // referralPayout

  // 3. Read the connected wallet's balance + hook-accrued (in-tx) amount.
  // Note: the current hook has no "held" balance or external flush/retry
  // path — a failed forward to ReferralPayout folds into the protocol leg
  // automatically inside `_afterSwap` (see `ReferralFoldedToProtocol`), so
  // there is nothing here for the user to manually retry.
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
        abi: skimHookAbi,
        functionName: 'accruedReferral' as const,
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

  // 4. Claim write path. Balances only refresh once the receipt actually
  // lands (`onConfirmed`) — never on a timer, since mainnet blocks are
  // ~12s and a fixed-delay refetch can read pre-transaction state.
  const onConfirmed = useCallback(() => {
    refetchBalances();
  }, [refetchBalances]);

  const { submit, status, hash: txHash, error: txError, reset } = useTxFlow({ onConfirmed });

  const onClaim = () => {
    if (!referralPayoutAddr) return;
    reset();
    submit({
      address: referralPayoutAddr,
      abi: referralPayoutAbi,
      functionName: 'claim',
      args: [],
    });
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
              {(Number(maxReferralBps) / 100).toFixed(2)}%
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
            disabled={ledgerBalance === 0n || status === 'confirming' || status === 'pending'}
            className="flex-1 rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 hover:bg-violet-900/30 disabled:opacity-50 disabled:cursor-not-allowed px-5 py-3 text-sm font-medium text-violet-200 hover:text-white"
          >
            {status === 'confirming'
              ? 'Confirm in wallet...'
              : status === 'pending'
                ? 'Claiming...'
                : `Claim ${formatEther(ledgerBalance)} ETH`}
          </button>
        </div>
      )}

      {status === 'pending' && txHash && (
        <p className="text-xs text-zinc-500">
          Tx pending —{' '}
          <a
            href={explorerTxUrl(chainId, txHash)}
            target="_blank"
            rel="noreferrer"
            className="text-violet-300 hover:text-violet-200"
          >
            {shortAddr(txHash)}
          </a>
        </p>
      )}
      {status === 'confirmed' && txHash && (
        <p className="text-xs text-emerald-300">
          Confirmed —{' '}
          <a
            href={explorerTxUrl(chainId, txHash)}
            target="_blank"
            rel="noreferrer"
            className="text-emerald-200 hover:text-emerald-100"
          >
            {shortAddr(txHash)}
          </a>
        </p>
      )}
      {status === 'error' && txError && (
        <p className="text-xs text-red-400">{decodeClaimError(txError)}</p>
      )}
    </div>
  );
}
