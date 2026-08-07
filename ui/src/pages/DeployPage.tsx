import { useEffect, useState } from 'react';
import { useAccount } from 'wagmi';
import TokenConfigForm from '../components/TokenConfigForm';
import PoolConfigForm from '../components/PoolConfigForm';
import AntiSniperForm from '../components/AntiSniperForm';
import RewardsForm from '../components/RewardsForm';
import ExtensionsForm from '../components/ExtensionsForm';
import ReviewAndDeploy from '../components/ReviewAndDeploy';
import {
  validateTokenStep,
  validatePoolStep,
  validateRewardsStep,
  validateExtensionsStep,
} from '../lib/validate';
import type {
  TokenFormState,
  PoolFormState,
  MevFormState,
  RewardsFormState,
  ExtensionsFormState,
} from '../lib/types';

// ── Draft persistence ───────────────────────────────────────────────────
//
// The deploy form can represent a nontrivial amount of configuration work
// (a full mainnet token launch). Losing it to an accidental refresh or
// back-navigation is hostile, so the whole form is mirrored to
// localStorage and restored on mount.
//
// The storage key is itself versioned so an incompatible future shape
// change can bump the suffix and old drafts are simply ignored rather than
// crashing on load; `version` inside the payload is a second,
// belt-and-suspenders check for the same thing (in case the key is ever
// kept but the payload shape changes).
const DRAFT_VERSION = 1;
const DRAFT_STORAGE_KEY = `artcoins:deployDraft:v${DRAFT_VERSION}`;

const DEFAULT_TOKEN_FORM: TokenFormState = {
  name: '',
  symbol: '',
  admin: '',
  totalSupply: '1000000000',
  image: '',
  metadata: '',
  context: '',
};

const DEFAULT_POOL_FORM: PoolFormState = {
  pairedToken: 'weth',
  customPairedToken: '',
  tickSpacing: 60,
  startingTick: -230400,
  buyFeePercent: 1,
  sellFeePercent: 1,
};

const DEFAULT_MEV_FORM: MevFormState = {
  moduleType: 'linear',
  linearStartPercent: 99,
  linearEndPercent: 1,
  linearDurationMin: 69,
  descStartPercent: 99,
  descEndPercent: 1,
  descDurationSec: 4140,
  timeDelaySec: 12,
};

const DEFAULT_REWARDS_FORM: RewardsFormState = {
  mode: 'simple',
  recipients: [{ admin: '', recipient: '', bps: 10000 }],
  // Single-sided liquidity: tickLower MUST be >= pool's starting tick.
  // In simple mode we sync tickLower to poolForm.startingTick (see RewardsForm).
  positions: [{ tickLower: -230400, tickUpper: 887220, bps: 10000 }],
};

const DEFAULT_EXTENSIONS_FORM: ExtensionsFormState = {
  vault: { enabled: false, admin: '', allocationPercent: 10, lockupDays: 30, vestingDays: 90 },
  airdrop: { enabled: false, admin: '', allocationPercent: 5, merkleRoot: '', lockupDays: 7, vestingDays: 30 },
  devBuy: { enabled: false, ethAmount: '0.1', allocationPercent: 5 },
};

interface DeployDraft {
  version: number;
  tokenForm: TokenFormState;
  poolForm: PoolFormState;
  mevForm: MevFormState;
  rewardsForm: RewardsFormState;
  extensionsForm: ExtensionsFormState;
}

// None of the current form slices contain `bigint` values — every field in
// lib/types.ts is a string/number/boolean, and `ReviewAndDeploy` only
// derives bigints (totalSupply, msgValue, ...) at submit time from those
// strings/numbers, never storing them back into form state. So a plain
// JSON round-trip is safe today. This replacer/reviver pair guards against
// that changing later: `JSON.stringify` throws outright on a bare bigint,
// and a naive `String(bigint)` reviver would be unable to tell a
// stringified bigint apart from an ordinary numeric string field.
const BIGINT_TAG = '__bigint__';

function draftReplacer(_key: string, value: unknown): unknown {
  return typeof value === 'bigint' ? { [BIGINT_TAG]: value.toString() } : value;
}

function draftReviver(_key: string, value: unknown): unknown {
  if (value && typeof value === 'object' && BIGINT_TAG in (value as Record<string, unknown>)) {
    return BigInt((value as Record<string, string>)[BIGINT_TAG]);
  }
  return value;
}

// Parsed at most once per page load and cached here — each form slice's
// lazy `useState` initializer reads from this instead of re-parsing
// localStorage five separate times.
let cachedDraft: DeployDraft | null | undefined;

function loadDraft(): DeployDraft | null {
  if (cachedDraft !== undefined) return cachedDraft;
  try {
    const raw = window.localStorage.getItem(DRAFT_STORAGE_KEY);
    if (!raw) {
      cachedDraft = null;
      return null;
    }
    const parsed = JSON.parse(raw, draftReviver) as Partial<DeployDraft> | null;
    if (!parsed || parsed.version !== DRAFT_VERSION) {
      cachedDraft = null;
      return null;
    }
    cachedDraft = parsed as DeployDraft;
    return cachedDraft;
  } catch {
    // Malformed JSON, localStorage disabled (private browsing), etc. — fall
    // back to defaults rather than crash the page.
    cachedDraft = null;
    return null;
  }
}

function clearDraft() {
  cachedDraft = null;
  try {
    window.localStorage.removeItem(DRAFT_STORAGE_KEY);
  } catch {
    // best-effort
  }
}

