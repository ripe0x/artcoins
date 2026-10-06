import { useEffect } from 'react';
import type { LpPosition, PositionPreset, RewardRecipient, RewardsFormState } from '../lib/types';
import { projectSideBps, type Issue } from '../lib/encodeV2';
import { Issues } from './formUi';
import { inputClass } from './formStyles';
import { PRESET_LABELS, presetFitsSpacing, presetPositions } from '../lib/launchDefaults';
import { BPS, MAX_LP_POSITIONS, MAX_REWARD_PARTICIPANTS, MAX_TICK } from '../lib/constants';

const roundDown = (tick: number, spacing: number) => Math.floor(tick / spacing) * spacing;

interface Props {
  value: RewardsFormState;
  onChange: (v: RewardsFormState) => void;
  connectedAddress: string | undefined;
  startingTick: number;
  tickSpacing: number;
  /** factory.defaultProtocolFeeBps(), the slot the factory appends */
  protocolBps: number;
  issues: Issue[];
}

export default function RewardsForm({ value, onChange, connectedAddress, startingTick, tickSpacing, protocolBps, issues }: Props) {
  const target = projectSideBps(protocolBps);
  const maxProject = MAX_REWARD_PARTICIPANTS - (protocolBps === 0 ? 0 : 1);
  const presetOk = presetFitsSpacing(startingTick, tickSpacing);

  // presets follow the starting tick
  useEffect(() => {
    if (value.preset === 'custom' || !presetOk) return;
    const next = presetPositions(value.preset, startingTick);
    const same =
      next.length === value.positions.length && next.every((p, i) => p.tickLower === value.positions[i].tickLower && p.tickUpper === value.positions[i].tickUpper && p.bps === value.positions[i].bps);
    if (!same) onChange({ ...value, positions: next });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [startingTick, tickSpacing, value.preset, presetOk]);

  const setPreset = (preset: PositionPreset) => {
    if (preset === 'custom') onChange({ ...value, preset });
    else onChange({ ...value, preset, positions: presetPositions(preset, startingTick) });
  };

  const updateRecipient = (idx: number, patch: Partial<RewardRecipient>) =>
    onChange({ ...value, recipients: value.recipients.map((r, i) => (i === idx ? { ...r, ...patch } : r)) });
  const addRecipient = () => {
    if (value.recipients.length >= maxProject) return;
    onChange({ ...value, recipients: [...value.recipients, { recipient: '', bps: 0 }] });
  };
  const removeRecipient = (idx: number) => onChange({ ...value, recipients: value.recipients.filter((_, i) => i !== idx) });
  const rebalance = () => {
    const n = value.recipients.length;
    if (n === 0) return;
    const each = Math.floor(target / n);
    onChange({ ...value, recipients: value.recipients.map((r, i) => ({ ...r, bps: i === n - 1 ? target - each * (n - 1) : each })) });
  };

  const updatePosition = (idx: number, patch: Partial<LpPosition>) =>
    onChange({ ...value, preset: 'custom', positions: value.positions.map((p, i) => (i === idx ? { ...p, ...patch } : p)) });
  const addPosition = () => {
    if (value.positions.length >= MAX_LP_POSITIONS) return;
    onChange({ ...value, preset: 'custom', positions: [...value.positions, { tickLower: Math.ceil(startingTick / tickSpacing) * tickSpacing, tickUpper: roundDown(MAX_TICK, tickSpacing), bps: 0 }] });
  };
  const removePosition = (idx: number) => onChange({ ...value, preset: 'custom', positions: value.positions.filter((_, i) => i !== idx) });

  const total = value.recipients.reduce((s, r) => s + r.bps, 0);
  const totalPos = value.positions.reduce((s, p) => s + p.bps, 0);

  return (
    <div className="space-y-6">
      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <h4 className="text-sm font-medium text-zinc-300">
            Reward recipients{' '}
            <span className={total === target ? 'text-green-400' : 'text-amber-400'}>({total} / {target} bps)</span>
          </h4>
          <div className="flex gap-3">
            <button type="button" onClick={rebalance} className="text-xs text-zinc-400 hover:text-white">Split evenly</button>
            <button type="button" onClick={addRecipient} disabled={value.recipients.length >= maxProject} className="text-xs text-violet-400 hover:text-violet-300 disabled:text-zinc-600 disabled:cursor-not-allowed">+ Add recipient</button>
          </div>
        </div>
        <p className="text-xs text-zinc-500">
          Shares are of all LP rewards in basis points. The factory adds a protocol slot of {protocolBps / 100}% ({protocolBps} bps, read from the
          factory), so your recipients must add up to {target} bps ({target / 100}%), not {BPS}. At most {maxProject} recipients.
        </p>

        {value.recipients.map((r, i) => (
          <div key={i} className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-3 space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-xs font-medium text-zinc-400">Recipient {i + 1}</span>
              {value.recipients.length > 1 && (
                <button type="button" onClick={() => removeRecipient(i)} className="text-xs text-red-400 hover:text-red-300">Remove</button>
              )}
            </div>
            <div className="grid grid-cols-3 gap-2">
              <div className="col-span-2">
                <label className="text-xs text-zinc-500">Address</label>
                <input type="text" className={inputClass} placeholder={connectedAddress ?? '0x...'} value={r.recipient} onChange={(e) => updateRecipient(i, { recipient: e.target.value })} />
              </div>
              <div>
                <label className="text-xs text-zinc-500">Share (bps)</label>
                <input type="number" className={inputClass} min={0} max={target} value={r.bps} onChange={(e) => updateRecipient(i, { bps: Math.round(Number(e.target.value)) })} />
              </div>
            </div>
          </div>
        ))}
        {protocolBps > 0 && (
          <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 py-2 text-xs text-zinc-400 flex justify-between">
            <span>Protocol slot (added by the factory)</span>
            <span>{protocolBps} bps ({protocolBps / 100}%)</span>
          </div>
        )}
        <Issues issues={issues} prefix="rewards" />
      </div>

      <div className="space-y-3">
        <div className="flex items-center justify-between">
          <h4 className="text-sm font-medium text-zinc-300">
            LP positions <span className={totalPos === BPS ? 'text-green-400' : 'text-amber-400'}>({totalPos} / {BPS} bps)</span>
          </h4>
          <button type="button" onClick={addPosition} disabled={value.positions.length >= MAX_LP_POSITIONS} className="text-xs text-violet-400 hover:text-violet-300 disabled:text-zinc-600">+ Add position</button>
        </div>
        <div className="flex flex-wrap gap-2">
          {(Object.keys(PRESET_LABELS) as PositionPreset[]).map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => setPreset(p)}
              disabled={p !== 'custom' && !presetOk}
              className={`rounded-lg px-3 py-1.5 text-xs font-medium ${value.preset === p ? 'bg-violet-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:text-white disabled:opacity-40'}`}
            >
              {PRESET_LABELS[p]}
            </button>
          ))}
        </div>
        {!presetOk && <p className="text-xs text-amber-400">The presets need a starting tick that is a multiple of 200 and tick spacing 200, 60 or 10 steps of 200. Use custom positions.</p>}
        <p className="text-xs text-zinc-500">
          Single sided liquidity in the token0 frame: each lower tick is at least the starting tick ({startingTick.toLocaleString()}) and every tick is a multiple of {tickSpacing}.
          Position shares add up to {BPS} bps. These are locked forever, there is no way to remove liquidity.
        </p>
        {value.positions.map((p, i) => (
          <div key={i} className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-3 space-y-2">
            <div className="flex items-center justify-between">
              <span className="text-xs font-medium text-zinc-400">Position {i + 1}</span>
              {value.positions.length > 1 && (
                <button type="button" onClick={() => removePosition(i)} className="text-xs text-red-400 hover:text-red-300">Remove</button>
              )}
            </div>
            <div className="grid grid-cols-3 gap-2">
              <div>
                <label className="text-xs text-zinc-500">Tick lower</label>
                <input type="number" className={`${inputClass} ${p.tickLower < startingTick || p.tickLower % tickSpacing !== 0 ? 'border-red-500' : ''}`} value={p.tickLower} onChange={(e) => updatePosition(i, { tickLower: Number(e.target.value) })} />
              </div>
              <div>
                <label className="text-xs text-zinc-500">Tick upper</label>
                <input type="number" className={`${inputClass} ${p.tickUpper <= p.tickLower || p.tickUpper % tickSpacing !== 0 ? 'border-red-500' : ''}`} value={p.tickUpper} onChange={(e) => updatePosition(i, { tickUpper: Number(e.target.value) })} />
              </div>
              <div>
                <label className="text-xs text-zinc-500">Share (bps)</label>
                <input type="number" className={inputClass} min={0} max={BPS} value={p.bps} onChange={(e) => updatePosition(i, { bps: Math.round(Number(e.target.value)) })} />
              </div>
            </div>
          </div>
        ))}
        <Issues issues={issues} prefix="positions" />
      </div>
    </div>
  );
}
