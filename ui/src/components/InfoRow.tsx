import type { ReactNode } from 'react';

interface Props {
  label: string;
  value: ReactNode;
}

export default function InfoRow({ label, value }: Props) {
  return (
    <div className="flex justify-between gap-4 py-1.5 border-b border-zinc-800 last:border-0">
      <span className="text-sm text-zinc-500 flex-shrink-0">{label}</span>
      <span className="text-sm text-white text-right max-w-[60%] break-all">{value}</span>
    </div>
  );
}
