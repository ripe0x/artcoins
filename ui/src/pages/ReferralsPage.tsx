import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import {
  useAccount,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { ConnectButton } from '@rainbow-me/rainbowkit';
import {
  BaseError,
  ContractFunctionRevertedError,
  formatEther,
} from 'viem';

import EscrowClaim from '../components/EscrowClaim';
import InfoCard from '../components/InfoCard';
import InfoRow from '../components/InfoRow';
import CopyableAddress from '../components/CopyableAddress';
import { referralPayoutAbi } from '../lib/abi';
import { hookV1Abi } from '../lib/abi/v1/hook';
import { hookV2Abi } from '../lib/abi/v2/hook';
import { factoryV2Abi } from '../lib/abi/v2/factory';
import { ZERO_ADDRESS } from '../lib/constants';
import { shortAddr } from '../lib/format';
import { normalizeSkim, skimPercent } from '../lib/poolReads';
import { useToken } from '../lib/useTokens';
import { getV2Stack } from '../lib/v2';
import { useAddressesOrNull, useWalletGate } from '../lib/useChain';
import { cleanText, MAX_SYMBOL } from '../lib/security';

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
  const { address: param } = useParams<{ address: string }>();
  const { chainId } = useAddressesOrNull();
  const { address: wallet, isConnected } = useAccount();
  const gate = useWalletGate();
  const { token: event, validAddress, isLoading: eventsLoading } = useToken(param);

  // 1. the pool id the token announced at launch
  const poolId = event?.poolId;

  // 2. the hook's per pool fee config names the ReferralPayout holding referrer balances. v1 returns
  //    8 values, v2 a struct, normalizeSkim reads both. The deployer of a v1 coin chooses this address.
  const { data: skimRaw, isLoading: skimLoading } = useReadContract({
    address: event?.hook,
    abi: event?.version === 2 ? hookV2Abi : hookV1Abi,
    functionName: 'skimConfig',
    args: poolId ? [poolId] : undefined,
    query: { enabled: !!poolId && !!event },
  });
  const skim = normalizeSkim(skimRaw);
  const maxReferralBps = skim?.maxReferralBpsOfVolume;

  // v2: referral fees the hook could not push sit in the pool's fee escrow, named by the factory's
  // deploymentInfo. v1: the deployer supplied the ledger address in the hook's skim config.
  const { data: info } = useReadContract({
    address: event?.factory,
    abi: factoryV2Abi,
    functionName: 'deploymentInfo',
    args: event ? [event.token] : undefined,
    query: { enabled: event?.version === 2 },
  });
  const poolEscrow = info?.escrow;
  const v2Escrow = poolEscrow && poolEscrow !== ZERO_ADDRESS ? poolEscrow : getV2Stack(chainId)?.escrow;
  const referralPayoutAddr = event?.version === 2 ? v2Escrow : skim?.referralPayout;
  const isEscrow = event?.version === 2 && !!v2Escrow && v2Escrow !== ZERO_ADDRESS;
  const payoutTrusted = isEscrow;
  const [payoutConfirmed, setPayoutConfirmed] = useState(false);

  // 3. the connected wallet's balance on that ledger
  const { data: balanceData, refetch: refetchBalances } = useReadContracts({
    contracts:
      wallet && referralPayoutAddr
        ? [{ address: referralPayoutAddr, abi: referralPayoutAbi, functionName: 'balances' as const, args: [wallet] as const }]
        : [],
    query: { enabled: !!wallet && !!referralPayoutAddr },
  });
  const ledgerBalance = balanceData?.[0]?.status === 'success' ? (balanceData[0].result as bigint) : 0n;

  // 4. claim write path
  const { writeContractAsync } = useWriteContract();
  const [tx, setTx] = useState<TxState>({ kind: 'idle' });
  const waitFor = tx.kind === 'pending' ? tx.hash : undefined;
  const { data: claimReceipt } = useWaitForTransactionReceipt({ hash: waitFor, query: { enabled: !!waitFor } });
  // the state follows the receipt: a reverted claim is an error, never "confirmed"
  useEffect(() => {
    if (tx.kind !== 'pending' || !claimReceipt) return;
    if (claimReceipt.status === 'success') {
      void refetchBalances();
      setTx({ kind: 'confirmed', hash: tx.hash });
    } else {
      setTx({ kind: 'error', message: 'The claim transaction reverted. Nothing was paid.' });
    }
  }, [claimReceipt, tx, refetchBalances]);

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

  if (!validAddress || !event) {
    return (
      <div className="mx-auto max-w-3xl px-4 py-12 text-center">
        <p className="text-zinc-400">{validAddress ? 'Token not found.' : 'Not a token address.'}</p>
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
          to={`/tokens/${event.token}`}
          className="text-sm text-zinc-400 hover:text-zinc-200"
        >
          ← {cleanText(event.symbol, MAX_SYMBOL)}
        </Link>
        <h1 className="mt-2 text-3xl font-bold text-zinc-100">Referral earnings</h1>
        <p className="mt-2 text-sm text-zinc-400">
          Anyone can route swaps through this pool with an attribution{' '}
          <code className="text-xs">hookData</code> payload naming a referrer
          address. The hook routes up to{' '}
          {maxReferralBps !== undefined ? (
            <strong className="text-zinc-200">
              {skimPercent(maxReferralBps, skim?.denominator).toFixed(2)}%
            </strong>
          ) : (
            '...'
          )}{' '}
          of swap volume to that address, pulled exclusively from the protocol
          fee leg. The protocol still keeps at least the floor the factory set
          for the launch, so a referral never takes the whole protocol share.
          URL parameter <code className="text-xs">?ref=0x...</code> on
          the swap page sets the referrer; or build your own UI and pass{' '}
          <Link to="/" className="text-violet-300 hover:text-violet-200">
            attribution hookData
          </Link>{' '}
          directly.
        </p>
      </div>

      {isEscrow && referralPayoutAddr ? (
        <EscrowClaim escrow={referralPayoutAddr} chainId={chainId} />
      ) : (
        <>
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
        </InfoCard>

        {referralPayoutAddr && !payoutTrusted && (
          <label className="flex items-start gap-2 rounded-xl border border-amber-800 bg-amber-950/20 p-3 text-xs text-amber-200">
            <input type="checkbox" checked={payoutConfirmed} onChange={(e) => setPayoutConfirmed(e.target.checked)} className="mt-0.5" />
            <span>
              The ledger at <span className="font-mono">{referralPayoutAddr}</span> was chosen by this token's deployer, not by the
              factory. Confirm you recognise it before claiming.
            </span>
          </label>
        )}
        {payoutTrusted && <p className="text-xs text-emerald-300">This is the payout contract the factory itself wired in.</p>}

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
              disabled={
                !gate.ok ||
                ledgerBalance === 0n ||
                (!payoutTrusted && !payoutConfirmed) ||
                tx.kind === 'awaitingSig' ||
                tx.kind === 'pending'
              }
              className="flex-1 rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 hover:bg-violet-900/30 disabled:opacity-50 disabled:cursor-not-allowed px-5 py-3 text-sm font-medium text-violet-200 hover:text-white"
            >
              {tx.kind === 'awaitingSig'
                ? 'Confirm in wallet...'
                : tx.kind === 'pending'
                  ? 'Claiming...'
                  : `Claim ${formatEther(ledgerBalance)} ETH`}
            </button>
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
        </>
      )}
    </div>
  );
}
