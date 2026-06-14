import { formatUnits } from 'viem';

export const shortAddr = (a?: string | null): string => {
  if (!a) return '';
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
};

export const formatSupply = (raw: bigint | undefined, decimals = 18): string => {
  if (raw === undefined) return '—';
  const n = Number(formatUnits(raw, decimals));
  return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
};

/** V4 fee units: 1_000_000 = 100%, so 10_000 = 1% */
export const formatFeeBps = (units: number | undefined): string => {
  if (units === undefined) return '—';
  return `${(units / 10_000).toFixed(2)}%`;
};

export const formatDuration = (sec: bigint | number | undefined): string => {
  if (sec === undefined) return '—';
  const s = typeof sec === 'bigint' ? Number(sec) : sec;
  if (s <= 0) return 'expired';
  const hours = Math.floor(s / 3600);
  const minutes = Math.floor((s % 3600) / 60);
  const seconds = s % 60;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
};

export const formatTimestamp = (ts: bigint | number | undefined): string => {
  if (!ts) return '—';
  const s = typeof ts === 'bigint' ? Number(ts) : ts;
  return new Date(s * 1000).toLocaleString();
};

/** Price of NM token in paired token, formatted for display. */
export const formatPrice = (price: number | undefined): string => {
  if (price === undefined || !isFinite(price) || price === 0) return '—';
  if (price < 0.000001) return price.toExponential(3);
  if (price < 1) return price.toFixed(8);
  return price.toLocaleString(undefined, { maximumFractionDigits: 4 });
};
