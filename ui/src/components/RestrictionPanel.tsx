import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { usePublicClient, useReadContracts, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { parseAbiItem, type Address } from 'viem';
import { tokenV2Abi } from '../lib/abi/v2/token';
import { parseAddress } from '../lib/encodeV2';
import { describeError } from '../lib/errors';
import { foldAllowed } from '../lib/launchRules';
import { useWalletGate } from '../lib/useChain';
import InfoCard from './InfoCard';
import InfoRow from './InfoRow';
import { inputClass } from './formStyles';

const allowedSet = parseAbiItem('event AllowedSet(address indexed account, bool allowed, bool pinned)');

interface Props {
  token: Address;
  /** current coin admin */
  admin: Address | undefined;
  /** block of the launch, where the allowlist events start */
  fromBlock: bigint;
}

/** Restriction status of a v2 coin, with the admin controls (setAllowed, unrestrict, lockAllowlist). */
export default function RestrictionPanel({ token, admin, fromBlock }: Props) {
  const gate = useWalletGate();
  const client = usePublicClient();
  const base = { address: token, abi: tokenV2Abi } as const;
  const { data, refetch } = useReadContracts({
    contracts: [
      { ...base, functionName: 'restricted' },
      { ...base, functionName: 'allowlistLocked' },
    ],
    allowFailure: true,
    query: { staleTime: 15_000 },
  });
  const restricted = data?.[0]?.status === 'success' ? (data[0].result as boolean) : undefined;
  const locked = data?.[1]?.status === 'success' ? (data[1].result as boolean) : undefined;

  const { data: allowlist, refetch: refetchList } = useQuery({
    queryKey: ['allowedSet', token],
    enabled: !!client,
    staleTime: 60_000,
    queryFn: async () => {
      const logs = await client!.getLogs({ address: token, event: allowedSet, fromBlock, toBlock: 'latest' });
      return foldAllowed(logs.map((l) => ({ account: l.args.account as string, allowed: !!l.args.allowed })));
    },
  });

  const { writeContractAsync, data: hash, isPending, reset } = useWriteContract();
  const { data: receipt, isLoading: confirming } = useWaitForTransactionReceipt({ hash });
  const [error, setError] = useState<string | null>(null);
  const [entry, setEntry] = useState('');
  const entryAddr = entry.trim() ? parseAddress(entry.trim()) : null;

  const isAdmin = !!gate.address && !!admin && gate.address.toLowerCase() === admin.toLowerCase();
  const busy = isPending || confirming;

  const send = async (fn: 'setAllowed' | 'unrestrict' | 'lockAllowlist', args?: readonly [Address, boolean], confirmText?: string) => {
    if (!client || !gate.address) return;
    if (confirmText && !window.confirm(confirmText)) return;
    setError(null);
    reset();
    try {
      if (fn === 'setAllowed') {
        const sim = await client.simulateContract({ account: gate.address, ...base, functionName: 'setAllowed', args: args! });
        await writeContractAsync(sim.request);
      } else {
        const sim = await client.simulateContract({ account: gate.address, ...base, functionName: fn });
        await writeContractAsync(sim.request);
      }
      setEntry('');
    } catch (e) {
      setError(describeError(e));
    }
  };

  // refresh the reads once a transaction lands
  const [seen, setSeen] = useState<string | undefined>();
  if (receipt?.status === 'success' && seen !== receipt.transactionHash) {
    setSeen(receipt.transactionHash);
    void refetch();
    void refetchList();
  }

  if (restricted === undefined) return null;
  const status = restricted ? 'restricted, no wallet to wallet transfers' : 'none';
  const canEdit = isAdmin && locked === false;

  return (
    <InfoCard title="Transfer restriction">
      <InfoRow label="Restriction" value={status} />
      {restricted && <InfoRow label="Allowlist entries" value={allowlist ? allowlist.length : '...'} />}
      <InfoRow label="Allowlist locked" value={locked === undefined ? '...' : locked ? 'yes, the allowlist and the switch are frozen' : 'no'} />
      {isAdmin && locked === false && (
        <div className="mt-3 space-y-3 border-t border-zinc-800 pt-3 text-xs text-zinc-400">
          {restricted && (
            <div className="space-y-2">
              <p>Allowlist entry. Only add contracts whose payouts are fixed by their own code, never routers, aggregators, multicall contracts or smart wallets.</p>
              <input type="text" className={inputClass} placeholder="0x..." value={entry} onChange={(e) => setEntry(e.target.value)} />
              <div className="flex gap-2">
                <button type="button" disabled={!canEdit || !entryAddr || busy} onClick={() => void send('setAllowed', [entryAddr!, true])} className="rounded border border-zinc-600 px-3 py-1 text-zinc-200 disabled:opacity-40">Allow</button>
                <button type="button" disabled={!canEdit || !entryAddr || busy} onClick={() => void send('setAllowed', [entryAddr!, false])} className="rounded border border-zinc-600 px-3 py-1 text-zinc-200 disabled:opacity-40">Remove</button>
              </div>
            </div>
          )}
          <div className="flex flex-wrap gap-2">
            {restricted && (
              <button
                type="button"
                disabled={busy}
                onClick={() => void send('unrestrict', undefined, 'Turn off the transfer restriction? This is permanent. The coin can never be restricted again.')}
                className="rounded border border-amber-600 px-3 py-1 text-amber-300 disabled:opacity-40"
              >
                Unrestrict
              </button>
            )}
            <button
              type="button"
              disabled={busy}
              onClick={() => void send('lockAllowlist', undefined, 'Lock the allowlist and the restriction switch? This is permanent. Entries can no longer change and the coin can no longer be unrestricted.')}
              className="rounded border border-amber-600 px-3 py-1 text-amber-300 disabled:opacity-40"
            >
              Lock allowlist
            </button>
          </div>
          <p>Unrestrict and lock allowlist are permanent.</p>
          {busy && <p>Waiting for the transaction...</p>}
          {error && <p className="text-red-400 break-words">{error}</p>}
        </div>
      )}
    </InfoCard>
  );
}