function StepCard({
  step,
  title,
  subtitle,
  isOpen,
  onToggle,
  hasError,
  children,
}: {
  step: number;
  title: string;
  subtitle: string;
  isOpen: boolean;
  onToggle: () => void;
  hasError?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
      <button
        type="button"
        onClick={onToggle}
        className="w-full flex items-center gap-4 px-6 py-4 text-left hover:bg-zinc-800/50 transition-colors"
      >
        <span className="relative flex-shrink-0 w-8 h-8 rounded-full bg-violet-600/20 text-violet-400 flex items-center justify-center text-sm font-semibold">
          {step}
          {hasError && (
            <span
              className="absolute -top-0.5 -right-0.5 w-3 h-3 rounded-full bg-red-500 border-2 border-zinc-900"
              title="This step has validation errors"
            />
          )}
        </span>
        <div className="flex-1 min-w-0">
          <h3 className="text-base font-semibold text-white flex items-center gap-2">
            {title}
            {hasError && (
              <span className="text-xs font-medium text-red-400">Needs attention</span>
            )}
          </h3>
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

  const [tokenForm, setTokenForm] = useState<TokenFormState>(
    () => loadDraft()?.tokenForm ?? DEFAULT_TOKEN_FORM
  );

  const [poolForm, setPoolForm] = useState<PoolFormState>(
    () => loadDraft()?.poolForm ?? DEFAULT_POOL_FORM
  );

  const [mevForm, setMevForm] = useState<MevFormState>(
    () => loadDraft()?.mevForm ?? DEFAULT_MEV_FORM
  );

  const [rewardsForm, setRewardsForm] = useState<RewardsFormState>(
    () => loadDraft()?.rewardsForm ?? DEFAULT_REWARDS_FORM
  );

  const [extensionsForm, setExtensionsForm] = useState<ExtensionsFormState>(
    () => loadDraft()?.extensionsForm ?? DEFAULT_EXTENSIONS_FORM
  );

  // Mirror every change back to localStorage so a refresh or accidental
  // back-navigation doesn't discard the in-progress configuration. The draft
  // is cleared once a deploy confirms (see `onDeployed` below) and by the
  // explicit reset control.
  useEffect(() => {
    try {
      const draft: DeployDraft = {
        version: DRAFT_VERSION,
        tokenForm,
        poolForm,
        mevForm,
        rewardsForm,
        extensionsForm,
      };
      window.localStorage.setItem(DRAFT_STORAGE_KEY, JSON.stringify(draft, draftReplacer));
    } catch {
      // Storage may be full or disabled (private browsing) — the in-memory
      // form still works, it just won't survive a refresh.
    }
  }, [tokenForm, poolForm, mevForm, rewardsForm, extensionsForm]);

  const toggle = (step: number) => setOpenStep(prev => (prev === step ? 0 : step));

  const handleResetForm = () => {
    if (!window.confirm('Reset all deploy form fields? This clears your saved draft and cannot be undone.')) {
      return;
    }
    setTokenForm(DEFAULT_TOKEN_FORM);
    setPoolForm(DEFAULT_POOL_FORM);
    setMevForm(DEFAULT_MEV_FORM);
    setRewardsForm(DEFAULT_REWARDS_FORM);
    setExtensionsForm(DEFAULT_EXTENSIONS_FORM);
    setOpenStep(1);
    clearDraft();
  };

  const tokenStepErrors = validateTokenStep(tokenForm);
  const poolStepErrors = validatePoolStep(poolForm);
  const rewardsStepErrors = validateRewardsStep(rewardsForm, poolForm);
  const extensionsStepErrors = validateExtensionsStep(extensionsForm);
  const reviewStepErrors = [
    ...tokenStepErrors,
    ...poolStepErrors,
    ...rewardsStepErrors,
    ...extensionsStepErrors,
  ];

  return (
    <main className="mx-auto max-w-3xl px-4 py-8 space-y-3">
      <div className="mb-8 flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold">Deploy Token</h1>
          <p className="text-zinc-500 mt-1">
            Configure and deploy a new token through the artcoins factory.
          </p>
        </div>
        <button
          type="button"
          onClick={handleResetForm}
          className="flex-shrink-0 rounded-lg border border-zinc-700 hover:border-red-500/60 px-3 py-1.5 text-xs font-medium text-zinc-400 hover:text-red-300 transition-colors"
        >
          Reset form
        </button>
      </div>

      <StepCard
        step={1}
        title="Token Configuration"
        subtitle="Name, symbol, supply, and metadata"
        isOpen={openStep === 1}
        onToggle={() => toggle(1)}
        hasError={tokenStepErrors.length > 0}
      >
        <TokenConfigForm value={tokenForm} onChange={setTokenForm} connectedAddress={address} />
      </StepCard>

      <StepCard
        step={2}
        title="Pool Configuration"
        subtitle="Paired token, fees, and tick settings"
        isOpen={openStep === 2}
        onToggle={() => toggle(2)}
        hasError={poolStepErrors.length > 0}
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
        hasError={rewardsStepErrors.length > 0}
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
        hasError={extensionsStepErrors.length > 0}
      >
        <ExtensionsForm value={extensionsForm} onChange={setExtensionsForm} connectedAddress={address} />
      </StepCard>

      <StepCard
        step={6}
        title="Review & Deploy"
        subtitle="Review configuration and deploy your token"
        isOpen={openStep === 6}
        onToggle={() => toggle(6)}
        hasError={reviewStepErrors.length > 0}
      >
        <ReviewAndDeploy
          tokenForm={tokenForm}
          poolForm={poolForm}
          mevForm={mevForm}
          rewardsForm={rewardsForm}
          extensionsForm={extensionsForm}
          onDeployed={clearDraft}
        />
      </StepCard>
    </main>
  );
}
