/**
 * Resolves the referrer address for a swap, in priority order:
 *
 *   1. `?ref=0x...` in the URL (current visit). Persisted to localStorage.
 *   2. Previously stored value in localStorage (sticky from a prior `?ref`).
 *   3. `defaultReferrer` from `/config.json` — the artcoins-operator
 *      fallback, served as a static asset from `ui/public/config.json`.
 *      Runtime-tunable: the operator edits and re-uploads the JSON to
 *      swap the default without a frontend rebuild. Fetched once per
 *      session and cached in module memory. NOT written to localStorage.
 *   4. `null` — no attribution. Hook leaves the referral slice in the
 *      protocol leg.
 *
 * Async note: the runtime default arrives a fraction of a second after
 * mount. A swap that fires before `/config.json` resolves uses URL/storage
 * if available, else `null` (no operator-default applied). Acceptable
 * tradeoff for runtime tunability — see permanent-collection's
 * `app/lib/swap/useReferrer.ts` for the same pattern.
 *
 * Vite analogue of permanent-collection/app/lib/swap/useReferrer.ts.
 */

import { useEffect, useState } from 'react';
import { getAddress, isAddress } from 'viem';

const STORAGE_KEY = 'artcoins:referrer';

/** Module-level cache for the runtime `defaultReferrer`. Populated on
 *  first fetch; subsequent mounts read it synchronously. */
let runtimeDefault: `0x${string}` | null = null;
let runtimeFetchPromise: Promise<`0x${string}` | null> | null = null;

function fetchRuntimeDefault(): Promise<`0x${string}` | null> {
  if (runtimeDefault !== null) return Promise.resolve(runtimeDefault);
  if (runtimeFetchPromise) return runtimeFetchPromise;
  runtimeFetchPromise = (async () => {
    try {
      const res = await fetch('/config.json', { cache: 'no-cache' });
      if (!res.ok) return null;
      const data = (await res.json()) as { defaultReferrer?: unknown };
      const raw = data?.defaultReferrer;
      if (typeof raw !== 'string') return null;
      if (!isAddress(raw, { strict: false })) return null;
      try {
        const checksummed = getAddress(raw);
        if (checksummed === '0x0000000000000000000000000000000000000000') {
          return null;
        }
        runtimeDefault = checksummed;
        return checksummed;
      } catch {
        return null;
      }
    } catch {
      return null;
    } finally {
      runtimeFetchPromise = null;
    }
  })();
  return runtimeFetchPromise;
}

function normalize(raw: string | null): `0x${string}` | null {
  if (!raw) return null;
  if (!isAddress(raw, { strict: false })) return null;
  try {
    return getAddress(raw);
  } catch {
    return null;
  }
}

function readStorage(): `0x${string}` | null {
  if (typeof window === 'undefined') return null;
  try {
    return normalize(window.localStorage.getItem(STORAGE_KEY));
  } catch {
    return null;
  }
}

function writeStorage(value: `0x${string}` | null) {
  if (typeof window === 'undefined') return;
  try {
    if (value) window.localStorage.setItem(STORAGE_KEY, value);
    else window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    // localStorage may be disabled (private browsing). Best-effort only.
  }
}

export function useReferrer(): `0x${string}` | null {
  const [ref, setRef] = useState<`0x${string}` | null>(null);

  useEffect(() => {
    let cancelled = false;
    const resolve = () => {
      if (typeof window === 'undefined') return;
      const params = new URL(window.location.href).searchParams;
      const urlRef = normalize(params.get('ref'));
      if (urlRef) {
        writeStorage(urlRef);
        setRef(urlRef);
        return;
      }
      const stored = readStorage();
      if (stored) {
        setRef(stored);
        return;
      }
      // Set whatever the runtime cache has synchronously, then upgrade
      // once /config.json resolves.
      setRef(runtimeDefault);
      void fetchRuntimeDefault().then((v) => {
        if (cancelled) return;
        const live = normalize(
          new URL(window.location.href).searchParams.get('ref'),
        );
        if (live || readStorage()) return;
        setRef(v);
      });
    };

    resolve();

    const onPop = () => resolve();
    window.addEventListener('popstate', onPop);
    const origPush = window.history.pushState;
    const origReplace = window.history.replaceState;
    window.history.pushState = function patchedPush(...args) {
      const r = origPush.apply(this, args);
      resolve();
      return r;
    };
    window.history.replaceState = function patchedReplace(...args) {
      const r = origReplace.apply(this, args);
      resolve();
      return r;
    };
    return () => {
      cancelled = true;
      window.removeEventListener('popstate', onPop);
      window.history.pushState = origPush;
      window.history.replaceState = origReplace;
    };
  }, []);

  return ref;
}

export function getStoredReferrer(): `0x${string}` | null {
  return readStorage();
}

export function clearStoredReferrer(): void {
  writeStorage(null);
}
