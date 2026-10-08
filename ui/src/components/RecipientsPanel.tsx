import { useMemo, useState } from 'react';
import { usePublicClient, useReadContracts, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import type { Address, Hex } from 'viem';
import { tokenV2Abi } from '../lib/abi/v2/token';
import { hookV2Abi } from '../lib/abi/v2/hook';
import { lockerV2Abi } from '../lib/abi/v2/locker';
import { describeError } from '../lib/errors';
import { deriveRewardRows, recipientEditState, validateRecipient, type RecipientForbidden } from '../lib/recipients';
import { useWalletGate } from '../lib/useChain';
import CopyableAddress from './CopyableAddress';
import InfoCard from './InfoCard';
import InfoRow from './InfoRow';
import { inputClass } from './formStyles';

interface Props {
  token: Address;
  hook: Address;
  locker: Address;
  escrow: Address;
  poolManager: Address;
  poolId: Hex;
  admin: Address | undefined;
}

type Target = { kind: 'bounty' } | { kind: 'reward'; index: number };

/** Fee recipients of a v2 coin: the hook bounty recipient and the locker reward recipients, with admin controls. */
export default function RecipientsPanel({ token, hook, locker, escrow, poolManager, poolId, admin }: Props) {
  const gate = useWalletGate();
  const client = usePublicClient();
  const { data, refetch } = useReadContracts({
    contracts: [
      { address: token, abi: tokenV2Abi, functionName: 'recipientsLocked' },
      { address: hook, abi: hookV2Abi, functionName: 'skimConfig', args: [poolId] },
      { address: locker, abi: lockerV2Abi, functionName: 'tokenRewards', args: [token] },
      { address: locker, abi: lockerV2Abi, functionName: 'protocolSlotIndex', args: [token] },
    ],
    allowFailure: true,
    query: { staleTime: 15_000 },
  });
  const locked = data?.[0]?.status === 'success' ? (data[0].result as boolean) : undefined;
  const skim = data?.[1]?.status === 'success' ? (data[1].result as { bountyRecipient: Address; protocolRecipient: Address }) : undefined;
  const rewards = data?.[2]?.status === 'success' ? (data[2].result as { rewardBps: readonly number[]; rewardRecipients: readonly Address[] }) : undefined;
  const slot = data?.[3]?.status === 'success' ? (data[3].result as readonly [boolean, bigint]) : undefined;
  const rows = useMemo(
    () => (rewards && slot ? deriveRewardRows(rewards.rewardBps, rewards.rewardRecipients, { exists: slot[0], index: slot[1] }) : []),
    [rewards, slot]
  );

  const { writeContractAsync, data: txHash, isPending, reset } = useWriteContract();
  const { data: receipt, isLoading: confirming } = useWaitForTransactionReceipt({ hash: txHash });
  const [error, setError] = useState<string | null>(null);
  const [target, setTarget] = useState<Target | null>(null);
  const [entry, setEntry] = useState('');
  const [seen, setSeen] = useState<string | undefined>();
  if (receipt?.status === 'success' && seen !== receipt.transactionHash) {
    setSeen(receipt.transactionHash);
    void refetch();
  }

  const isAdmin = !!gate.address && !!admin && gate.address.toLowerCase() === admin.toLowerCase();
  const state = recipientEditState(isAdmin, locked);
  const busy = isPending || confirming;
  const forbidden: RecipientForbidden = { coin: token, hook, locker, escrow, poolManager };
  const check = entry.trim() ? validateRecipient(entry, forbidden) : null;

  const run = async (go: () => Promise<{ request: never }>) => {
    setError(null);
    reset();
    try {
      const sim = await go();
      await writeContractAsync(sim.request);
      setEntry('');
      setTarget(null);
    } catch (e) {
      setError(describeError(e));
    }
  };

  const submit = () => {
    if (!client || !gate.address || !target || !check?.ok) return;
    const account = gate.address;
    void run(() =>
      (target.kind === 'bounty'
        ? client.simulateContract({ account, address: hook, abi: hookV2Abi, functionName: 'setBountyRecipient', args: [poolId, check.address] })
        : client.simulateContract({ account, address: locker, abi: lockerV2Abi, functionName: 'setRewardRecipient', args: [token, BigInt(target.index), check.address] })) as never
    );
  };

  const lock = () => {
    if (!client || !gate.address) return;
    if (!window.confirm('Lock the fee recipients? This is permanent. The bounty recipient and the reward recipients can never change again.')) return;
    const account = gate.address;
    void run(() => client.simulateContract({ account, address: token, abi: tokenV2Abi, functionName: 'lockRecipients' }) as never);
  };

  if (!skim && !rewards) return null;
  const editable = state === 'editable';
  const editBtn = 'rounded border border-zinc-600 px-2 py-0.5 text-xs text-zinc-200 disabled:opacity-40';
  const addr = (a: Address) => <CopyableAddress address={a} />;

  return (
    <InfoCard title="Fee recipients">
      {skim && (
        <InfoRow
          label="Bounty recipient"
          value={
            <span className="flex items-center gap-2">
              {addr(skim.bountyRecipient)}
              {editable && <button type="button" disabled={busy} className={editBtn} onClick={() => { setTarget({ kind: 'bounty' }); setEntry(''); }}>Change</button>}
            </span>
          }
        />
      )}
      {rows.map((r) => (
        <InfoRow
          key={r.index}
          label={`Reward ${r.index + 1}${r.protocolSlot ? ' (protocol, fixed)' : ''}`}
          value={
            <span className="flex items-center gap-2">
              <span className="text-zinc-400">{(r.bps / 100).toFixed(2)}%</span>
              {addr(r.recipient)}
              {editable && !r.protocolSlot && <button type="button" disabled={busy} className={editBtn} onClick={() => { setTarget({ kind: 'reward', index: r.index }); setEntry(''); }}>Change</button>}
            </span>
          }
        />
      ))}
      <InfoRow label="Recipients locked" value={locked === undefined ? '...' : locked ? 'yes, no recipient can change' : 'no'} />
      {editable && (
        <div className="mt-3 space-y-3 border-t border-zinc-800 pt-3 text-xs text-zinc-400">
          {target && (
            <div className="space-y-2">
              <p>New {target.kind === 'bounty' ? 'bounty recipient' : `reward ${target.index + 1} recipient`}. Shares stay the same.</p>
              <input type="text" className={inputClass} placeholder="0x..." value={entry} onChange={(e) => setEntry(e.target.value)} />
              {check && !check.ok && <p className="text-red-400">{check.error}</p>}
              <div className="flex gap-2">
                <button type="button" disabled={!check?.ok || busy} onClick={submit} className="rounded border border-zinc-600 px-3 py-1 text-zinc-200 disabled:opacity-40">Set recipient</button>
                <button type="button" disabled={busy} onClick={() => { setTarget(null); setEntry(''); }} className="rounded border border-zinc-700 px-3 py-1 text-zinc-400">Cancel</button>
              </div>
            </div>
          )}
          <button type="button" disabled={busy} onClick={lock} className="rounded border border-amber-600 px-3 py-1 text-amber-300 disabled:opacity-40">Lock recipients</button>
          <p>Locking is permanent and covers the bounty recipient and every reward recipient.</p>
          {busy && <p>Waiting for the transaction...</p>}
          {error && <p className="text-red-400 break-words">{error}</p>}
        </div>
      )}
    </InfoCard>
  );
}
