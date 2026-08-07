import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  useAccount,
  useBalance,
  useChainId,
  usePublicClient,
  useReadContract,
  useReadContracts,
} from 'wagmi';
import { formatUnits, parseEther, parseUnits, type Address, type Hex } from 'viem';

import { getAddresses } from '../lib/config';
import {
  erc20Abi,
  permit2Abi,
  quoterAbi,
  universalRouterAbi,
} from '../lib/abi';
import type { PoolKey } from '../lib/pool';
import {
  applySlippage,
  buildBuyCalldata,
  buildSellCalldata,
  MAX_UINT160,
  MAX_UINT256,
} from '../lib/swap';
import {
  encodeAttributionHookData,
  hasAnyAttribution,
} from '../lib/attribution';
import { useReferrer } from '../lib/useReferrer';
import { useDebouncedValue } from '../lib/useDebouncedValue';
import { useTxFlow } from '../lib/useTxFlow';
import { decodeContractError } from '../lib/decodeError';
import { inputClass as baseInputClass } from './formStyles';

type Direction = 'buy' | 'sell';

interface Props {
  tokenAddress: Address;
  tokenSymbol: string;
  /**
   * `undefined` means the pool's real tickSpacing couldn't be matched
   * on-chain (see `resolveTickSpacing`) — in that case we don't have a
   * trustworthy PoolKey to quote or swap against, so the form is disabled.
   */
  poolKey: PoolKey | undefined;
  /**
   * Whether the ArtCoin is `token0` in the pool. `undefined` means the
   * on-chain read for this either failed or hasn't resolved yet — in that
   * case we must NOT guess (a wrong direction flag makes the widget
   * quote/swap the wrong way), so the form is disabled instead.
   */
  isToken0: boolean | undefined;
  /** Is the MEV module currently active? Warn user if yes. */
  mevActive?: boolean;
}

// Error-name -> human message for approval/swap transaction failures. Keyed
// by viem error class name (walked out of the thrown error's `cause` chain
// by `decodeContractError`) rather than a Solidity revert name, since these
// are the failure modes a swapper actually hits before a revert is even
// possible (wallet cancel, underfunded account).
const SWAP_TX_ERROR_MESSAGES: Record<string, string> = {
  UserRejectedRequestError: 'You rejected the request in your wallet.',
  InsufficientFundsError: "Your wallet doesn't have enough ETH to cover this transaction.",
};

function decodeSwapTxError(err: unknown): string {
  return decodeContractError(err, SWAP_TX_ERROR_MESSAGES);
}

const SLIPPAGE_OPTIONS = [0.5, 1, 2, 5];
const DEFAULT_DEADLINE_SECS = 60 * 10; // 10 minutes
// Reserve kept back from the "max" buy amount so the buyer's wallet still has
// something left to pay gas with — filling the input with the FULL ETH
// balance produces a transaction that can never actually be sent.
const BUY_GAS_RESERVE = parseEther('0.01');

// SwapWidget deliberately uses larger padding/text than the rest of the
// forms (this is the primary trade action). Composed from the shared base
// via targeted substitution — rather than appending `py-2.5 text-base` and
// relying on both `py-2`/`py-2.5` and `text-sm`/`text-base` staying present
// together, which would depend on Tailwind's generated stylesheet order to
// resolve the conflict correctly (verified against this project's actual
// build output: `.text-base` is emitted *before* `.text-sm` in the utilities
// layer, so appending `text-base` after a base string containing `text-sm`
// would silently lose — `text-sm` wins the cascade tie). Replacing in place
// keeps this a single source of truth while producing the exact same
// literal class string this component always rendered.
const inputClass = baseInputClass.replace('py-2 text-sm', 'py-2.5 text-base');

