import { shortAddr } from '../lib/format';
import type { ReferrerState } from '../lib/useReferrer';

const SOURCE_LABEL = { link: 'from your link', session: 'from an earlier link this session', default: 'site default' } as const;

/** Always visible: who is credited on this swap, why, and a way out. */
export default function ReferrerNotice({ state }: { state: ReferrerState }) {
  const { referrer, source, rejected, optedOut, optOut, optIn } = state;
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 py-2 text-xs text-zinc-400 space-y-1">
      {referrer && source ? (
        <p>
          Referred by <span className="font-mono text-zinc-200" title={referrer}>{shortAddr(referrer)}</span>{' '}
          ({SOURCE_LABEL[source]}). It comes out of the protocol's share of the fee, you pay the same.{' '}
          <button type="button" onClick={optOut} className="text-violet-400 hover:text-violet-300 underline">
            Don't use a referrer
          </button>
        </p>
      ) : optedOut ? (
        <p>
          No referrer on this swap.{' '}
          <button type="button" onClick={optIn} className="text-violet-400 hover:text-violet-300 underline">
            Undo
          </button>
        </p>
      ) : (
        <p>No referrer on this swap.</p>
      )}
      {rejected && <p className="text-amber-400">{rejected}</p>}
    </div>
  );
}
