import { useState } from 'react';
import { useReadContracts, usePublicClient, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { formatEther, type Address } from 'viem';
import { escrowV2Abi } from '../lib/abi/v2/escrow';
import { ZERO_ADDRESS } from '../lib/constants';
import { parseAddress } from '../lib/encodeV2';
import { escrowClaimBlock, escrowClaimCall } from '../lib/escrowClaim';
import { describeError } from '../lib/errors';
import { shortAddr } from '../lib/format';
import { useWalletGate } from '../lib/useChain';
import CopyableAddress from './CopyableAddress';
import InfoCard from './InfoCard';
import InfoRow from './InfoRow';
import { inputClass } from './formStyles';

/** Claim panel for referral earnings held in the v2 fee escrow. Anyone may trigger a claim, the eth goes to the referrer. */
export default function EscrowClaim({ escrow, chainId }: { escrow: Address; chainId: number }) {
  const gate = useWalletGate();
  const client = usePublicClient();
  const [typed, setTyped] = useState('');
  // default: the connected wallet. A typed address claims for someone else (their eth goes to them).
  const referrer: Address | null = typed.trim() ? parseAddress(typed) : (gate.address ?? null);
  const typedInvalid = !!typed.trim() && !referrer;

  const { data, refetch } = useReadContracts({
    contracts: referrer
      ? [
          { address: escrow, abi: escrowV2Abi, functionName: 'balances' as const, args: [referrer, ZERO_ADDRESS] as const },
          { address: escrow, abi: escrowV2Abi, functionName: 'selfClaimOnly' as const, args: [referrer] as const },
        ]
      : [],
    query: { enabled: !!referrer, refetchInterval: 30_000 },
  });
  const balance = data?.[0]?.status === 'success' ? (data[0].result as bigint) : 0n;
  const selfOnly = data?.[1]?.status === 'success' ? (data[1].result as boolean) : false;
  const readFailed = !!referrer && !!data && data.some((d) => d.status !== 'success');

  const { writeContractAsync, data: hash, isPending, reset } = useWriteContract();
  const { data: receipt, isLoading: confirming } = useWaitForTransactionReceipt({ hash });
  const [error, setError] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);

  const block = referrer ? escrowClaimBlock({ balance, selfClaimOnly: selfOnly, caller: gate.address, referrer }) : null;
  const done = receipt?.status === 'success';
  const reverted = receipt?.status === 'reverted';

  const onClaim = async () => {
    if (!referrer || !client || !gate.address) return;
    setError(null);
    setChecking(true);
    try {
      // simulate first: a revert is shown with its reason and nothing is signed
      const sim = await client.simulateContract({ account: gate.address, ...escrowClaimCall(escrow, referrer) });
      await writeContractAsync(sim.request);
      void refetch();
    } catch (e) {
      setError(describeError(e));
    } finally {
      setChecking(false);
    }
  };

  const explorer = chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';

  return (
    <div className="space-y-4">
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-4 text-sm text-zinc-300 space-y-2">
        <p className="font-medium text-zinc-100">Referral earnings are claimed from the fee escrow</p>
        <p>
          On this coin the hook does not send referral fees to a wallet. It credits the referrer in the fee escrow, as ETH. The claim is{' '}
          <code className="text-xs">claim(referrer, address(0))</code> on the escrow, and anyone may send it: the ETH always goes to the referrer. A
          referrer that wants only itself to trigger claims can turn on self claim only, and can use <code className="text-xs">claimTo</code> to send its
          balance to another address.
        </p>
        <p className="text-xs text-zinc-500">The balance is everything credited to that address in the escrow, across every coin that uses it (it also holds any lp fee push that failed).</p>
      </div>

      <InfoCard title="Escrow balance">
        <InfoRow label="Fee escrow" value={<CopyableAddress address={escrow} />} />
        <InfoRow label="Referrer" value={referrer ? <CopyableAddress address={referrer} /> : <span className="text-zinc-500">connect a wallet or enter an address</span>} />
        <InfoRow label="Claimable (ETH)" value={<span className="font-mono text-zinc-100">{formatEther(balance)} ETH</span>} />
        {selfOnly && <InfoRow label="Self claim only" value={<span className="text-amber-300">on</span>} />}
      </InfoCard>

      <label className="block text-xs text-zinc-500">
        Claim for another referrer (optional, leave empty for your wallet)
        <input
          type="text"
          className={`${inputClass} mt-1`}
          placeholder="0x..."
          value={typed}
          onChange={(e) => {
            setTyped(e.target.value);
            setError(null);
            reset();
          }}
        />
      </label>
      {typedInvalid && <p className="text-xs text-red-400">Not a valid address (check the checksum).</p>}
      {readFailed && <p className="text-xs text-red-400">Could not read the escrow. Try again.</p>}

      <button
        type="button"
        onClick={() => void onClaim()}
        disabled={!gate.ok || !referrer || !!block || readFailed || isPending || confirming || checking}
        className="w-full rounded-xl border border-violet-600/40 bg-violet-950/20 hover:border-violet-500 hover:bg-violet-900/30 disabled:opacity-50 disabled:cursor-not-allowed px-5 py-3 text-sm font-medium text-violet-200 hover:text-white"
      >
        {isPending ? 'Confirm in wallet...' : confirming ? 'Claiming...' : checking ? 'Checking the claim...' : `Claim ${formatEther(balance)} ETH`}
      </button>
      {!gate.ok && gate.reason && (
        <p className="text-xs text-amber-400">
          {gate.reason}.{' '}
          {gate.needsSwitch && (
            <button type="button" className="underline" onClick={gate.switchToMainnet}>
              Switch
            </button>
          )}
        </p>
      )}
      {gate.ok && block && <p className="text-xs text-zinc-500">{block}</p>}
      {error && <p className="text-xs text-red-400 break-words">{error}</p>}
      {hash && confirming && (
        <p className="text-xs text-zinc-500">
          Pending:{' '}
          <a href={`${explorer}/tx/${hash}`} target="_blank" rel="noreferrer" className="text-violet-300 hover:text-violet-200">
            {shortAddr(hash)}
          </a>
        </p>
      )}
      {done && hash && (
        <p className="text-xs text-emerald-300">
          Claimed:{' '}
          <a href={`${explorer}/tx/${hash}`} target="_blank" rel="noreferrer" className="text-emerald-200 hover:text-emerald-100">
            {shortAddr(hash)}
          </a>
        </p>
      )}
      {reverted && <p className="text-xs text-red-400">The claim transaction reverted. Nothing was paid.</p>}
    </div>
  );
}
