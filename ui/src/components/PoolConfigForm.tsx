import type { PoolFormState } from '../lib/types';
import type { Issue } from '../lib/encodeV2';
import { Field, Issues } from './formUi';
import { hintClass, inputClass, selectClass } from './formStyles';
import { impliedFdvEth, startPriceEthPerCoin } from '../lib/curve';
import { formatPrice } from '../lib/format';
import { maxBountyBps, percentToBps } from '../lib/encodeV2';
import { maxReferralCapBps } from '../lib/launchRules';
import { MAX_BASELINE_SKIM_BPS, MAX_LP_FEE } from '../lib/constants';

interface Props {
  value: PoolFormState;
  onChange: (v: PoolFormState) => void;
  issues: Issue[];
  supplyWhole: number;
  minProtocolSkimShareBps: number;
  connectedAddress: string | undefined;
}

function Slider({
  label,
  value,
  min,
  max,
  step,
  unit,
  onChange,
  hint,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit: string;
  onChange: (v: number) => void;
  hint?: string;
}) {
  return (
    <div>
      <label className="block text-sm font-medium text-zinc-300 mb-1.5">
        {label}: <span className="text-violet-400 font-semibold">{value}{unit}</span>
      </label>
      <input type="range" min={min} max={max} step={step} value={value} onChange={(e) => onChange(Number(e.target.value))} className="w-full accent-violet-500" />
      <div className="flex justify-between text-xs text-zinc-600">
        <span>{min}{unit}</span>
        <span>{max}{unit}</span>
      </div>
      {hint && <p className={hintClass}>{hint}</p>}
    </div>
  );
}

export default function PoolConfigForm({ value, onChange, issues, supplyWhole, minProtocolSkimShareBps, connectedAddress }: Props) {
  const set = <K extends keyof PoolFormState>(field: K, val: PoolFormState[K]) => onChange({ ...value, [field]: val });
  const price = startPriceEthPerCoin(value.startingTick);
  const fdv = impliedFdvEth(value.startingTick, supplyWhole);
  const maxBounty = maxBountyBps(minProtocolSkimShareBps) / 100;
  // D52: the same formula the factory runs, floor(baseline * (BPS - bounty - protocol floor) / BPS)
  const capMaxBps = maxReferralCapBps(percentToBps(value.baselineSkimPercent), percentToBps(value.bountyPercent), minProtocolSkimShareBps);
  const capMax = capMaxBps / 100;
  const protocolFloorPct = minProtocolSkimShareBps / 100;

  return (
    <div className="space-y-5">
      <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 px-4 py-3 text-sm text-zinc-300">
        Every v2 pool pairs the coin with native ETH. There is no paired token to choose.
      </div>

      <div className="grid grid-cols-2 gap-4">
        <Field label="Tick spacing" hint="Positions and the starting tick must be multiples of it. The presets assume 200.">
          <select className={selectClass} value={value.tickSpacing} onChange={(e) => set('tickSpacing', Number(e.target.value))}>
            <option value={200}>200 (default)</option>
            <option value={60}>60</option>
            <option value={10}>10</option>
          </select>
        </Field>
        <Field label="Starting tick" hint="As if the coin were currency0. Price in ETH per coin is 1.0001^tick.">
          <input type="number" className={inputClass} value={value.startingTick} onChange={(e) => set('startingTick', Number(e.target.value))} />
        </Field>
      </div>
      <div className="rounded-lg bg-zinc-800/40 px-3 py-2 text-xs text-zinc-400 flex justify-between">
        <span>Launch price {formatPrice(price)} ETH per coin</span>
        <span>Launch fdv {Number.isFinite(fdv) ? fdv.toLocaleString(undefined, { maximumFractionDigits: 3 }) : '-'} ETH at {supplyWhole.toLocaleString()} coins</span>
      </div>

      <Slider label="LP fee" value={value.lpFeePercent} min={0} max={MAX_LP_FEE / 10_000} step={0.05} unit="%" onChange={(v) => set('lpFeePercent', v)} hint="Charged on every swap, paid to the LP reward recipients and the protocol's lp slot. At 0% the pool earns from the skim only." />
      <Slider label="Baseline skim" value={value.baselineSkimPercent} min={0} max={MAX_BASELINE_SKIM_BPS / 100} step={0.1} unit="%" onChange={(v) => set('baselineSkimPercent', v)} hint="Taken from the ETH side of every swap, split between the bounty recipient and the protocol." />
      <Slider label="Bounty share of the skim" value={value.bountyPercent} min={0} max={maxBounty} step={0.01} unit="%" onChange={(v) => set('bountyPercent', v)} hint={`The protocol keeps at least ${protocolFloorPct}% of the skim on every swap, referred or not (read from the factory), so the bounty share is capped at ${maxBounty}%.`} />
      <Slider label="Referral cap" value={value.referralCapPercent} min={0} max={capMax} step={0.001} unit="%" onChange={(v) => set('referralCapPercent', v)} hint={`Most of the volume a swap referrer can earn. It is paid out of the protocol's share, not by the trader, and the protocol still keeps at least ${protocolFloorPct}% of the skim. Maximum for these fees: ${capMax}% of volume = baseline skim x (100% - bounty share - ${protocolFloorPct}%). Referrers are paid in ETH during each swap.`} />
      {value.referralCapPercent > capMax && (
        <p className="text-xs text-amber-400">
          The referral cap of {value.referralCapPercent}% is above the maximum of {capMax}% for these fees. The factory would reject the launch.{' '}
          <button type="button" className="underline" onClick={() => set('referralCapPercent', capMax)}>Set it to {capMax}%</button>
        </p>
      )}

      <Field label="Bounty recipient" hint="Receives the bounty share of the skim. Defaults to your wallet.">
        <input type="text" className={inputClass} placeholder={connectedAddress ?? '0x...'} value={value.bountyRecipient} onChange={(e) => set('bountyRecipient', e.target.value)} />
      </Field>
      <Issues issues={issues} prefix="pool" />
    </div>
  );
}
