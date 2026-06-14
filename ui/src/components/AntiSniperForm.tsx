import type { MevFormState, MevModuleType } from '../lib/types';

const labelClass = 'block text-sm font-medium text-zinc-300 mb-1.5';

interface Props {
  value: MevFormState;
  onChange: (v: MevFormState) => void;
}

function FeeDecayChart({
  startFee,
  endFee,
  duration,
  type,
}: {
  startFee: number;
  endFee: number;
  duration: number;
  type: 'linear' | 'descending';
}) {
  const w = 320;
  const h = 140;
  const pad = { top: 20, right: 20, bottom: 30, left: 45 };
  const plotW = w - pad.left - pad.right;
  const plotH = h - pad.top - pad.bottom;

  const maxFee = Math.max(startFee, endFee, 10);

  const points: string[] = [];
  const steps = 60;
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    let fee: number;
    if (type === 'linear') {
      fee = startFee + (endFee - startFee) * t;
    } else {
      fee = endFee + (startFee - endFee) * (1 - t) * (1 - t);
    }
    const x = pad.left + t * plotW;
    const y = pad.top + (1 - fee / maxFee) * plotH;
    points.push(`${x},${y}`);
  }

  const yTicks = [0, Math.round(maxFee / 2), maxFee];
  const durationLabel =
    duration >= 60 ? `${Math.round(duration / 60)}m` : `${duration}s`;

  return (
    <svg viewBox={`0 0 ${w} ${h}`} className="w-full max-w-sm" fill="none">
      <rect
        x={pad.left}
        y={pad.top}
        width={plotW}
        height={plotH}
        fill="#18181b"
        rx={4}
      />
      {yTicks.map(tick => {
        const y = pad.top + (1 - tick / maxFee) * plotH;
        return (
          <g key={tick}>
            <line
              x1={pad.left}
              y1={y}
              x2={pad.left + plotW}
              y2={y}
              stroke="#3f3f46"
              strokeDasharray="4,4"
            />
            <text
              x={pad.left - 6}
              y={y + 4}
              textAnchor="end"
              className="text-[10px] fill-zinc-500"
            >
              {tick}%
            </text>
          </g>
        );
      })}
      <text
        x={pad.left}
        y={h - 4}
        className="text-[10px] fill-zinc-500"
      >
        0
      </text>
      <text
        x={pad.left + plotW}
        y={h - 4}
        textAnchor="end"
        className="text-[10px] fill-zinc-500"
      >
        {durationLabel}
      </text>
      <polyline
        points={points.join(' ')}
        stroke="#7c3aed"
        strokeWidth={2}
        fill="none"
      />
    </svg>
  );
}

const moduleOptions: { value: MevModuleType; label: string; desc: string }[] = [
  { value: 'none', label: 'None', desc: 'No MEV protection' },
  { value: 'linear', label: 'Linear Fees', desc: 'Recommended - linear fee decay over time' },
  { value: 'descending', label: 'Descending Fees', desc: 'Parabolic fee decay curve' },
  { value: 'timeDelay', label: 'Time Delay', desc: 'Block swaps for a duration after launch' },
];

