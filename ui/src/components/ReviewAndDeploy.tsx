import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { usePublicClient, useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import { useQueryClient } from '@tanstack/react-query';
import { formatEther, parseEventLogs, type Address } from 'viem';
import { factoryV2Abi } from '../lib/abi/v2/factory';
import { buildLaunchConfigV2, percentToBps, percentToSkim, validateLaunch, type LaunchContext } from '../lib/encodeV2';
import { maxReferralCapSkim } from '../lib/launchRules';
import type { LaunchForm } from '../lib/types';
import type { V2Stack } from '../lib/v2';
import type { FactoryState } from '../lib/factoryState';
import { useWalletGate } from '../lib/useChain';
import { describeError } from '../lib/errors';
import { impliedFdvEth } from '../lib/curve';
import { estimateDevBuy } from '../lib/devBuy';
import { Issues } from './formUi';

interface Props {
  form: LaunchForm;
  ctx: LaunchContext;
  v2: V2Stack | null;
  state: FactoryState;
  /** reasons the page already knows deploy is closed (no v2 stack, deprecated and not owner) */
  pageBlock: string | null;
  supplyWhole: number;
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex justify-between py-1.5 border-b border-zinc-800 last:border-0 gap-4">
      <span className="text-sm text-zinc-500 flex-shrink-0">{label}</span>
      <span className="text-sm text-white text-right break-all">{value}</span>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">{title}</h4>
      <div className="rounded-lg border border-zinc-800 bg-zinc-800/30 px-4 py-2">{children}</div>
    </div>
  );
}

const pct = (n: number, digits = 2) => `${n.toFixed(digits).replace(/\.?0+$/, '')}%`;

