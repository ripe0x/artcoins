import type { TaxFormState, TaxMode } from '../lib/types';
import type { Issue } from '../lib/encodeV2';
import { Field, Issues } from './formUi';
import { hintClass, inputClass } from './formStyles';
import { MAX_TAX_EXEMPT, TAX_BPS_ABSOLUTE_MAX } from '../lib/constants';

interface Props {
  value: TaxFormState;
  onChange: (v: TaxFormState) => void;
  issues: Issue[];
}

const MODES: { value: TaxMode; label: string; desc: string }[] = [
  { value: 0, label: 'No tax', desc: 'Plain transfers, the default.' },
  { value: 1, label: 'Venue tax', desc: 'Tax on coin leaving a listed venue (a v2 or v3 pool) to a non exempt wallet.' },
  { value: 2, label: 'Hard mode', desc: 'Only flows the canonical hook granted in the same transaction are allowed. Transfers touching a listed venue are blocked.' },
];

export default function TaxForm({ value, onChange, issues }: Props) {
  const set = <K extends keyof TaxFormState>(field: K, val: TaxFormState[K]) => onChange({ ...value, [field]: val });
  return (
    <div className="space-y-4">
      <p className="text-xs text-zinc-500">The tax mode, the cap and the sink are fixed at launch and cannot be changed. A tax makes the coin unlike a plain erc20 for other protocols.</p>
      <div className="grid gap-3 sm:grid-cols-3">
        {MODES.map((m) => (
          <button key={m.value} type="button" onClick={() => set('mode', m.value)} className={`rounded-lg border p-3 text-left ${value.mode === m.value ? 'border-violet-500 bg-violet-950/20' : 'border-zinc-700 bg-zinc-800/40 hover:border-zinc-500'}`}>
            <div className="text-sm font-medium text-white">{m.label}</div>
            <div className="text-xs text-zinc-500 mt-1">{m.desc}</div>
          </button>
        ))}
      </div>

      {value.mode !== 0 && (
        <>
          {value.mode === 1 && (
            <div className="grid grid-cols-2 gap-4">
              <Field label="Starting tax (%)">
                <input type="number" min={0} max={TAX_BPS_ABSOLUTE_MAX / 100} step={0.01} className={inputClass} value={value.taxPercent} onChange={(e) => set('taxPercent', Number(e.target.value))} />
              </Field>
              <Field label="Maximum tax (%)" hint={`Hard ceiling ${TAX_BPS_ABSOLUTE_MAX / 100}%. The admin can move the rate only up to this.`}>
                <input type="number" min={0} max={TAX_BPS_ABSOLUTE_MAX / 100} step={0.01} className={inputClass} value={value.maxPercent} onChange={(e) => set('maxPercent', Number(e.target.value))} />
              </Field>
            </div>
          )}
          <Field label="Tax sink" hint="Where the tax goes: burned, or to the pool's bounty recipient. Nothing else is allowed.">
            <select className={inputClass} value={value.sink} onChange={(e) => set('sink', e.target.value as 'dead' | 'bounty')}>
              <option value="dead">Burn (0x...dEaD)</option>
              <option value="bounty">Bounty recipient</option>
            </select>
          </Field>
          <Field label="Venue admin" hint="May add tax venues until it renounces. Empty means the token admin.">
            <input type="text" className={inputClass} placeholder="0x... or empty" value={value.venueAdmin} onChange={(e) => set('venueAdmin', e.target.value)} />
          </Field>
          {value.mode === 1 && (
            <Field label={`Exempt addresses (up to ${MAX_TAX_EXEMPT})`}>
              <textarea rows={2} className={`${inputClass} resize-none`} placeholder="0x..., 0x..." value={value.exempt} onChange={(e) => set('exempt', e.target.value)} />
              <p className={hintClass}>Separate with commas or spaces.</p>
            </Field>
          )}
        </>
      )}
      <Issues issues={issues} prefix="tax" />
    </div>
  );
}
