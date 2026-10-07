/**
 * Resolves the referrer credited on a swap, in priority order:
 *
 *   1. `?ref=0x...` in the current url. Kept for the browser session only (sessionStorage), never in
 *      localStorage, so a crafted link cannot replace the default referrer forever (UI-17).
 *   2. the value stored earlier in this session.
 *   3. `defaultReferrer` from `/config.json`, fetched fresh (no cache) so operator edits propagate.
 *   4. none: the hook leaves the referral slice with the protocol.
 *
 * A candidate is accepted only when it is a valid address (mixed case must carry a correct checksum),
 * is not the zero address and is not the connected wallet. The referral is carved from the protocol
 * side of the skim, the trader never pays more or less because of it.
 *
 * The ui always shows the active referrer and lets the user turn it off for the session.
 */
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { useAccount } from 'wagmi';
import type { Address } from 'viem';
import { checkReferrer } from './referrerCheck';

const STORAGE_KEY = 'artcoins:referrer';
const OPTOUT_KEY = 'artcoins:referrer:optout';

export type ReferrerSource = 'link' | 'session' | 'default';

export interface ReferrerState {
  referrer: Address | null;
  source: ReferrerSource | null;
  /** why a candidate was dropped, shown next to the indicator */
  rejected: string | null;
  optedOut: boolean;
  optOut: () => void;
  optIn: () => void;
}

let runtimeDefault: Address | null = null;
let runtimeFetch: Promise<Address | null> | null = null;

function fetchRuntimeDefault(): Promise<Address | null> {
  if (runtimeDefault) return Promise.resolve(runtimeDefault);
  if (runtimeFetch) return runtimeFetch;
  runtimeFetch = (async () => {
    try {
      const res = await fetch('/config.json', { cache: 'no-cache' });
      if (!res.ok) return null;
      const data = (await res.json()) as { defaultReferrer?: unknown };
      const c = checkReferrer(typeof data?.defaultReferrer === 'string' ? data.defaultReferrer : null);
      if (!c.ok) return null;
      runtimeDefault = c.address;
      return c.address;
    } catch {
      return null;
    } finally {
      runtimeFetch = null;
    }
  })();
  return runtimeFetch;
}

function readSession(key: string): string | null {
  try {
    return window.sessionStorage.getItem(key);
  } catch {
    return null;
  }
}
function writeSession(key: string, value: string | null) {
  try {
    if (value === null) window.sessionStorage.removeItem(key);
    else window.sessionStorage.setItem(key, value);
  } catch {
    // storage can be blocked (private mode), the referrer then lives only in memory for this page view
  }
}

export function useReferrer(): ReferrerState {
  const { address: self } = useAccount();
  const { search } = useLocation();
  const [defaultRef, setDefaultRef] = useState<Address | null>(runtimeDefault);
  const [optedOut, setOptedOut] = useState<boolean>(() => readSession(OPTOUT_KEY) === '1');

  useEffect(() => {
    let cancelled = false;
    void fetchRuntimeDefault().then((v) => {
      if (!cancelled) setDefaultRef(v);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const linkRaw = useMemo(() => new URLSearchParams(search).get('ref'), [search]);

  // a valid link value is remembered for this session only
  useEffect(() => {
    if (!linkRaw) return;
    const c = checkReferrer(linkRaw);
    if (c.ok) writeSession(STORAGE_KEY, c.address);
  }, [linkRaw]);

  const optOut = useCallback(() => {
    writeSession(OPTOUT_KEY, '1');
    setOptedOut(true);
  }, []);
  const optIn = useCallback(() => {
    writeSession(OPTOUT_KEY, null);
    setOptedOut(false);
  }, []);

  return useMemo<ReferrerState>(() => {
    let rejected: string | null = null;
    const candidates: [ReferrerSource, string | null][] = [
      ['link', linkRaw],
      ['session', readSession(STORAGE_KEY)],
      ['default', defaultRef],
    ];
    let found: { address: Address; source: ReferrerSource } | null = null;
    for (const [source, raw] of candidates) {
      if (!raw) continue;
      const c = checkReferrer(raw, self);
      if (c.ok) {
        found = { address: c.address, source };
        break;
      }
      if (source === 'link') rejected = `ignored ?ref: ${c.reason}`;
    }
    return {
      referrer: optedOut ? null : (found?.address ?? null),
      source: optedOut ? null : (found?.source ?? null),
      rejected,
      optedOut,
      optOut,
      optIn,
    };
  }, [linkRaw, defaultRef, self, optedOut, optOut, optIn]);
}