export default function AntiSniperForm({ value, onChange }: Props) {
  const set = <K extends keyof MevFormState>(field: K, val: MevFormState[K]) =>
    onChange({ ...value, [field]: val });

  return (
    <div className="space-y-5">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {moduleOptions.map(opt => (
          <button
            key={opt.value}
            type="button"
            onClick={() => set('moduleType', opt.value)}
            className={`rounded-lg border px-3 py-3 text-left transition-colors ${
              value.moduleType === opt.value
                ? 'border-violet-500 bg-violet-500/10'
                : 'border-zinc-700 bg-zinc-800 hover:border-zinc-600'
            }`}
          >
            <div className="text-sm font-medium text-white">{opt.label}</div>
            <div className="text-xs text-zinc-500 mt-0.5">{opt.desc}</div>
          </button>
        ))}
      </div>

      {value.moduleType === 'linear' && (
        <div className="space-y-4">
          <div>
            <label className={labelClass}>
              Starting Fee:{' '}
              <span className="text-violet-400 font-semibold">{value.linearStartPercent}%</span>
            </label>
            <input
              type="range"
              min={1}
              max={99}
              value={value.linearStartPercent}
              onChange={e => set('linearStartPercent', Number(e.target.value))}
              className="w-full accent-violet-500"
            />
            <div className="flex justify-between text-xs text-zinc-600">
              <span>1%</span>
              <span>99%</span>
            </div>
          </div>

          <div>
            <label className={labelClass}>
              Ending Fee:{' '}
              <span className="text-violet-400 font-semibold">{value.linearEndPercent}%</span>
            </label>
            <input
              type="range"
              min={0}
              max={10}
              step={0.5}
              value={value.linearEndPercent}
              onChange={e => set('linearEndPercent', Number(e.target.value))}
              className="w-full accent-violet-500"
            />
            <div className="flex justify-between text-xs text-zinc-600">
              <span>0%</span>
              <span>10%</span>
            </div>
          </div>

          <div>
            <label className={labelClass}>
              Duration:{' '}
              <span className="text-violet-400 font-semibold">{value.linearDurationMin} min</span>
            </label>
            <input
              type="range"
              min={1}
              max={180}
              value={value.linearDurationMin}
              onChange={e => set('linearDurationMin', Number(e.target.value))}
              className="w-full accent-violet-500"
            />
            <div className="flex justify-between text-xs text-zinc-600">
              <span>1 min</span>
              <span>180 min</span>
            </div>
          </div>

          <FeeDecayChart
            startFee={value.linearStartPercent}
            endFee={value.linearEndPercent}
            duration={value.linearDurationMin * 60}
            type="linear"
          />
        </div>
      )}

      {value.moduleType === 'descending' && (
        <div className="space-y-4">
          <div>
            <label className={labelClass}>
              Starting Fee:{' '}
              <span className="text-violet-400 font-semibold">{value.descStartPercent}%</span>
            </label>
            <input
              type="range"
              min={1}
              max={99}
              value={value.descStartPercent}
              onChange={e => set('descStartPercent', Number(e.target.value))}
              className="w-full accent-violet-500"
            />
            <div className="flex justify-between text-xs text-zinc-600">
              <span>1%</span>
              <span>99%</span>
            </div>
          </div>

          <div>
            <label className={labelClass}>
              Ending Fee:{' '}
              <span className="text-violet-400 font-semibold">{value.descEndPercent}%</span>
            </label>
            <input
              type="range"
              min={0}
              max={10}
              step={0.5}
              value={value.descEndPercent}
              onChange={e => set('descEndPercent', Number(e.target.value))}
              className="w-full accent-violet-500"
            />
            <div className="flex justify-between text-xs text-zinc-600">
              <span>0%</span>
              <span>10%</span>
            </div>
          </div>

          <div>
            <label className={labelClass}>
              Duration:{' '}
              <span className="text-violet-400 font-semibold">{value.descDurationSec}s</span>
            </label>
            <input
              type="range"
              min={60}
              max={10800}
              step={60}
              value={value.descDurationSec}
              onChange={e => set('descDurationSec', Number(e.target.value))}
              className="w-full accent-violet-500"
            />
            <div className="flex justify-between text-xs text-zinc-600">
              <span>1 min</span>
              <span>180 min</span>
            </div>
          </div>

          <FeeDecayChart
            startFee={value.descStartPercent}
            endFee={value.descEndPercent}
            duration={value.descDurationSec}
            type="descending"
          />
        </div>
      )}

      {value.moduleType === 'timeDelay' && (
        <div>
          <label className={labelClass}>Delay (seconds)</label>
          <input
            type="number"
            min={1}
            max={600}
            value={value.timeDelaySec}
            onChange={e => set('timeDelaySec', Number(e.target.value))}
            className="w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          />
          <p className="text-xs text-zinc-500 mt-1">
            Swaps will be blocked for this many seconds after token deployment.
          </p>
        </div>
      )}
    </div>
  );
}