export default function ReviewAndDeploy({ form, ctx, v2, state, pageBlock, supplyWhole }: Props) {
  const gate = useWalletGate();
  const client = usePublicClient();
  const queryClient = useQueryClient();
  const { writeContractAsync, data: txHash, isPending, reset } = useWriteContract();
  const { data: receipt, isLoading: isConfirming, error: receiptError } = useWaitForTransactionReceipt({ hash: txHash });
  const [sendError, setSendError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [checking, setChecking] = useState(false);

  const issues = useMemo(() => validateLaunch(form, ctx), [form, ctx]);
  const errors = issues.filter((i) => i.severity === 'error');
  const built = useMemo(() => {
    if (errors.length > 0) return null;
    try {
      return buildLaunchConfigV2(form, ctx);
    } catch {
      return null;
    }
  }, [form, ctx, errors.length]);

  // the token address comes from the launch event of the factory that was called, nothing else
  const deployedToken = useMemo<Address | null>(() => {
    if (!receipt || receipt.status !== 'success' || !v2) return null;
    const logs = receipt.logs.filter((l) => l.address.toLowerCase() === v2.factory.toLowerCase());
    try {
      const parsed = parseEventLogs({ abi: factoryV2Abi, eventName: 'TokenCreatedV2', logs });
      return parsed[0]?.args.token ?? null;
    } catch {
      return null;
    }
  }, [receipt, v2]);
  const reverted = receipt?.status === 'reverted';

  useEffect(() => {
    if (deployedToken) void queryClient.invalidateQueries({ queryKey: ['tokens'] });
  }, [deployedToken, queryClient]);

  const blocker =
    pageBlock ??
    (!state.ok && !state.loading ? 'Could not read the factory, try again' : null) ??
    (errors.length > 0 ? `${errors.length} problem${errors.length === 1 ? '' : 's'} to fix above` : null);
  const walletBlock = gate.reason;
  const dev = form.extensions.devBuy.enabled ? estimateDevBuy(form) : null;

  const handleDeploy = async () => {
    if (!v2 || !client || !gate.address || !built) return;
    setSendError(null);
    setNotice(null);
    setChecking(true);
    try {
      // 1. read the fee and the gate again right before signing, the owner can change both
      const [deprecated, fee] = await Promise.all([
        client.readContract({ address: v2.factory, abi: factoryV2Abi, functionName: 'deprecated' }),
        client.readContract({ address: v2.factory, abi: factoryV2Abi, functionName: 'deployFee' }),
      ]);
      if (fee !== ctx.deployFee) {
        state.refetch();
        setNotice(`The deploy fee changed from ${formatEther(ctx.deployFee)} to ${formatEther(fee)} ETH. Review and press deploy again.`);
        return;
      }
      if (deprecated && !state.deprecated) {
        state.refetch();
        setNotice('The factory was just closed to public launches. Nothing was sent.');
        return;
      }
      // 2. simulate with the exact value, a revert is shown with its reason and nothing is signed
      const sim = await client.simulateContract({
        account: gate.address,
        address: v2.factory,
        abi: factoryV2Abi,
        functionName: 'deployToken',
        args: [built.config],
        value: built.value,
      });
      // 3. send
      await writeContractAsync(sim.request);
    } catch (e) {
      setSendError(describeError(e));
    } finally {
      setChecking(false);
    }
  };

  const mev = form.mev;
  const taxLabel = form.tax.mode === 0 ? 'None' : form.tax.mode === 1 ? `Venue tax, side pools taxed: ${form.tax.taxPercent}% (max ${form.tax.maxPercent}%) to ${form.tax.sink === 'dead' ? 'burn' : 'bounty recipient'}` : 'Hard mode, side pools blocked (a v2 pair listed later traps its lps)';
  const totalExt =
    (form.extensions.vault.enabled ? form.extensions.vault.allocationPercent : 0) + (form.extensions.airdrop.enabled ? form.extensions.airdrop.allocationPercent : 0);
  const sumRewards = form.rewards.recipients.reduce((s, r) => s + r.bps, 0);
  const disabled = !!blocker || !!walletBlock || isPending || isConfirming || checking || !built;

  return (
    <div className="space-y-6">
      <div className="space-y-4">
        <Section title="Token">
          <Row label="Name" value={form.token.name || '-'} />
          <Row label="Symbol" value={form.token.symbol || '-'} />
          <Row label="Admin" value={form.token.admin || 'Connected wallet'} />
          <Row label="Supply" value={Number(form.token.totalSupply) > 0 ? Number(form.token.totalSupply).toLocaleString() : 'Factory default (1,000,000,000)'} />
          <Row label="Renderer" value={form.token.renderer || 'default'} />
        </Section>

        <Section title="Pool and fees">
          <Row label="Paired with" value="native ETH" />
          <Row label="Tick spacing / start tick" value={`${form.pool.tickSpacing} / ${form.pool.startingTick}`} />
          <Row label="Launch fdv" value={`${impliedFdvEth(form.pool.startingTick, supplyWhole).toLocaleString(undefined, { maximumFractionDigits: 3 })} ETH`} />
          <Row label="LP fee" value={`${pct(form.pool.lpFeePercent)} (factory minimum ${pct(ctx.minLpFee / 10_000)})`} />
          <Row label="Baseline skim" value={`${pct(form.pool.baselineSkimPercent)} of volume`} />
          <Row label="Bounty share of skim" value={pct(form.pool.bountyPercent)} />
          <Row
            label="Referral cap"
            value={`${pct(form.pool.referralCapPercent, 3)} of volume (maximum for these fees ${pct(maxReferralCapSkim(percentToSkim(form.pool.baselineSkimPercent), percentToBps(form.pool.bountyPercent), ctx.minProtocolSkimShareBps) / 1_000, 3)}), claimed from the fee escrow`}
          />
          <Row label="Protocol keeps at least" value={`${pct(ctx.minProtocolSkimShareBps / 100)} of the skim`} />
          <Row label="Anti sniper" value={mev.enabled ? `${pct(mev.startPercent)} decaying to ${pct(form.pool.baselineSkimPercent)} over ${mev.windowMin} min` : 'Off'} />
          <Row label="Tax" value={taxLabel} />
        </Section>

        <Section title="Rewards">
          <Row label="Your recipients" value={`${form.rewards.recipients.length} (${sumRewards / 100}% of LP rewards)`} />
          <Row label="Protocol slot" value={`${ctx.protocolBps / 100}% of LP rewards, set by the factory`} />
          <Row label="Positions" value={`${form.rewards.positions.length}, locked forever`} />
        </Section>

        <Section title="Extensions">
          <Row label="Vault" value={form.extensions.vault.enabled ? `${form.extensions.vault.allocationPercent}%` : 'Off'} />
          <Row label="Airdrop" value={form.extensions.airdrop.enabled ? `${form.extensions.airdrop.allocationPercent}%` : 'Off'} />
          <Row
            label="Dev buy"
            value={form.extensions.devBuy.enabled ? `${form.extensions.devBuy.ethAmount} ETH, at least ${form.extensions.devBuy.minTokenOut || '?'} coins${dev ? ` (est. ${Number(dev.coinOut / 10n ** 18n).toLocaleString()})` : ''}` : 'Off'}
          />
          <Row label="To liquidity" value={pct(100 - totalExt)} />
        </Section>

        <Section title="Cost">
          <Row label="Deploy fee (from the factory)" value={state.ok ? `${formatEther(ctx.deployFee)} ETH` : 'unknown'} />
          <Row label="Extension ETH" value={`${formatEther(built?.extensionValue ?? 0n)} ETH`} />
          <Row label="Total sent" value={<strong>{built ? `${formatEther(built.value)} ETH` : '-'}</strong>} />
        </Section>
      </div>

      <Issues issues={issues} prefix={['token', 'pool', 'mev', 'tax', 'rewards', 'positions', 'vault', 'airdrop', 'devBuy', 'extensions']} />

      {deployedToken ? (
        <div className="rounded-lg border border-green-800 bg-green-900/20 p-4 space-y-2">
          <h4 className="text-green-400 font-semibold">Token launched</h4>
          <p className="text-sm text-zinc-300 font-mono break-all">{deployedToken}</p>
          <div className="flex flex-wrap gap-3">
            <Link to={`/tokens/${deployedToken}`} className="text-sm text-violet-400 hover:text-violet-300 underline">View token</Link>
            <a href={`https://etherscan.io/address/${deployedToken}`} target="_blank" rel="noopener noreferrer" className="text-sm text-violet-400 hover:text-violet-300 underline">Etherscan</a>
            {txHash && <a href={`https://etherscan.io/tx/${txHash}`} target="_blank" rel="noopener noreferrer" className="text-sm text-violet-400 hover:text-violet-300 underline">Transaction</a>}
          </div>
        </div>
      ) : (
        <>
          {pageBlock && <p className="text-sm text-amber-400">{pageBlock}</p>}
          {!pageBlock && walletBlock && (
            <div className="flex items-center gap-3">
              <p className="text-sm text-amber-400">{walletBlock}.</p>
              {gate.needsSwitch && (
                <button type="button" onClick={gate.switchToMainnet} className="text-sm text-violet-400 underline">Switch</button>
              )}
            </div>
          )}
          {notice && <p className="text-sm text-amber-300">{notice}</p>}

          {txHash && isConfirming && (
            <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-4 space-y-2">
              <p className="text-sm text-zinc-300">Transaction submitted. Waiting for confirmation. If it takes long, check the link, a dropped transaction never confirms.</p>
              <a href={`https://etherscan.io/tx/${txHash}`} target="_blank" rel="noopener noreferrer" className="text-sm text-violet-400 hover:text-violet-300 underline font-mono break-all">{txHash}</a>
            </div>
          )}
          {reverted && (
            <div className="rounded-lg border border-red-800 bg-red-900/20 p-3 space-y-1">
              <p className="text-sm text-red-400">The launch transaction was mined but reverted. No token was created.</p>
              <button type="button" onClick={() => reset()} className="text-xs text-red-300 underline">Dismiss</button>
            </div>
          )}
          {(sendError || receiptError) && (
            <div className="rounded-lg border border-red-800 bg-red-900/20 p-3">
              <p className="text-sm text-red-400 break-words">{sendError ?? describeError(receiptError)}</p>
              <p className="text-xs text-zinc-500 mt-1">Nothing was signed unless a wallet prompt appeared before this message.</p>
            </div>
          )}

          <button
            type="button"
            onClick={() => void handleDeploy()}
            disabled={disabled}
            className="w-full rounded-xl bg-violet-600 py-3 text-base font-semibold text-white transition-colors hover:bg-violet-500 disabled:bg-zinc-700 disabled:text-zinc-500 disabled:cursor-not-allowed"
          >
            {isPending ? 'Confirm in wallet...' : isConfirming ? 'Confirming...' : checking ? 'Checking the launch...' : (pageBlock ?? blocker ?? walletBlock ?? `Deploy token (${built ? formatEther(built.value) : '-'} ETH)`)}
          </button>
          <p className="text-xs text-zinc-600">The launch is simulated against the chain first. If the simulation reverts you see the reason and nothing is sent.</p>
        </>
      )}
    </div>
  );
}
