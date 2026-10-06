import type { TaxFormState, TaxMode } from '../lib/types';
import type { Issue } from '../lib/encodeV2';
import { Field, Issues } from './formUi';
import { hintClass, inputClass } from './formStyles';
import { MAX_TAX_EXEMPT, TAX_BPS_ABSOLUTE_MAX } from '../lib/constants';
import { EXEMPT_NOT_ALLOWED, type ExemptStatusMap } from '../lib/launchRules';
import { parseAddress } from '../lib/encodeV2';

interface Props {
  value: TaxFormState;
  onChange: (v: TaxFormState) => void;
  issues: Issue[];
  /** factory allowlist answers per exempt entry, null without a configured factory */
  exemptStatus: ExemptStatusMap | null;
  factoryConfigured: boolean;
}

const MODES: { value: TaxMode; label: string; desc: string }[] = [
  { value: 0, label: 'No tax', desc: 'Plain transfers, the default. Liquidity on the canonical pool stays open to anyone.' },
  {
    value: 1,
    label: 'Venue tax (VENUE)',
    desc: 'Side pools are taxed: coin leaving a listed venue (a v2 or v3 pool) to a non exempt wallet pays the tax. Side pools still trade.',
  },
  {
    value: 2,
    label: 'Hard mode (HARD)',
    desc: 'Side pools are blocked: only flows the canonical hook granted in the same transaction work, and any transfer touching a listed venue reverts.',
  },
];

export default function TaxForm({ value, onChange, issues, exemptStatus, factoryConfigured }: Props) {
  const set = <K extends keyof TaxFormState>(field: K, val: TaxFormState[K]) => onChange({ ...value, [field]: val });
  // entries the factory is asked about: valid addresses only (the validator reports the rest)
  const exemptList = value.mode === 1 ? value.exempt.split(/[\s,]+/).filter((a) => a && parseAddress(a)) : [];
  // the per entry allowlist answers are shown in the list above, not repeated in the issue list
  const shownIssues = issues.filter((i) => !i.field.startsWith('tax.exempt.allowlist'));
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
        <div className="rounded-lg border border-zinc-700 bg-zinc-800/40 px-4 py-3 text-xs text-zinc-400 space-y-2">
          <p>
            <span className="text-zinc-200">Liquidity on the canonical pool is locker only.</span> On a taxed coin (either mode) only the locker, at launch,
            can add liquidity to the canonical pool. Anyone else who wants to provide liquidity must use a side pool, which is taxed in venue mode and
            blocked in hard mode. With no tax the canonical pool stays open to everyone.
          </p>
          {value.mode === 2 && (
            <p className="text-amber-300">
              Hard mode blocks every transfer touching a listed venue. If a v2 pair for this coin is listed as a venue later, its liquidity providers
              cannot withdraw: their weth is trapped along with the coin. Do not list a v2 pair that already has liquidity.
            </p>
          )}
        </div>
      )}

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
              <p className={hintClass}>
                Separate with commas or spaces. Only contracts the launcher owner has allowlisted (or this launch's locker and hook, an enabled escrow or
                an enabled extension) can be exempt. Entries must be contracts.
              </p>
              {exemptList.length > 0 && (
                <ul className="mt-2 space-y-0.5 text-xs">
                  {exemptList.map((a) => {
                    const st = exemptStatus?.[a.toLowerCase()];
                    if (!factoryConfigured || !exemptStatus) return <li key={a} className="text-zinc-500 break-all">{a}: not checked, no factory configured</li>;
                    if (st === 'allowed') return <li key={a} className="text-emerald-400 break-all">{a}: allowed</li>;
                    if (st === 'not-allowed') return <li key={a} className="text-red-400 break-all">{a}: {EXEMPT_NOT_ALLOWED}</li>;
                    return <li key={a} className="text-amber-400 break-all">{a}: checking the launcher allowlist...</li>;
                  })}
                </ul>
              )}
            </Field>
          )}
        </>
      )}
      <Issues issues={shownIssues} prefix="tax" />
    </div>
  );
}
