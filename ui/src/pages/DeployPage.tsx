import { useMemo, useState } from 'react';
import { useAccount, useReadContract } from 'wagmi';
import TokenConfigForm from '../components/TokenConfigForm';
import PoolConfigForm from '../components/PoolConfigForm';
import AntiSniperForm from '../components/AntiSniperForm';
import TaxForm from '../components/TaxForm';
import RewardsForm from '../components/RewardsForm';
import ExtensionsForm from '../components/ExtensionsForm';
import ReviewAndDeploy from '../components/ReviewAndDeploy';
import type { LaunchForm } from '../lib/types';
import { CURRENT } from '../lib/deployments.generated';
import { getV2Stack } from '../lib/v2';
import { useExemptStatus, useFactoryStateV1, useFactoryStateV2, type FactoryState } from '../lib/factoryState';
import { factoryV2Abi } from '../lib/abi/v2/factory';
import { maxReferralCapSkim } from '../lib/launchRules';
import { useAddressesOrNull } from '../lib/useChain';
import { defaultLaunchForm } from '../lib/launchForm';
import { generateSalt, maxBountyBps, percentToBps, percentToSkim, projectSideBps, skimToPercent, validateLaunch, type LaunchContext } from '../lib/encodeV2';
import { ZERO_ADDRESS } from '../lib/constants';

function StepCard({
  step,
  title,
  subtitle,
  isOpen,
  onToggle,
  children,
}: {
  step: number;
  title: string;
  subtitle: string;
  isOpen: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
      <button
        type="button"
        onClick={onToggle}
        className="w-full flex items-center gap-4 px-6 py-4 text-left hover:bg-zinc-800/50 transition-colors"
      >
        <span className="flex-shrink-0 w-8 h-8 rounded-full bg-violet-600/20 text-violet-400 flex items-center justify-center text-sm font-semibold">
          {step}
        </span>
        <div className="flex-1 min-w-0">
          <h3 className="text-base font-semibold text-white">{title}</h3>
          <p className="text-sm text-zinc-500 truncate">{subtitle}</p>
        </div>
        <svg
          className={`w-5 h-5 text-zinc-500 transition-transform ${isOpen ? 'rotate-180' : ''}`}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>
      {isOpen && <div className="px-6 pb-6 pt-2 border-t border-zinc-800">{children}</div>}
    </div>
  );
}

