import { useEffect, useState } from 'react';
import { useBlock } from 'wagmi';
import { estimateChainNow } from './chainClock';

/** The chain clock (latest block timestamp, advanced by the time since it was read) for deadline displays and checks. */
export function useChainNow(refetchMs = 12_000): number {
  const { data: head, dataUpdatedAt } = useBlock({ query: { refetchInterval: refetchMs } });
  // browser time only measures the seconds elapsed since the block was read, it never sets the chain time
  const [browserNowMs, setBrowserNowMs] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setBrowserNowMs(Date.now()), 5_000);
    return () => clearInterval(id);
  }, []);
  return estimateChainNow(head?.timestamp, dataUpdatedAt, Math.max(browserNowMs, dataUpdatedAt));
}
