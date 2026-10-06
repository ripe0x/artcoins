import type { ReactNode } from 'react';
import type { Issue } from '../lib/encodeV2';

import { hintClass, labelClass } from './formStyles';
import { utf8ByteLength } from '../lib/launchRules';

export function Toggle({ enabled, onToggle, label }: { enabled: boolean; onToggle: () => void; label: string }) {
  return (
    <button type="button" onClick={onToggle} className="flex items-center gap-3 w-full" aria-pressed={enabled}>
      <div className={`relative w-10 h-5 rounded-full transition-colors ${enabled ? 'bg-violet-600' : 'bg-zinc-700'}`}>
        <div className={`absolute top-0.5 w-4 h-4 rounded-full bg-white transition-transform ${enabled ? 'translate-x-5' : 'translate-x-0.5'}`} />
      </div>
      <span className="text-sm font-medium text-white">{label}</span>
    </button>
  );
}

/** Issues of a form section, matched by field prefix. */
export function Issues({ issues, prefix }: { issues: Issue[]; prefix: string | string[] }) {
  const prefixes = Array.isArray(prefix) ? prefix : [prefix];
  const mine = issues.filter((i) => prefixes.some((p) => i.field === p || i.field.startsWith(`${p}.`)));
  if (mine.length === 0) return null;
  return (
    <ul className="space-y-0.5 text-xs">
      {mine.map((i, n) => (
        <li key={n} className={i.severity === 'error' ? 'text-red-400' : 'text-amber-400'}>
          {i.message}
        </li>
      ))}
    </ul>
  );
}

export function Field({ label, hint, children }: { label: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <div>
      <label className={labelClass}>{label}</label>
      {children}
      {hint && <p className={hintClass}>{hint}</p>}
    </div>
  );
}

/** Live utf8 byte counter next to a capped string field. The chain caps bytes, not characters. */
export function ByteCount({ value, cap }: { value: string; cap: number }) {
  const n = utf8ByteLength(value);
  return <span className={n > cap ? 'text-red-400' : 'text-zinc-500'}>{n} / {cap} bytes</span>;
}
