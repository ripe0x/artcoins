// Deadlines in the contracts (permit2 expirations, the anti sniper window, the router deadline) are compared
// with block.timestamp, never with the browser clock. A browser clock that runs behind or ahead of the chain
// by minutes (or a fork whose chain clock lags) turns "10 minutes left" into "expired" or, worse, signs a
// permit2 approval that is already expired on chain. Every such comparison reads the chain timestamp; the
// browser clock is only the fallback when no block is known.

/** extra seconds added to a chain deadline check, so a swap mined a few blocks later still finds the approval alive */
export const CHAIN_DEADLINE_MARGIN_SEC = 120;

/**
 * The chain's "now" in unix seconds. `headTimestamp` is the latest block timestamp and `fetchedAtMs` the browser
 * time at which that block was read: only the elapsed time since the read comes from the browser clock, so a
 * skewed browser clock cancels out. Without a block the browser clock is returned.
 */
export function estimateChainNow(headTimestamp: bigint | number | undefined, fetchedAtMs: number | undefined, browserNowMs: number): number {
  if (headTimestamp === undefined || !fetchedAtMs) return Math.floor(browserNowMs / 1000);
  const elapsed = Math.max(0, Math.floor((browserNowMs - fetchedAtMs) / 1000));
  return Number(headTimestamp) + elapsed;
}

/** latest block timestamp read from the chain, or the browser clock when the read fails */
export async function latestChainTimestamp(client: { getBlock: () => Promise<{ timestamp: bigint }> }): Promise<number> {
  try {
    const block = await client.getBlock();
    return Number(block.timestamp);
  } catch {
    return Math.floor(Date.now() / 1000);
  }
}

/** is the permit2 allowance (amount, expiration) good for `amount` until `deadlineMin` minutes from the chain's now */
export function permit2Covers(args: {
  amount: bigint;
  expiration: number;
  need: bigint;
  chainNow: number;
  deadlineMin: number;
}): boolean {
  return args.amount >= args.need && args.expiration >= args.chainNow + args.deadlineMin * 60 + CHAIN_DEADLINE_MARGIN_SEC;
}

/** expiration to sign for a permit2 approval: the chain's now, the swap deadline, and 5 minutes of room */
export function permit2Expiration(chainNow: number, deadlineMin: number): number {
  return chainNow + (deadlineMin + 5) * 60;
}

/**
 * Which approval a sell still needs. The balance check comes first: above the balance neither approval is
 * offered (the button says "Insufficient"), so nobody signs an approval for coins they do not hold.
 */
export function sellApprovalSteps(args: {
  direction: 'buy' | 'sell';
  amountIn: bigint;
  balance: bigint;
  erc20ToPermit2: bigint;
  permit2Amount: bigint;
  permit2Expiration: number;
  chainNow: number;
  deadlineMin: number;
}): { needsErc20Approval: boolean; needsPermit2Approval: boolean } {
  const active = args.direction === 'sell' && args.amountIn > 0n && args.amountIn <= args.balance;
  const needsErc20Approval = active && args.erc20ToPermit2 < args.amountIn;
  const needsPermit2Approval =
    active &&
    !needsErc20Approval &&
    !permit2Covers({
      amount: args.permit2Amount,
      expiration: args.permit2Expiration,
      need: args.amountIn,
      chainNow: args.chainNow,
      deadlineMin: args.deadlineMin,
    });
  return { needsErc20Approval, needsPermit2Approval };
}