export default function DeployPage() {
  const { address } = useAccount();
  const { chainId, addresses } = useAddressesOrNull();
  const v2 = getV2Stack(chainId);

  // chain state: the v2 factory when configured, else the current factory only to explain why launching is closed
  const cur = useFactoryStateV1(addresses ? CURRENT.factory : undefined);
  const st2 = useFactoryStateV2(v2?.factory);
  const { data: owner } = useReadContract({
    address: v2?.factory,
    abi: factoryV2Abi,
    functionName: 'owner',
    query: { enabled: !!v2 },
  });
  const state: FactoryState = v2
    ? st2
    : {
        loading: cur.loading,
        ok: cur.ok,
        deprecated: cur.deprecated,
        deployFee: cur.deployFee,
        defaultProtocolFeeBps: cur.defaultProtocolFeeBps,
        minProtocolSkimShareBps: 0,
        minLpFee: 0,
        refetch: () => undefined,
      };

  const [openStep, setOpenStep] = useState(1);
  const [form, setForm] = useState<LaunchForm>(() => defaultLaunchForm());
  const [salt] = useState(() => generateSalt());

  // once the factory answers, make a single default recipient take exactly the project side
  // (adjusting state during render is the react pattern for state derived from other state)
  const [balancedFor, setBalancedFor] = useState<number | null>(null);
  if (state.ok && balancedFor !== state.defaultProtocolFeeBps) {
    setBalancedFor(state.defaultProtocolFeeBps);
    if (form.rewards.recipients.length === 1) {
      setForm({
        ...form,
        rewards: { ...form.rewards, recipients: [{ ...form.rewards.recipients[0], bps: projectSideBps(state.defaultProtocolFeeBps) }] },
      });
    }
  }

  // D47: every exempt entry is checked against the factory's allowlist (VENUE mode only, HARD sends none)
  const exemptEntries = useMemo(
    () => (form.tax.mode === 1 ? form.tax.exempt.split(/[\s,]+/).filter(Boolean) : []),
    [form.tax.mode, form.tax.exempt]
  );
  const exemptStatus = useExemptStatus(v2?.factory, exemptEntries, v2?.locker ?? ZERO_ADDRESS, v2?.hook ?? ZERO_ADDRESS);

  // the defaults (lp fee, bounty, referral cap) come from coin 111. once the factory answers, pull them inside the
  // factory's limits (min lp fee, bounty ceiling, referral cap maximum) so the untouched form is launchable.
  // this only ever lowers or raises a default into range, it never overwrites a value that is already valid.
  const limitsKey = state.ok ? `${state.minLpFee}:${state.minProtocolSkimShareBps}` : null;
  const [limitsFor, setLimitsFor] = useState<string | null>(null);
  if (limitsKey && limitsFor !== limitsKey) {
    setLimitsFor(limitsKey);
    const p = form.pool;
    const bounty = Math.min(p.bountyPercent, maxBountyBps(state.minProtocolSkimShareBps) / 100);
    const capMaxPct = maxReferralCapSkim(percentToSkim(p.baselineSkimPercent), percentToBps(bounty), state.minProtocolSkimShareBps) / 1_000;
    const next = {
      ...p,
      lpFeePercent: Math.max(p.lpFeePercent, state.minLpFee / 10_000),
      bountyPercent: bounty,
      referralCapPercent: Math.min(p.referralCapPercent, capMaxPct),
    };
    if (next.lpFeePercent !== p.lpFeePercent || next.bountyPercent !== p.bountyPercent || next.referralCapPercent !== p.referralCapPercent) {
      setForm((f) => ({ ...f, pool: next }));
    }
  }

  const ctx: LaunchContext = useMemo(
    () => ({
      sender: address ?? ZERO_ADDRESS,
      hook: v2?.hook ?? ZERO_ADDRESS,
      locker: v2?.locker ?? ZERO_ADDRESS,
      mevModule: v2?.mevModule ?? ZERO_ADDRESS,
      vault: v2?.vault ?? ZERO_ADDRESS,
      airdrop: v2?.airdrop ?? ZERO_ADDRESS,
      devBuy: v2?.devBuy ?? ZERO_ADDRESS,
      poolExtension: v2?.poolExtension ?? ZERO_ADDRESS,
      protocolBps: state.defaultProtocolFeeBps,
      minProtocolSkimShareBps: state.minProtocolSkimShareBps,
      minLpFee: state.minLpFee,
      exemptStatus,
      deployFee: state.deployFee,
      salt,
    }),
    [address, v2, state.defaultProtocolFeeBps, state.minProtocolSkimShareBps, state.minLpFee, exemptStatus, state.deployFee, salt]
  );
  const issues = useMemo(() => validateLaunch(form, ctx), [form, ctx]);

  const isOwner = !!address && !!owner && (owner as string).toLowerCase() === address.toLowerCase();
  let pageBlock: string | null = null;
  if (!addresses) pageBlock = 'Switch to Ethereum mainnet. There is no artcoins deployment on this network.';
  else if (!v2)
    pageBlock = cur.deprecated
      ? 'Launches are owner only on the current factory (its deprecated() flag is set), and the v2 launcher is not deployed yet. Public launches open with v2.'
      : 'The v2 launcher is not configured in this build, so this page cannot send a launch.';
  else if (state.deprecated && !isOwner)
    pageBlock = 'Launches are owner only on the v2 factory (deprecated() is true). Only the factory owner can launch until it is reopened.';

  // the most a referrer may be paid for the fees on the form (D52), shown next to the factory numbers
  const refCapMaxPercent =
    maxReferralCapSkim(percentToSkim(form.pool.baselineSkimPercent), percentToBps(form.pool.bountyPercent), state.minProtocolSkimShareBps) / 1_000;
  const supplyWhole = Number(form.token.totalSupply) > 0 ? Number(form.token.totalSupply) : 1_000_000_000;
  const toggle = (step: number) => setOpenStep((prev) => (prev === step ? 0 : step));
  const patch = <K extends keyof LaunchForm>(k: K) => (v: LaunchForm[K]) => setForm((f) => ({ ...f, [k]: v }));

  return (
    <main className="mx-auto max-w-3xl px-4 py-8 space-y-3">
      <div className="mb-8">
        <h1 className="text-2xl font-bold">Launch a coin</h1>
        <p className="text-zinc-500 mt-1">Configure and launch an art coin with its native ETH pool through the artcoins factory.</p>
      </div>

      {pageBlock && (
        <div className="rounded-xl border border-amber-700/50 bg-amber-950/20 p-4 text-sm text-amber-200" role="status">
          <p className="font-medium">Launching is closed</p>
          <p className="text-amber-200/80 mt-1">{pageBlock}</p>
          <p className="text-xs text-amber-200/60 mt-2">You can still fill in the form and review it. Nothing is sent from this page while launching is closed.</p>
        </div>
      )}
      {state.ok && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 px-4 py-3 text-xs text-zinc-400 grid grid-cols-2 sm:grid-cols-3 gap-2">
          <span>Deploy fee: <span className="text-zinc-200">{Number(state.deployFee) / 1e18} ETH</span></span>
          <span>Protocol slot: <span className="text-zinc-200">{state.defaultProtocolFeeBps / 100}%</span></span>
          <span>Min protocol skim share: <span className="text-zinc-200">{state.minProtocolSkimShareBps / 100}%</span></span>
          <span>Min lp fee: <span className="text-zinc-200">{state.minLpFee / 10_000}%</span></span>
          <span>Referral cap max (these fees): <span className="text-zinc-200">{refCapMaxPercent}% of volume</span></span>
          <span>Public launches: <span className="text-zinc-200">{state.deprecated ? 'closed' : 'open'}</span></span>
        </div>
      )}

      <StepCard step={1} title="Token" subtitle="Name, symbol, supply, image" isOpen={openStep === 1} onToggle={() => toggle(1)}>
        <TokenConfigForm value={form.token} onChange={patch('token')} connectedAddress={address} issues={issues} />
      </StepCard>

      <StepCard step={2} title="Pool and fees" subtitle="Start price, lp fee, skim, referral cap" isOpen={openStep === 2} onToggle={() => toggle(2)}>
        <PoolConfigForm value={form.pool} onChange={patch('pool')} issues={issues} supplyWhole={supplyWhole} minProtocolSkimShareBps={state.minProtocolSkimShareBps} minLpFee={state.minLpFee} connectedAddress={address} />
      </StepCard>

      <StepCard step={3} title="Anti-sniper" subtitle="Skim that decays after launch" isOpen={openStep === 3} onToggle={() => toggle(3)}>
        <AntiSniperForm value={form.mev} onChange={patch('mev')} issues={issues} baselinePercent={form.pool.baselineSkimPercent} moduleConfigured={!!v2 && v2.mevModule !== ZERO_ADDRESS} />
      </StepCard>

      <StepCard step={4} title="Token tax" subtitle="Optional, fixed at launch" isOpen={openStep === 4} onToggle={() => toggle(4)}>
        <TaxForm value={form.tax} onChange={patch('tax')} issues={issues} exemptStatus={exemptStatus} factoryConfigured={!!v2} />
      </StepCard>

      <StepCard step={5} title="LP rewards" subtitle="Who earns the fees, and the position ranges" isOpen={openStep === 5} onToggle={() => toggle(5)}>
        <RewardsForm
          value={form.rewards}
          onChange={patch('rewards')}
          connectedAddress={address}
          startingTick={form.pool.startingTick}
          tickSpacing={form.pool.tickSpacing}
          protocolBps={state.defaultProtocolFeeBps}
          issues={issues}
        />
      </StepCard>

      <StepCard step={6} title="Extensions" subtitle="Vault, airdrop and dev buy" isOpen={openStep === 6} onToggle={() => toggle(6)}>
        <ExtensionsForm
          value={form.extensions}
          onChange={patch('extensions')}
          connectedAddress={address}
          issues={issues}
          form={form}
          configured={{ vault: !!v2 && v2.vault !== ZERO_ADDRESS, airdrop: !!v2 && v2.airdrop !== ZERO_ADDRESS, devBuy: !!v2 && v2.devBuy !== ZERO_ADDRESS }}
        />
      </StepCard>

      <StepCard step={7} title="Review and launch" subtitle="Everything you are about to freeze on chain" isOpen={openStep === 7} onToggle={() => toggle(7)}>
        <ReviewAndDeploy form={form} ctx={ctx} v2={v2} state={state} pageBlock={pageBlock} supplyWhole={supplyWhole} />
      </StepCard>
      <p className="text-xs text-zinc-600 pt-2">Baseline skim {skimToPercent(Math.round(form.pool.baselineSkimPercent * 1000))}% of volume is paid on every swap on top of the lp fee. Everything on this page is frozen at launch.</p>
    </main>
  );
}
