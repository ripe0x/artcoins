import { Link } from 'react-router-dom';
import type { TokenRecord } from '../lib/discovery';
import { safeImageUrl } from '../lib/security';
import { shortAddr } from '../lib/format';
import OfficialBadge from './OfficialBadge';

interface Props {
  event: TokenRecord;
}

export default function TokenCard({ event }: Props) {
  // images load only from https, ipfs, ar and data:image urls, with no referrer
  const image = safeImageUrl(event.image);

  return (
    <Link
      to={`/tokens/${event.token}`}
      className="group rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden hover:border-violet-500/60 transition-colors"
    >
      <div className="aspect-square bg-zinc-800 relative overflow-hidden">
        {image ? (
          <img
            src={image}
            alt={event.symbol || event.name}
            referrerPolicy="no-referrer"
            loading="lazy"
            decoding="async"
            className="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
            onError={e => {
              (e.currentTarget as HTMLImageElement).style.display = 'none';
            }}
          />
        ) : (
          <div className="w-full h-full flex items-center justify-center bg-gradient-to-br from-violet-900/30 to-zinc-900">
            <span className="font-mono text-2xl font-bold text-zinc-600">
              {(event.symbol || '??').slice(0, 4)}
            </span>
          </div>
        )}
      </div>
      <div className="p-4 space-y-1">
        <div className="flex items-baseline justify-between gap-2">
          <h3 className="font-semibold text-white truncate">
            {event.name || 'Unnamed Token'}
          </h3>
          <span className="text-xs font-mono text-zinc-500 flex-shrink-0">
            {event.symbol}
          </span>
        </div>
        <div className="flex items-center justify-between text-xs text-zinc-500">
          <span className="font-mono">{shortAddr(event.token)}</span>
          <span>block {event.blockNumber.toString()}</span>
        </div>
        <div className="flex flex-wrap items-center gap-1.5 pt-1">
          <OfficialBadge version={event.version} legacy={event.legacy} />
          {event.lookalike && (
            <span className="px-1.5 py-0.5 text-[10px] rounded bg-amber-500/10 text-amber-300 border border-amber-500/30" title="Another token has a very similar name or symbol. Check the contract address.">
              similar name
            </span>
          )}
        </div>
      </div>
    </Link>
  );
}
