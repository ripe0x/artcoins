import type { MevFormState } from '../lib/types';
import type { Issue } from '../lib/encodeV2';
import { Issues, Toggle } from './formUi';
import { hintClass } from './formStyles';
import { MAX_MEV_WINDOW, MAX_SKIM_BPS, MIN_MEV_WINDOW } from '../lib/constants';

interface Props {
  value: MevFormState;
  onChange: (v: MevFormState) => void;
  issues: Issue[];
  baselinePercent: number;
  moduleConfigured: boolean;
}

function DecayChart({ start, end, windowMin }: { start: number; end: number; windowMin: number }) {
  const w = 320;
  const h = 140;
  const pad = { top: 20, right: 20, bottom: 30, left: 45 };
  const plotW = w - pad.left - pad.right;
  const plotH = h - pad.top - pad.bottom;
  const maxV = Math.max(start, end, 10);
  const pts: string[] = [];
  for (let i = 0; i <= 60; i++) {
    const t = i / 60;
    const v = start + (end - start) * t; // linear decay to the baseline
    pts.push(`${pad.left + t * plotW},${pad.top + (1 - v / maxV) * plotH}`);
  }
  return (
    <svg viewBox={`0 0 ${w} ${h}`} className="w-full max-w-sm" fill="none">
      <rect x={pad.left} y={pad.top} width={plotW} height={plotH} fill="#18181b" rx={4} />
      {[0, Math.round(maxV / 2), Math.round(maxV)].map((tick) => {
        const y = pad.top + (1 - tick / maxV) * plotH;
        return (
          <g key={tick}>
            <line x1={pad.left} y1={y} x2={pad.left + plotW} y2={y} stroke="#3f3f46" strokeDasharray="4,4" />
            <text x={pad.left - 6} y={y + 4} textAnchor="end" className="text-[10px] fill-zinc-500">{tick}%</text>
          </g>
        );
      })}
      <text x={pad.left} y={h - 4} className="text-[10px] fill-zinc-500">0</text>
      <text x={pad.left + plotW} y={h - 4} textAnchor="end" className="text-[10px] fill-zinc-500">{windowMin}m</text>
      <polyline points={pts.join(' ')} stroke="#7c3aed" strokeWidth={2} fill="none" />
    </svg>
  );
}

export default function AntiSniperForm({ value, onChange, issues, baselinePercent, moduleConfigured }: Props) {
  const set = <K extends keyof MevFormState>(field: K, val: MevFormState[K]) => onChange({ ...value, [field]: val });
  return (
    <div className="space-y-5">
      <Toggle enabled={value.enabled} onToggle={() => set('enabled', !value.enabled)} label="Anti-sniper skim" />
      {!moduleConfigured && value.enabled && (
        <p className="text-xs text-amber-400">No anti sniper module is configured for this stack yet, launching with it on is blocked.</p>
      )}
      {value.enabled && (
        <>
          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-1.5">
              Starting skim: <span className="text-violet-400 font-semibold">{value.startPercent}%</span> of volume
            </label>
            <input type="range" min={baselinePercent} max={MAX_SKIM_BPS / 100} step={0.01} value={value.startPercent} onChange={(e) => set('startPercent', Number(e.target.value))} className="w-full accent-violet-500" />
            <p className={hintClass}>Decays linearly to the {baselinePercent}% baseline over the window. The maximum is {MAX_SKIM_BPS / 100}%.</p>
          </div>
          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-1.5">
              Window: <span className="text-violet-400 font-semibold">{value.windowMin} minutes</span>
            </label>
            <input type="range" min={MIN_MEV_WINDOW / 60} max={MAX_MEV_WINDOW / 60} step={1} value={value.windowMin} onChange={(e) => set('windowMin', Number(e.target.value))} className="w-full accent-violet-500" />
            <p className={hintClass}>{MIN_MEV_WINDOW / 60} to {MAX_MEV_WINDOW / 60} minutes. The window starts when the launch transaction lands.</p>
          </div>
          <DecayChart start={value.startPercent} end={baselinePercent} windowMin={value.windowMin} />
        </>
      )}
      <Issues issues={issues} prefix="mev" />
    </div>
  );
}
