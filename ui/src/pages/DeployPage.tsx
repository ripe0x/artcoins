import { useState } from 'react';
import { useAccount } from 'wagmi';
import TokenConfigForm from '../components/TokenConfigForm';
import PoolConfigForm from '../components/PoolConfigForm';
import AntiSniperForm from '../components/AntiSniperForm';
import RewardsForm from '../components/RewardsForm';
import ExtensionsForm from '../components/ExtensionsForm';
import ReviewAndDeploy from '../components/ReviewAndDeploy';
import type {
  TokenFormState,
  PoolFormState,
  MevFormState,
  RewardsFormState,
  ExtensionsFormState,
} from '../lib/types';

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

  const [openStep, setOpenStep] = useState(1);

  const [tokenForm, setTokenForm] = useState<TokenFormState>({
    name: '',
    symbol: '',
    admin: '',
    totalSupply: '1000000000',
    image: '',
    metadata: '',
    context: '',
  });

  const [poolForm, setPoolForm] = useState<PoolFormState>({
    pairedToken: 'weth',
    customPairedToken: '',
    tickSpacing: 60,
    startingTick: -230400,
    buyFeePercent: 1,
    sellFeePercent: 1,
  });

  const [mevForm, setMevForm] = useState<MevFormState>({
    moduleType: 'linear',
    linearStartPercent: 99,
    linearEndPercent: 1,
    linearDurationMin: 69,
    descStartPercent: 99,
    descEndPercent: 1,
    descDurationSec: 4140,
    timeDelaySec: 12,
  });

  const [rewardsForm, setRewardsForm] = useState<RewardsFormState>({
    mode: 'simple',
    recipients: [{ admin: '', recipient: '', bps: 10000 }],
    // Single-sided liquidity: tickLower MUST be >= pool's starting tick.
    // In simple mode we sync tickLower to poolForm.startingTick (see RewardsForm).
    positions: [{ tickLower: -230400, tickUpper: 887220, bps: 10000 }],
  });

  const [extensionsForm, setExtensionsForm] = useState<ExtensionsFormState>({
    vault: { enabled: false, admin: '', allocationPercent: 10, lockupDays: 30, vestingDays: 90 },
    airdrop: { enabled: false, admin: '', allocationPercent: 5, merkleRoot: '', lockupDays: 7, vestingDays: 30 },
    devBuy: { enabled: false, ethAmount: '0.1', allocationPercent: 5 },
  });

  const toggle = (step: number) => setOpenStep(prev => (prev === step ? 0 : step));

  return (
    <main className="mx-auto max-w-3xl px-4 py-8 space-y-3">
      <div className="mb-8">
        <h1 className="text-2xl font-bold">Deploy Token</h1>
        <p className="text-zinc-500 mt-1">
          Configure and deploy a new token through the NewMaterial factory.
        </p>
      </div>

      <StepCard
        step={1}
        title="Token Configuration"
        subtitle="Name, symbol, supply, and metadata"
        isOpen={openStep === 1}
        onToggle={() => toggle(1)}
      >
        <TokenConfigForm value={tokenForm} onChange={setTokenForm} connectedAddress={address} />
      </StepCard>

      <StepCard
        step={2}
        title="Pool Configuration"
        subtitle="Paired token, fees, and tick settings"
        isOpen={openStep === 2}
        onToggle={() => toggle(2)}
      >
        <PoolConfigForm value={poolForm} onChange={setPoolForm} />
      </StepCard>

      <StepCard
        step={3}
        title="Anti-Sniper / MEV Protection"
        subtitle="Launch fee schedule to deter bots"
        isOpen={openStep === 3}
        onToggle={() => toggle(3)}
      >
        <AntiSniperForm value={mevForm} onChange={setMevForm} />
      </StepCard>

      <StepCard
        step={4}
        title="LP Rewards"
        subtitle="Reward recipients and LP position ranges"
        isOpen={openStep === 4}
        onToggle={() => toggle(4)}
      >
        <RewardsForm
          value={rewardsForm}
          onChange={setRewardsForm}
          connectedAddress={address}
          startingTick={poolForm.startingTick}
          tickSpacing={poolForm.tickSpacing}
        />
      </StepCard>

      <StepCard
        step={5}
        title="Extensions"
        subtitle="Vault, airdrop, and dev buy allocations"
        isOpen={openStep === 5}
        onToggle={() => toggle(5)}
      >
        <ExtensionsForm value={extensionsForm} onChange={setExtensionsForm} connectedAddress={address} />
      </StepCard>

      <StepCard
        step={6}
        title="Review & Deploy"
        subtitle="Review configuration and deploy your token"
        isOpen={openStep === 6}
        onToggle={() => toggle(6)}
      >
        <ReviewAndDeploy
          tokenForm={tokenForm}
          poolForm={poolForm}
          mevForm={mevForm}
          rewardsForm={rewardsForm}
          extensionsForm={extensionsForm}
        />
      </StepCard>
    </main>
  );
}
