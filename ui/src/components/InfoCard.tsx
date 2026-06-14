import type { ReactNode } from 'react';

interface Props {
  title: string;
  action?: ReactNode;
  children: ReactNode;
}

export default function InfoCard({ title, action, children }: Props) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900">
      <div className="flex items-center justify-between px-5 py-3 border-b border-zinc-800">
        <h3 className="text-xs font-semibold uppercase tracking-wider text-zinc-400">{title}</h3>
        {action}
      </div>
      <div className="px-5 py-3 space-y-0.5">{children}</div>
    </div>
  );
}
