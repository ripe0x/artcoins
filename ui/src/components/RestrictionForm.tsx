import type { RestrictionFormState } from '../lib/types';
import type { Issue } from '../lib/encodeV2';
import { Field, Issues } from './formUi';
import { hintClass, inputClass } from './formStyles';
import { MAX_ALLOWED } from '../lib/constants';

interface Props {
  value: RestrictionFormState;
  onChange: (v: RestrictionFormState) => void;
  issues: Issue[];
}

export default function RestrictionForm({ value, onChange, issues }: Props) {
  const set = <K extends keyof RestrictionFormState>(field: K, val: RestrictionFormState[K]) => onChange({ ...value, [field]: val });
  return (
    <div className="space-y-4">
      <label className="flex items-start gap-3 rounded-lg border border-zinc-700 bg-zinc-800/40 px-4 py-3 cursor-pointer">
        <input type="checkbox" className="mt-1" checked={value.restricted} onChange={(e) => set('restricted', e.target.checked)} />
        <span>
          <span className="block text-sm font-medium text-white">Restrict transfers</span>
          <span className="block text-xs text-zinc-500 mt-1">
            Holders can trade the coin in its home pool but cannot send it wallet to wallet. The coin admin can turn the restriction off later, once,
            and can lock the allowlist and the switch permanently. A restricted coin differs from a plain erc20 for other protocols.
          </span>
        </span>
      </label>

      {value.restricted && (
        <Field label={`Allowlist (up to ${MAX_ALLOWED} entries including the launcher's own)`}>
          <textarea rows={2} className={`${inputClass} resize-none`} placeholder="0x..., 0x..." value={value.allowed} onChange={(e) => set('allowed', e.target.value)} />
          <p className={hintClass}>
            Optional. Separate with commas or spaces. A transfer passes when either side is on the list. The launcher adds this launch's locker, the fee
            escrow, the selected extensions and its owner defaults.
          </p>
          <p className="mt-2 text-xs text-amber-300">
            Only add contracts whose payouts are fixed by their own code. Never add routers, aggregators, multicall contracts or smart wallets: an
            allowlisted address lets anyone move the coin through it.
          </p>
        </Field>
      )}
      <Issues issues={issues} prefix="restriction" />
    </div>
  );
}