export default function SwapWidget({
  tokenAddress,
  tokenSymbol,
  poolKey,
  isToken0,
  mevActive,
}: Props) {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const client = usePublicClient();
  const addresses = getAddresses(chainId);

  const [direction, setDirection] = useState<Direction>('buy');
  const [amountIn, setAmountIn] = useState('');
  const [slippageBps, setSlippageBps] = useState(100); // 1%
  const [quoting, setQuoting] = useState(false);
  const [quote, setQuote] = useState<bigint | null>(null);
  const [quoteError, setQuoteError] = useState<string | null>(null);

  // ── User balances ─────────────────────────────────────────────────
  const { data: ethBalance } = useBalance({
    address,
    query: { refetchInterval: 15_000, enabled: !!address },
  });
  const { data: tokenBalance, refetch: refetchTokenBalance } = useReadContract({
    address: tokenAddress,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 15_000 },
  });

  const balance = direction === 'buy' ? ethBalance?.value ?? 0n : (tokenBalance as bigint) ?? 0n;
  const balanceLabel = direction === 'buy' ? 'ETH' : tokenSymbol;

  // ── Allowances (for sell direction) ───────────────────────────────
  // Two approvals needed for sell:
  //   1. token.approve(permit2, MAX_UINT256)
  //   2. permit2.approve(token, universalRouter, MAX_UINT160, expiration)
  const { data: erc20ToPermit2, refetch: refetchErc20Allowance } = useReadContract({
    address: tokenAddress,
    abi: erc20Abi,
    functionName: 'allowance',
    args: address ? [address, addresses.permit2] : undefined,
    query: { enabled: !!address && direction === 'sell', refetchInterval: 15_000 },
  });

  const { data: permit2Allow, refetch: refetchPermit2Allowance } = useReadContracts({
    contracts:
      address && direction === 'sell'
        ? [
            {
              address: addresses.permit2,
              abi: permit2Abi,
              functionName: 'allowance',
              args: [address, tokenAddress, addresses.universalRouter],
            } as const,
          ]
        : [],
    allowFailure: true,
    query: {
      enabled: !!address && direction === 'sell',
      refetchInterval: 15_000,
    },
  });

  const permit2Info = permit2Allow?.[0]?.result as
    | readonly [bigint, number, number]
    | undefined;
  const permit2Amount = permit2Info?.[0] ?? 0n;
  const permit2Expiration = permit2Info?.[1] ?? 0;

  // ── Parse input amount ────────────────────────────────────────────
  const amountInWei = useMemo(() => {
    if (!amountIn || isNaN(Number(amountIn))) return 0n;
    try {
      return parseUnits(amountIn, 18);
    } catch {
      return 0n;
    }
  }, [amountIn]);

  const overBalance = amountInWei > balance;

  // Debounce the amount that drives quoting so fast typing (e.g. "0.125")
  // doesn't fire an RPC simulation per keystroke. The `cancelled` flag below
  // still guards against a stale in-flight response clobbering a newer one
  // (e.g. two debounced values resolving out of order) — debouncing cuts
  // down how often requests are *started*, it doesn't replace that guard.
  const debouncedAmountInWei = useDebouncedValue(amountInWei, 300);

  // ── Quote ──────────────────────────────────────────────────────────
  // Uses Uniswap V4 Quoter. The quoter function is nonpayable (not view)
  // because it uses a revert-to-return pattern internally. We use
  // simulateContract which handles this cleanly.
  useEffect(() => {
    let cancelled = false;

    // Every early-return branch below must reset `quoting` to false itself.
    // If a previous run left it true (request in flight) and this run bails
    // out before reaching setQuoting(true) again, nothing else would ever
    // flip it back — the cleanup's `cancelled` flag suppresses the in-flight
    // request's own `finally`, so this is the only place that can do it.
    if (!client || debouncedAmountInWei === 0n) {
      setQuote(null);
      setQuoteError(null);
      setQuoting(false);
      return;
    }
    if (!poolKey) {
      // Pool parameters couldn't be verified — do not attempt to quote.
      setQuote(null);
      setQuoteError(null);
      setQuoting(false);
      return;
    }
    if (isToken0 === undefined) {
      // Pool direction couldn't be verified — do not guess.
      setQuote(null);
      setQuoteError(null);
      setQuoting(false);
      return;
    }
    if (addresses.quoter === '0x0000000000000000000000000000000000000000') {
      setQuoteError('Quoter not configured on this chain');
      setQuote(null);
      setQuoting(false);
      return;
    }

    setQuoting(true);
    setQuoteError(null);

    const zeroForOne = direction === 'buy' ? !isToken0 : isToken0;
    // Narrow-and-capture so the closure below keeps the non-undefined type.
    const resolvedPoolKey = poolKey;

    (async () => {
      try {
        const { result } = await client.simulateContract({
          address: addresses.quoter,
          abi: quoterAbi,
          functionName: 'quoteExactInputSingle',
          args: [
            {
              poolKey: {
                currency0: resolvedPoolKey.currency0,
                currency1: resolvedPoolKey.currency1,
                fee: resolvedPoolKey.fee,
                tickSpacing: resolvedPoolKey.tickSpacing,
                hooks: resolvedPoolKey.hooks,
              },
              zeroForOne,
              exactAmount: debouncedAmountInWei,
              hookData: '0x',
            },
          ],
        });
        if (cancelled) return;
        const [amountOut] = result as readonly [bigint, bigint];
        setQuote(amountOut);
      } catch (e: unknown) {
        if (cancelled) return;
        // Quote failures are simulated reverts against the Uniswap V4
        // Quoter — the ABI doesn't decode named errors for it, so there's
        // nothing meaningful to map by name. Just give a plain sentence
        // instead of the raw "The contract function ... reverted" dump.
        setQuoteError(
          decodeContractError(e, {}, () => 'Unable to get a quote for this trade right now.')
        );
        setQuote(null);
      } finally {
        if (!cancelled) setQuoting(false);
      }
    })();

    return () => {
      cancelled = true;
    };
    // Deliberately depend on poolKey's primitive fields rather than the
    // poolKey object itself, which may be a freshly-built object on every
    // render; the fields below cover every value the effect actually reads.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    client,
    addresses.quoter,
    debouncedAmountInWei,
    direction,
    isToken0,
    poolKey?.currency0,
    poolKey?.currency1,
    poolKey?.fee,
    poolKey?.tickSpacing,
    poolKey?.hooks,
  ]);

  const minOut = useMemo(() => {
    if (quote === null) return 0n;
    return applySlippage(quote, slippageBps);
  }, [quote, slippageBps]);

  // ── Write functions ───────────────────────────────────────────────
  // This is a multi-step flow (up to two Permit2 approvals, then the swap
  // itself), and each step is a genuinely distinct on-chain write with its
  // own confirmation — so each gets its own `useTxFlow` instance rather than
  // sharing one. Only one of the three is ever "active" at a time (the UI
  // below only ever renders one of the three buttons), but keeping them
  // separate means each step's status/error can't leak into another step's
  // button label.
  const approveErc20Flow = useTxFlow({
    onConfirmed: useCallback(() => {
      refetchErc20Allowance();
    }, [refetchErc20Allowance]),
  });

  const approvePermit2Flow = useTxFlow({
    onConfirmed: useCallback(() => {
      refetchPermit2Allowance();
    }, [refetchPermit2Allowance]),
  });

  const swapFlow = useTxFlow({
    onConfirmed: useCallback(() => {
      // Refresh balances once the receipt actually lands, instead of the
      // old blind 2500ms timer. Clearing the amount also collapses the
      // debounced quote back to null via the quote effect above.
      setAmountIn('');
      refetchTokenBalance();
    }, [refetchTokenBalance]),
  });

  // ── Action handlers ───────────────────────────────────────────────
  const handleApproveErc20 = () => {
    approveErc20Flow.reset();
    approveErc20Flow.submit({
      address: tokenAddress,
      abi: erc20Abi,
      functionName: 'approve',
      args: [addresses.permit2, MAX_UINT256],
    });
  };

  const handleApprovePermit2 = () => {
    approvePermit2Flow.reset();
    // expiration: now + ~30 days (max uint48 is ~8.9M years, any sane value works)
    const expiration = Math.floor(Date.now() / 1000) + 30 * 86400;
    approvePermit2Flow.submit({
      address: addresses.permit2,
      abi: permit2Abi,
      functionName: 'approve',
      args: [tokenAddress, addresses.universalRouter, MAX_UINT160, expiration],
    });
  };

  const referrer = useReferrer();
  const handleSwap = () => {
    if (
      !address ||
      !poolKey ||
      amountInWei === 0n ||
      quote === null ||
      isToken0 === undefined
    )
      return;
    swapFlow.reset();
    const deadline = BigInt(Math.floor(Date.now() / 1000) + DEFAULT_DEADLINE_SECS);

    // Encode attribution as a 1-tuple PoolSwapData struct so the
    // skim-fee hook decodes it correctly. See lib/attribution.ts.
    const attrArgs = { referrer: referrer ?? undefined };
    const hookData: Hex = hasAnyAttribution(attrArgs)
      ? encodeAttributionHookData(attrArgs)
      : ('0x' as Hex);

    if (direction === 'buy') {
      const { commands, inputs, value } = buildBuyCalldata({
        poolKey,
        artCoinIsToken0: isToken0,
        weth: addresses.weth,
        token: tokenAddress,
        ethAmount: amountInWei,
        minTokenOut: minOut,
        hookData,
      });
      swapFlow.submit({
        address: addresses.universalRouter,
        abi: universalRouterAbi,
        functionName: 'execute',
        args: [commands, inputs, deadline],
        value,
      });
    } else {
      const { commands, inputs, value } = buildSellCalldata({
        poolKey,
        artCoinIsToken0: isToken0,
        weth: addresses.weth,
        token: tokenAddress,
        tokenAmount: amountInWei,
        minEthOut: minOut,
        recipient: address,
        hookData,
      });
      swapFlow.submit({
        address: addresses.universalRouter,
        abi: universalRouterAbi,
        functionName: 'execute',
        args: [commands, inputs, deadline],
        value,
      });
    }
  };

  // ── UI state decisions ───────────────────────────────────────────
  const needsErc20Approval =
    direction === 'sell' &&
    amountInWei > 0n &&
    ((erc20ToPermit2 as bigint | undefined) ?? 0n) < amountInWei;

  const needsPermit2Approval =
    direction === 'sell' &&
    amountInWei > 0n &&
    !needsErc20Approval &&
    (permit2Amount < amountInWei || permit2Expiration < Math.floor(Date.now() / 1000));

  // Single source of truth for "why is swapping disabled right now", so the
  // pool-direction-unknown case and the pool-key-unverified case drive one
  // banner and one set of disabled props instead of two competing paths.
  const disabledReason: string | null = !poolKey
    ? "This pool's parameters couldn't be verified — swapping is disabled here."
    : isToken0 === undefined
      ? // Pool direction (artCoinIsToken0) couldn't be verified on-chain —
        // never guess it, since a wrong direction flag would quote/swap the
        // wrong way.
        "This pool's configuration couldn't be verified — swapping is disabled here."
      : null;

  const poolConfigUnknown = disabledReason !== null;

  const canSwap =
    !poolConfigUnknown &&
    isConnected &&
    amountInWei > 0n &&
    quote !== null &&
    !overBalance &&
    !needsErc20Approval &&
    !needsPermit2Approval;

  // The flow instance backing whichever action is currently shown to the
  // user — drives the visible button's pending/error state below.
  const activeFlow = needsErc20Approval
    ? approveErc20Flow
    : needsPermit2Approval
      ? approvePermit2Flow
      : swapFlow;

  const swapButtonLabel = () => {
    if (poolConfigUnknown) return 'Swap disabled';
    if (!isConnected) return 'Connect wallet';
    if (!amountInWei) return 'Enter amount';
    if (overBalance) return `Insufficient ${balanceLabel}`;
    if (quoting) return 'Fetching quote…';
    if (quote === null) return 'No quote available';
    if (swapFlow.status === 'confirming' || swapFlow.status === 'pending') {
      return swapFlow.status === 'confirming' ? 'Confirm in wallet…' : 'Swapping…';
    }
    return direction === 'buy' ? `Buy ${tokenSymbol}` : `Sell ${tokenSymbol}`;
  };

  // ── Render ────────────────────────────────────────────────────────
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
      <div className="flex items-center justify-between px-5 py-3 border-b border-zinc-800">
        <h3 className="text-sm font-semibold text-white">Swap</h3>
        <div className="flex items-center gap-1 bg-zinc-800 rounded-lg p-0.5">
          {(['buy', 'sell'] as const).map(d => (
            <button
              key={d}
              type="button"
              disabled={poolConfigUnknown}
              aria-pressed={direction === d}
              onClick={() => {
                setDirection(d);
                setAmountIn('');
                setQuote(null);
                setQuoteError(null);
              }}
              className={`px-3 py-1 text-xs font-medium rounded-md transition-colors disabled:opacity-40 disabled:cursor-not-allowed ${
                direction === d
                  ? d === 'buy'
                    ? 'bg-green-600 text-white'
                    : 'bg-red-600 text-white'
                  : 'text-zinc-400 hover:text-white'
              }`}
            >
              {d === 'buy' ? 'Buy' : 'Sell'}
            </button>
          ))}
        </div>
      </div>

      <div className="p-5 space-y-3">
        {disabledReason && (
          <div className="rounded-lg border border-red-900 bg-red-950/30 p-3 text-xs text-red-300">
            {disabledReason}
          </div>
        )}

        {mevActive && (
          <div className="rounded-lg border border-violet-600/30 bg-violet-950/20 p-3 text-xs text-violet-200">
            <strong>Anti-sniper protection active.</strong> Buy fees are currently very high. See
            the anti-sniper panel below for the countdown.
          </div>
        )}

        {/* Amount in */}
        <div>
          <div className="flex items-center justify-between mb-1">
            <label htmlFor="swap-amount-in" className="text-xs text-zinc-500">
              You {direction === 'buy' ? 'pay' : 'sell'}
            </label>
            {isConnected && (
              <button
                type="button"
                onClick={() => {
                  // Buying spends ETH, which also has to cover gas — filling
                  // in the full balance would leave nothing for that and the
                  // tx could never be sent. Selling spends the ERC20 token,
                  // which doesn't pay gas, so the full balance is fine there.
                  const max =
                    direction === 'buy'
                      ? balance > BUY_GAS_RESERVE
                        ? balance - BUY_GAS_RESERVE
                        : 0n
                      : balance;
                  setAmountIn(formatUnits(max, 18));
                }}
                className="text-xs text-zinc-500 hover:text-zinc-300"
              >
                Balance: {Number(formatUnits(balance, 18)).toLocaleString(undefined, {
                  maximumFractionDigits: 6,
                })}{' '}
                {balanceLabel}
              </button>
            )}
          </div>
          <div className="relative">
            <input
              id="swap-amount-in"
              type="text"
              inputMode="decimal"
              placeholder="0.0"
              disabled={poolConfigUnknown}
              value={amountIn}
              onChange={e => {
                const v = e.target.value.replace(',', '.');
                if (/^\d*\.?\d*$/.test(v)) setAmountIn(v);
              }}
              className={`${inputClass} pr-20`}
            />
            <span className="absolute right-3 top-1/2 -translate-y-1/2 text-sm font-medium text-zinc-300">
              {balanceLabel}
            </span>
          </div>
        </div>

        {/* Amount out (quote) */}
        <div>
          <label className="text-xs text-zinc-500 mb-1 block">
            You receive (estimated)
          </label>
          <div className={`${inputClass} flex items-center justify-between cursor-default`}>
            <span className="text-zinc-300">
              {quoting
                ? '…'
                : quote !== null
                  ? Number(formatUnits(quote, 18)).toLocaleString(undefined, {
                      maximumFractionDigits: 8,
                    })
                  : '0.0'}
            </span>
            <span className="text-sm font-medium text-zinc-400">
              {direction === 'buy' ? tokenSymbol : 'ETH'}
            </span>
          </div>
          {quoteError && (
            <p className="text-xs text-red-400 mt-1">Quote failed: {quoteError}</p>
          )}
        </div>

        {/* Slippage */}
        <div className="flex items-center justify-between">
          <label className="text-xs text-zinc-500">Slippage</label>
          <div className="flex gap-1">
            {SLIPPAGE_OPTIONS.map(pct => (
              <button
                key={pct}
                type="button"
                onClick={() => setSlippageBps(Math.round(pct * 100))}
                className={`px-2 py-1 text-xs rounded ${
                  slippageBps === Math.round(pct * 100)
                    ? 'bg-violet-600 text-white'
                    : 'bg-zinc-800 text-zinc-400 hover:text-white'
                }`}
              >
                {pct}%
              </button>
            ))}
          </div>
        </div>

        {quote !== null && minOut > 0n && (
          <div className="text-xs text-zinc-500 flex items-center justify-between">
            <span>Min received</span>
            <span>
              {Number(formatUnits(minOut, 18)).toLocaleString(undefined, {
                maximumFractionDigits: 6,
              })}{' '}
              {direction === 'buy' ? tokenSymbol : 'ETH'}
            </span>
          </div>
        )}

        {/* Action button */}
        {needsErc20Approval ? (
          <button
            type="button"
            onClick={handleApproveErc20}
            disabled={
              poolConfigUnknown ||
              approveErc20Flow.status === 'confirming' ||
              approveErc20Flow.status === 'pending'
            }
            className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 disabled:cursor-not-allowed py-3 text-sm font-semibold"
          >
            {approveErc20Flow.status === 'confirming'
              ? 'Confirm in wallet…'
              : approveErc20Flow.status === 'pending'
                ? 'Approving…'
                : `1. Approve ${tokenSymbol}`}
          </button>
        ) : needsPermit2Approval ? (
          <button
            type="button"
            onClick={handleApprovePermit2}
            disabled={
              poolConfigUnknown ||
              approvePermit2Flow.status === 'confirming' ||
              approvePermit2Flow.status === 'pending'
            }
            className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 disabled:cursor-not-allowed py-3 text-sm font-semibold"
          >
            {approvePermit2Flow.status === 'confirming'
              ? 'Confirm in wallet…'
              : approvePermit2Flow.status === 'pending'
                ? 'Approving…'
                : '2. Approve Permit2'}
          </button>
        ) : (
          <button
            type="button"
            onClick={handleSwap}
            disabled={
              !canSwap || swapFlow.status === 'confirming' || swapFlow.status === 'pending'
            }
            className={`w-full rounded-lg py-3 text-sm font-semibold transition-colors ${
              canSwap && swapFlow.status !== 'confirming' && swapFlow.status !== 'pending'
                ? direction === 'buy'
                  ? 'bg-green-600 hover:bg-green-500'
                  : 'bg-red-600 hover:bg-red-500'
                : 'bg-zinc-700 cursor-not-allowed text-zinc-400'
            }`}
          >
            {swapButtonLabel()}
          </button>
        )}

        {/* Status / errors */}
        {activeFlow.error && (
          <div className="rounded-lg border border-red-900 bg-red-950/30 p-3 text-xs text-red-300">
            <p className="font-semibold mb-1">
              {activeFlow === swapFlow ? 'Swap failed' : 'Approval failed'}
            </p>
            <p>{decodeSwapTxError(activeFlow.error)}</p>
            <details className="mt-2">
              <summary className="cursor-pointer text-red-400/70 hover:text-red-300">
                Technical details
              </summary>
              <pre className="mt-1 max-h-32 overflow-auto whitespace-pre-wrap break-all font-mono text-red-400/80">
                {activeFlow.error.message.slice(0, 500)}
              </pre>
            </details>
          </div>
        )}

        {swapFlow.status === 'confirmed' && swapFlow.receipt && (
          <div className="rounded-lg border border-green-900 bg-green-950/30 p-3 text-xs text-green-300">
            Swap confirmed in block {swapFlow.receipt.blockNumber.toString()}.
          </div>
        )}
      </div>
    </div>
  );
}
