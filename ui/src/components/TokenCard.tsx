import { Link } from 'react-router-dom';
import type { TokenCreatedEvent } from '../lib/events';
import { resolveImage } from '../lib/metadata';
import { shortAddr } from '../lib/format';
import TokenImage from './TokenImage';

interface Props {
  event: TokenCreatedEvent;
}

export default function TokenCard({ event }: Props) {
  const image = resolveImage(undefined, event.tokenImage);

  return (
    <Link
      to={`/tokens/${event.tokenAddress}`}
      className="group rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden hover:border-violet-500/60 transition-colors"
    >
      <div className="aspect-square bg-zinc-800 relative overflow-hidden">
        <TokenImage
          src={image}
          alt={event.tokenSymbol || event.tokenName}
          symbol={event.tokenSymbol || '??'}
          imgClassName="w-full h-full object-cover group-hover:scale-105 transition-transform duration-300"
          fallbackClassName="w-full h-full flex items-center justify-center bg-gradient-to-br from-violet-900/30 to-zinc-900"
          monogramClassName="font-mono text-2xl font-bold text-zinc-600"
        />
      </div>
      <div className="p-4 space-y-1">
        <div className="flex items-baseline justify-between gap-2">
          <h3 className="font-semibold text-white truncate">
            {event.tokenName || 'Unnamed token'}
          </h3>
          <span className="text-xs font-mono text-zinc-500 flex-shrink-0">
            {event.tokenSymbol}
          </span>
        </div>
        <div className="flex items-center justify-between text-xs text-zinc-500">
          <span className="font-mono">{shortAddr(event.tokenAddress)}</span>
          <span>block {event.blockNumber.toString()}</span>
        </div>
      </div>
    </Link>
  );
}
