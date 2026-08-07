import { useEffect } from 'react';
import type { RewardsFormState, RewardRecipient, LpPosition } from '../lib/types';
import { validatePositionTicks } from '../lib/validate';

const inputClass =
  'w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white placeholder-zinc-500 focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500';

const MAX_TICK = 887220;

// Round a tick up to the nearest multiple of tickSpacing
function roundUpToSpacing(tick: number, spacing: number): number {
  if (spacing <= 0) return tick;
  const remainder = tick % spacing;
  if (remainder === 0) return tick;
  return tick + (spacing - (remainder < 0 ? remainder + spacing : remainder));
}

// Round a tick down to the nearest multiple of tickSpacing
function roundDownToSpacing(tick: number, spacing: number): number {
  if (spacing <= 0) return tick;
  const remainder = tick % spacing;
  if (remainder === 0) return tick;
  return tick - (remainder < 0 ? remainder + spacing : remainder);
}

interface Props {
  value: RewardsFormState;
  onChange: (v: RewardsFormState) => void;
  connectedAddress: string | undefined;
  startingTick: number;
  tickSpacing: number;
}

export default function RewardsForm({
  value,
  onChange,
  connectedAddress,
  startingTick,
  tickSpacing,
}: Props) {
  // In simple mode, keep the position range synced to the starting tick.
  // Single-sided liquidity requires tickLower >= startingTick.
  useEffect(() => {
    if (value.mode === 'simple') {
      const tickLower = roundUpToSpacing(startingTick, tickSpacing);
      const tickUpper = roundDownToSpacing(MAX_TICK, tickSpacing);
      const r = value.recipients[0];
      const needsRecipientUpdate =
        connectedAddress && !r.admin && !r.recipient;
      const needsPositionUpdate =
        value.positions[0]?.tickLower !== tickLower ||
        value.positions[0]?.tickUpper !== tickUpper;
      if (needsRecipientUpdate || needsPositionUpdate) {
        onChange({
          ...value,
          recipients: needsRecipientUpdate
            ? [{ admin: connectedAddress!, recipient: connectedAddress!, bps: 10000 }]
            : value.recipients,
          positions: [{ tickLower, tickUpper, bps: 10000 }],
        });
      }
    }
  }, [connectedAddress, startingTick, tickSpacing, value.mode]);

  const setMode = (mode: 'simple' | 'advanced') => {
    if (mode === 'simple') {
      const tickLower = roundUpToSpacing(startingTick, tickSpacing);
      const tickUpper = roundDownToSpacing(MAX_TICK, tickSpacing);
      onChange({
        ...value,
        mode,
        recipients: [{ admin: connectedAddress ?? '', recipient: connectedAddress ?? '', bps: 10000 }],
        positions: [{ tickLower, tickUpper, bps: 10000 }],
      });
    } else {
      onChange({ ...value, mode });
    }
  };

  const updateRecipient = (idx: number, patch: Partial<RewardRecipient>) => {
    const updated = value.recipients.map((r, i) => (i === idx ? { ...r, ...patch } : r));
    onChange({ ...value, recipients: updated });
  };

  const addRecipient = () => {
    if (value.recipients.length >= 7) return;
    onChange({
      ...value,
      recipients: [...value.recipients, { admin: connectedAddress ?? '', recipient: '', bps: 0 }],
    });
  };

  const removeRecipient = (idx: number) => {
    onChange({ ...value, recipients: value.recipients.filter((_, i) => i !== idx) });
  };

  const updatePosition = (idx: number, patch: Partial<LpPosition>) => {
    const updated = value.positions.map((p, i) => (i === idx ? { ...p, ...patch } : p));
    onChange({ ...value, positions: updated });
  };

  const addPosition = () => {
    const defaultLower = roundUpToSpacing(startingTick, tickSpacing);
    const defaultUpper = roundDownToSpacing(MAX_TICK, tickSpacing);
    onChange({
      ...value,
      positions: [...value.positions, { tickLower: defaultLower, tickUpper: defaultUpper, bps: 0 }],
    });
  };

  const removePosition = (idx: number) => {
    onChange({ ...value, positions: value.positions.filter((_, i) => i !== idx) });
  };

  const totalRecipientBps = value.recipients.reduce((s, r) => s + r.bps, 0);
  const totalPositionBps = value.positions.reduce((s, p) => s + p.bps, 0);

  return (
    <div className="space-y-5">
      <div className="flex gap-2">
        {(['simple', 'advanced'] as const).map(m => (
          <button
            key={m}
            type="button"
            onClick={() => setMode(m)}
            className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
              value.mode === m
                ? 'bg-violet-600 text-white'
                : 'bg-zinc-800 text-zinc-400 hover:text-white'
            }`}
          >
            {m === 'simple' ? 'Simple' : 'Advanced'}
          </button>
        ))}
      </div>

      {value.mode === 'simple' && (
        <div className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-4 space-y-2">
          <p className="text-sm text-zinc-300">
            All LP rewards go to your connected wallet. Position is set to single-sided liquidity
            starting at the pool's initial tick.
          </p>
          <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm">
            <div className="text-zinc-500">Recipient</div>
            <div className="text-white font-mono text-xs truncate">{connectedAddress ?? 'Connect wallet'}</div>
            <div className="text-zinc-500">BPS</div>
            <div className="text-white">10,000 (100%)</div>
            <div className="text-zinc-500">Tick Range</div>
            <div className="text-white">
              {value.positions[0]?.tickLower.toLocaleString()} to{' '}
              {value.positions[0]?.tickUpper.toLocaleString()}
            </div>
          </div>
          <p className="text-xs text-zinc-500 pt-1">
            Auto-synced to starting tick ({startingTick.toLocaleString()}). Only the new token is
            provided as liquidity — buyers supply the paired token.
          </p>
        </div>
      )}

      {value.mode === 'advanced' && (
        <>
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <h4 className="text-sm font-medium text-zinc-300">
                Reward Recipients{' '}
                <span className={totalRecipientBps === 10000 ? 'text-green-400' : 'text-amber-400'}>
                  ({totalRecipientBps} / 10,000 BPS)
                </span>
              </h4>
              <button
                type="button"
                onClick={addRecipient}
                disabled={value.recipients.length >= 7}
                className="text-xs text-violet-400 hover:text-violet-300 disabled:text-zinc-600 disabled:cursor-not-allowed"
              >
                + Add Recipient
              </button>
            </div>

            {value.recipients.map((r, i) => (
              <div key={i} className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-3 space-y-2">
                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium text-zinc-400">Recipient {i + 1}</span>
                  {value.recipients.length > 1 && (
                    <button
                      type="button"
                      onClick={() => removeRecipient(i)}
                      className="text-xs text-red-400 hover:text-red-300"
                    >
                      Remove
                    </button>
                  )}
                </div>
                <div className="grid grid-cols-2 gap-2">
                  <div>
                    <label className="text-xs text-zinc-500">Admin Address</label>
                    <input
                      type="text"
                      className={inputClass}
                      placeholder="0x..."
                      value={r.admin}
                      onChange={e => updateRecipient(i, { admin: e.target.value })}
                    />
                  </div>
                  <div>
                    <label className="text-xs text-zinc-500">Recipient Address</label>
                    <input
                      type="text"
                      className={inputClass}
                      placeholder="0x..."
                      value={r.recipient}
                      onChange={e => updateRecipient(i, { recipient: e.target.value })}
                    />
                  </div>
                </div>
                <div>
                  <label className="text-xs text-zinc-500">BPS (basis points, max 10000)</label>
                  <input
                    type="number"
                    className={inputClass}
                    min={0}
                    max={10000}
                    value={r.bps}
                    onChange={e => updateRecipient(i, { bps: Number(e.target.value) })}
                  />
                </div>
              </div>
            ))}
          </div>

          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <h4 className="text-sm font-medium text-zinc-300">
                LP Positions{' '}
                <span className={totalPositionBps === 10000 ? 'text-green-400' : 'text-amber-400'}>
                  ({totalPositionBps} / 10,000 BPS)
                </span>
              </h4>
              <button
                type="button"
                onClick={addPosition}
                className="text-xs text-violet-400 hover:text-violet-300"
              >
                + Add Position
              </button>
            </div>

            <p className="text-xs text-zinc-500">
              Single-sided liquidity: Tick Lower must be ≥ starting tick (
              {startingTick.toLocaleString()}). Ticks must be multiples of{' '}
              {tickSpacing}.
            </p>

            {value.positions.map((p, i) => {
              const { invalidLower, invalidSpacing, invalidRange } = validatePositionTicks(
                p.tickLower,
                p.tickUpper,
                startingTick,
                tickSpacing
              );
              return (
              <div key={i} className="rounded-lg border border-zinc-700 bg-zinc-800/50 p-3 space-y-2">
                <div className="flex items-center justify-between">
                  <span className="text-xs font-medium text-zinc-400">Position {i + 1}</span>
                  {value.positions.length > 1 && (
                    <button
                      type="button"
                      onClick={() => removePosition(i)}
                      className="text-xs text-red-400 hover:text-red-300"
                    >
                      Remove
                    </button>
                  )}
                </div>
                <div className="grid grid-cols-3 gap-2">
                  <div>
                    <label className="text-xs text-zinc-500">Tick Lower</label>
                    <input
                      type="number"
                      className={`${inputClass} ${invalidLower ? 'border-red-500' : ''}`}
                      value={p.tickLower}
                      onChange={e => updatePosition(i, { tickLower: Number(e.target.value) })}
                    />
                  </div>
                  <div>
                    <label className="text-xs text-zinc-500">Tick Upper</label>
                    <input
                      type="number"
                      className={inputClass}
                      value={p.tickUpper}
                      onChange={e => updatePosition(i, { tickUpper: Number(e.target.value) })}
                    />
                  </div>
                  <div>
                    <label className="text-xs text-zinc-500">BPS</label>
                    <input
                      type="number"
                      className={inputClass}
                      min={0}
                      max={10000}
                      value={p.bps}
                      onChange={e => updatePosition(i, { bps: Number(e.target.value) })}
                    />
                  </div>
                </div>
                {(invalidLower || invalidSpacing || invalidRange) && (
                  <div className="space-y-0.5 text-xs text-red-400">
                    {invalidLower && (
                      <p>
                        Tick Lower ({p.tickLower.toLocaleString()}) must be ≥ starting tick (
                        {startingTick.toLocaleString()}).
                      </p>
                    )}
                    {invalidSpacing && (
                      <p>Ticks must be multiples of the pool's tick spacing ({tickSpacing}).</p>
                    )}
                    {invalidRange && <p>Tick Upper must be greater than Tick Lower.</p>}
                  </div>
                )}
              </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}
