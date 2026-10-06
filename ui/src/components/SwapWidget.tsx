import { useEffect, useMemo, useState } from 'react';
import {
  useAccount,
  useBalance,
  usePublicClient,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { formatUnits, parseUnits, type Address, type Hex } from 'viem';
import { useQuery } from '@tanstack/react-query';

import { erc20Abi, permit2Abi, quoterAbi, stateViewAbi, universalRouterAbi } from '../lib/abi';
import { computePoolId, priceFromSqrtX96, type PoolKey } from '../lib/pool';
import {
  applySlippage,
  buildBuyCalldata,
  buildSellCalldata,
  classifyPool,
  coinIsCurrency0,
  priceImpactPercent,
} from '../lib/swap';
import { encodeAttributionHookData, hasAnyAttribution } from '../lib/attribution';
import { useReferrer } from '../lib/useReferrer';
import { useAddressesOrNull, useWalletGate } from '../lib/useChain';
import { describeError } from '../lib/errors';
import ReferrerNotice from './ReferrerNotice';

type Direction = 'buy' | 'sell';

interface Props {
  tokenAddress: Address;
  tokenSymbol: string;
  poolKey: PoolKey;
  /** human readable fee line for this pool, e.g. "0.5% lp fee + 6% skim" */
  feeSummary?: string;
  /** anti sniper window currently open */
  mevActive?: boolean;
  /** current anti sniper skim in percent of volume, when known */
  mevSkimPercent?: number;
}

const SLIPPAGE_OPTIONS = [0.5, 1, 2, 5];
const DEADLINE_OPTIONS = [2, 5, 10, 30]; // minutes
const QUOTE_REFRESH_MS = 12_000;
/** a quote older than this cannot be used to send */
const QUOTE_MAX_AGE_MS = 30_000;
/** eth kept back by "max" so the swap can still pay gas */
const GAS_RESERVE = parseUnits('0.005', 18);
/** above this price impact (incl. fees) the user must tick a box */
const HIGH_IMPACT_PERCENT = 10;
const ZERO = '0x0000000000000000000000000000000000000000';

const inputClass =
  'w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2.5 text-base text-white placeholder-zinc-500 focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500';

const fmt = (v: bigint, max = 6) =>
  Number(formatUnits(v, 18)).toLocaleString(undefined, { maximumFractionDigits: max });

interface Quote {
  amountOut: bigint;
  fetchedAt: number;
}

export default function SwapWidget({ tokenAddress, tokenSymbol, poolKey, feeSummary, mevActive, mevSkimPercent }: Props) {
  const { address } = useAccount();
  const gate = useWalletGate();
  const client = usePublicClient();
  const { addresses } = useAddressesOrNull();
  const referrer = useReferrer();

  const [direction, setDirection] = useState<Direction>('buy');
  const [amountIn, setAmountIn] = useState('');
  const [slippageBps, setSlippageBps] = useState(100);
  const [deadlineMin, setDeadlineMin] = useState(5);
  const [ackImpact, setAckImpact] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [preparing, setPreparing] = useState(false);

  const kind = addresses ? classifyPool(poolKey, tokenAddress, addresses.weth) : null;
  const coinIs0 = coinIsCurrency0(poolKey, tokenAddress);
  const poolId = useMemo(() => computePoolId(poolKey), [poolKey]);

  // The same hookData goes to the quoter and the swap, so the quote prices what is sent.
  const hookData: Hex = useMemo(() => {
    const attr = { referrer: referrer.referrer ?? undefined };
    return hasAnyAttribution(attr) ? encodeAttributionHookData(attr) : '0x';
  }, [referrer.referrer]);

  // ── balances ────────────────────────────────────────────────────────
  const { data: ethBalance } = useBalance({ address, query: { refetchInterval: 15_000, enabled: !!address } });
  const { data: tokenBalance, refetch: refetchTokenBalance } = useReadContract({
    address: tokenAddress,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
    query: { enabled: !!address, refetchInterval: 15_000 },
  });
  const balance = direction === 'buy' ? (ethBalance?.value ?? 0n) : ((tokenBalance as bigint | undefined) ?? 0n);
  const balanceLabel = direction === 'buy' ? 'ETH' : tokenSymbol;

  const amountInWei = useMemo(() => {
    if (!/^\d*\.?\d+$|^\d+\.$/.test(amountIn)) return 0n;
    try {
      return parseUnits(amountIn, 18);
    } catch {
      return 0n;
    }
  }, [amountIn]);
  const overBalance = amountInWei > balance;

  // ── allowances (sell): exact amounts, short expiry ──────────────────
  const permit2 = addresses?.permit2;
  const router = addresses?.universalRouter;
  const sellOn = direction === 'sell' && !!address && !!permit2 && !!router;
  const { data: erc20ToPermit2, refetch: refetchErc20Allowance } = useReadContract({
    address: tokenAddress,
    abi: erc20Abi,
    functionName: 'allowance',
    args: address && permit2 ? [address, permit2] : undefined,
    query: { enabled: sellOn, refetchInterval: 15_000 },
  });
  const { data: permit2Info, refetch: refetchPermit2 } = useReadContract({
    address: permit2,
    abi: permit2Abi,
    functionName: 'allowance',
    args: address && permit2 && router ? [address, tokenAddress, router] : undefined,
    query: { enabled: sellOn, refetchInterval: 15_000 },
  });
  const permit2Amount = permit2Info?.[0] ?? 0n;
  const permit2Expiration = permit2Info?.[1] ?? 0;

  // ── spot price (mid) ────────────────────────────────────────────────
  const { data: slot0 } = useReadContract({
    address: addresses?.stateView,
    abi: stateViewAbi,
    functionName: 'getSlot0',
    args: [poolId],
    query: { enabled: !!addresses && addresses.stateView !== ZERO, refetchInterval: QUOTE_REFRESH_MS },
  });
  const midCoinPerEth = useMemo(() => {
    if (!slot0) return null;
    const p = priceFromSqrtX96(slot0[0]); // token1 per token0
    if (!(p > 0)) return null;
    return coinIs0 ? 1 / p : p; // coin per eth (or weth)
  }, [slot0, coinIs0]);

  // ── quote: refreshed on an interval and again right before sending ──
  const zeroForOne = direction === 'buy' ? !coinIs0 : coinIs0;
  const quoter = addresses?.quoter;
  const quoteEnabled = !!client && !!quoter && quoter !== ZERO && amountInWei > 0n && kind !== null;
  const quoteQuery = useQuery({
    queryKey: ['quote', poolId, direction, amountInWei.toString(), hookData],
    enabled: quoteEnabled,
    refetchInterval: QUOTE_REFRESH_MS,
    staleTime: 0,
    gcTime: 0,
    retry: false,
    queryFn: async (): Promise<Quote> => {
      const { result } = await client!.simulateContract({
        address: quoter!,
        abi: quoterAbi,
        functionName: 'quoteExactInputSingle',
        args: [{ poolKey, zeroForOne, exactAmount: amountInWei, hookData }],
      });
      return { amountOut: (result as readonly [bigint, bigint])[0], fetchedAt: Date.now() };
    },
  });
  const quote = quoteQuery.data && quoteQuery.data.amountOut > 0n ? quoteQuery.data : null;
  const quoteFresh = quote !== null && Date.now() - quote.fetchedAt < QUOTE_MAX_AGE_MS;
  const quoteError = !quoter || quoter === ZERO
    ? 'Quoter is not configured, swaps are disabled'
    : quoteQuery.error
      ? describeError(quoteQuery.error)
      : quoteQuery.data && quoteQuery.data.amountOut === 0n
        ? 'The pool returned a zero quote'
        : null;

  const minOut = quote ? applySlippage(quote.amountOut, slippageBps) : 0n;
  const impact = quote && midCoinPerEth ? priceImpactPercent(direction, amountInWei, quote.amountOut, midCoinPerEth) : null;
  const highImpact = impact !== null && impact > HIGH_IMPACT_PERCENT;
  const impactUnknown = quote !== null && impact === null;

  // reset the acknowledgement whenever the situation changes
  useEffect(() => setAckImpact(false), [direction, amountIn, slippageBps]);

  // ── writes ──────────────────────────────────────────────────────────
  const { writeContractAsync, data: txHash, isPending, reset, error: writeError } = useWriteContract();
  const { data: receipt, isLoading: confirming } = useWaitForTransactionReceipt({ hash: txHash });
  const [pendingAction, setPendingAction] = useState<'approve-erc20' | 'approve-permit2' | 'swap' | null>(null);
  const reverted = receipt?.status === 'reverted';

  useEffect(() => {
    if (!receipt) return;
    if (receipt.status === 'success') {
      if (pendingAction === 'swap') setAmountIn('');
      void refetchTokenBalance();
      void refetchErc20Allowance();
      void refetchPermit2();
    }
    const t = setTimeout(() => {
      if (receipt.status === 'success') {
        setPendingAction(null);
        reset();
      }
    }, 2500);
    return () => clearTimeout(t);
  }, [receipt, pendingAction, refetchTokenBalance, refetchErc20Allowance, refetchPermit2, reset]);

  const needsErc20Approval = direction === 'sell' && amountInWei > 0n && ((erc20ToPermit2 as bigint | undefined) ?? 0n) < amountInWei;
  const nowSec = Math.floor(Date.now() / 1000);
  const needsPermit2Approval =
    direction === 'sell' &&
    amountInWei > 0n &&
    !needsErc20Approval &&
    (permit2Amount < amountInWei || permit2Expiration < nowSec + deadlineMin * 60);

  const handleApproveErc20 = async () => {
    if (!permit2) return;
    setActionError(null);
    setPendingAction('approve-erc20');
    try {
      // exactly the amount being sold, not an infinite allowance
      await writeContractAsync({ address: tokenAddress, abi: erc20Abi, functionName: 'approve', args: [permit2, amountInWei] });
    } catch (e) {
      setActionError(describeError(e));
      setPendingAction(null);
    }
  };

  const handleApprovePermit2 = async () => {
    if (!permit2 || !router) return;
    setActionError(null);
    setPendingAction('approve-permit2');
    try {
      // exact amount, expiry just past the swap deadline
      const expiration = Math.floor(Date.now() / 1000) + (deadlineMin + 5) * 60;
      await writeContractAsync({
        address: permit2,
        abi: permit2Abi,
        functionName: 'approve',
        args: [tokenAddress, router, amountInWei, expiration],
      });
    } catch (e) {
      setActionError(describeError(e));
      setPendingAction(null);
    }
  };

  const handleSwap = async () => {
    if (!address || !client || !addresses || !quoter || kind === null || amountInWei === 0n) return;
    setActionError(null);
    setPreparing(true);
    try {
      // 1. fresh quote right before sending, the screen quote may be seconds old
      const { result } = await client.simulateContract({
        address: quoter,
        abi: quoterAbi,
        functionName: 'quoteExactInputSingle',
        args: [{ poolKey, zeroForOne, exactAmount: amountInWei, hookData }],
      });
      const freshOut = (result as readonly [bigint, bigint])[0];
      if (freshOut === 0n) throw new Error('The pool returned a zero quote, nothing was sent');
      const floor = applySlippage(freshOut, slippageBps);
      if (floor === 0n) throw new Error('Computed a zero minimum out, nothing was sent');

      // 2. calldata with the floor, deadline from the chain clock
      const block = await client.getBlock();
      const deadline = block.timestamp + BigInt(deadlineMin * 60);
      const built =
        direction === 'buy'
          ? buildBuyCalldata({ poolKey, token: tokenAddress, weth: addresses.weth, ethAmount: amountInWei, minTokenOut: floor, hookData })
          : buildSellCalldata({ poolKey, token: tokenAddress, weth: addresses.weth, tokenAmount: amountInWei, minEthOut: floor, recipient: address, hookData });

      // 3. simulate: a revert is shown with its reason and nothing is sent
      const sim = await client.simulateContract({
        account: address,
        address: addresses.universalRouter,
        abi: universalRouterAbi,
        functionName: 'execute',
        args: [built.commands, built.inputs, deadline],
        value: built.value,
      });

      setPendingAction('swap');
      await writeContractAsync(sim.request);
    } catch (e) {
      setActionError(describeError(e));
      setPendingAction(null);
    } finally {
      setPreparing(false);
    }
  };

  // ── button state ────────────────────────────────────────────────────
  const busy = isPending || confirming || preparing;
  const canSwap =
    gate.ok &&
    kind !== null &&
    amountInWei > 0n &&
    !overBalance &&
    quoteFresh &&
    minOut > 0n &&
    !impactUnknown &&
    (!highImpact || ackImpact) &&
    !needsErc20Approval &&
    !needsPermit2Approval;

  const swapLabel = () => {
    if (gate.reason) return gate.reason;
    if (kind === null) return 'Pool not supported';
    if (!amountInWei) return 'Enter amount';
    if (overBalance) return `Insufficient ${balanceLabel}`;
    if (quoteQuery.isFetching && !quote) return 'Fetching quote…';
    if (!quote) return 'No quote available';
    if (!quoteFresh) return 'Refreshing quote…';
    if (impactUnknown) return 'Price impact unknown, swap disabled';
    if (highImpact && !ackImpact) return 'Acknowledge the price impact';
    if (preparing) return 'Checking…';
    if (pendingAction === 'swap' && (isPending || confirming)) return isPending ? 'Confirm in wallet…' : 'Swapping…';
    return direction === 'buy' ? `Buy ${tokenSymbol}` : `Sell ${tokenSymbol}`;
  };

  if (!addresses || kind === null) {
    return (
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5 text-sm text-zinc-400">
        This pool is not a coin / native eth pool, the in app swap does not support it.
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
      <div className="flex items-center justify-between px-5 py-3 border-b border-zinc-800">
        <h3 className="text-sm font-semibold text-white">Swap</h3>
        <div className="flex items-center gap-1 bg-zinc-800 rounded-lg p-0.5">
          {(['buy', 'sell'] as const).map((d) => (
            <button
              key={d}
              type="button"
              onClick={() => {
                setDirection(d);
                setAmountIn('');
                setActionError(null);
              }}
              className={`px-3 py-1 text-xs font-medium rounded-md transition-colors ${
                direction === d ? (d === 'buy' ? 'bg-green-600 text-white' : 'bg-red-600 text-white') : 'text-zinc-400 hover:text-white'
              }`}
            >
              {d === 'buy' ? 'Buy' : 'Sell'}
            </button>
          ))}
        </div>
      </div>

      <div className="p-5 space-y-3">
        {mevActive && (
          <div className="rounded-lg border border-violet-600/30 bg-violet-950/20 p-3 text-xs text-violet-200">
            <strong>Anti-sniper skim active.</strong>{' '}
            {mevSkimPercent !== undefined ? `Currently ${mevSkimPercent.toFixed(2)}% of volume. ` : ''}
            It decays to the baseline, the quote below already includes it.
          </div>
        )}
        {feeSummary && <p className="text-xs text-zinc-500">Pool fees: {feeSummary}</p>}

        <div>
          <div className="flex items-center justify-between mb-1">
            <label className="text-xs text-zinc-500">You {direction === 'buy' ? 'pay' : 'sell'}</label>
            {gate.ok && (
              <button
                type="button"
                onClick={() => {
                  const max = direction === 'buy' ? (balance > GAS_RESERVE ? balance - GAS_RESERVE : 0n) : balance;
                  setAmountIn(formatUnits(max, 18));
                }}
                className="text-xs text-zinc-500 hover:text-zinc-300"
              >
                Balance: {fmt(balance)} {balanceLabel}
              </button>
            )}
          </div>
          <div className="relative">
            <input
              type="text"
              inputMode="decimal"
              placeholder="0.0"
              value={amountIn}
              onChange={(e) => {
                const v = e.target.value.replace(',', '.');
                if (/^\d*\.?\d*$/.test(v)) setAmountIn(v);
              }}
              className={`${inputClass} pr-20`}
            />
            <span className="absolute right-3 top-1/2 -translate-y-1/2 text-sm font-medium text-zinc-300">{balanceLabel}</span>
          </div>
          {direction === 'buy' && <p className="text-xs text-zinc-600 mt-1">Max keeps 0.005 ETH back for gas.</p>}
        </div>

        <div>
          <label className="text-xs text-zinc-500 mb-1 block">You receive (estimated)</label>
          <div className={`${inputClass} flex items-center justify-between cursor-default`}>
            <span className="text-zinc-300">{quote ? fmt(quote.amountOut, 8) : quoteQuery.isFetching && quoteEnabled ? '…' : '0.0'}</span>
            <span className="text-sm font-medium text-zinc-400">{direction === 'buy' ? tokenSymbol : 'ETH'}</span>
          </div>
          {amountInWei > 0n && quoteError && <p className="text-xs text-red-400 mt-1">Quote failed: {quoteError}</p>}
        </div>

        {quote && (
          <div className="rounded-lg bg-zinc-800/40 px-3 py-2 text-xs space-y-1">
            <div className="flex justify-between text-zinc-500">
              <span>Price impact vs mid (fees included)</span>
              <span className={highImpact ? 'text-red-400 font-semibold' : impact !== null && impact > 3 ? 'text-amber-400' : 'text-zinc-300'}>
                {impact === null ? 'unknown' : `${impact.toFixed(2)}%`}
              </span>
            </div>
            <div className="flex justify-between text-zinc-500">
              <span>Min received ({(slippageBps / 100).toFixed(2)}% slippage)</span>
              <span className="text-zinc-300">
                {fmt(minOut, 8)} {direction === 'buy' ? tokenSymbol : 'ETH'}
              </span>
            </div>
            <div className="flex justify-between text-zinc-600">
              <span>Quote age</span>
              <span>{quoteFresh ? 'fresh, refreshes every 12s' : 'stale'}</span>
            </div>
          </div>
        )}

        {highImpact && (
          <label className="flex items-start gap-2 text-xs text-red-300">
            <input type="checkbox" checked={ackImpact} onChange={(e) => setAckImpact(e.target.checked)} className="mt-0.5" />
            <span>I understand I am paying about {impact?.toFixed(1)}% over the pool mid price.</span>
          </label>
        )}

        <div className="flex items-center justify-between">
          <label className="text-xs text-zinc-500">Slippage</label>
          <div className="flex gap-1">
            {SLIPPAGE_OPTIONS.map((pct) => (
              <button
                key={pct}
                type="button"
                onClick={() => setSlippageBps(Math.round(pct * 100))}
                className={`px-2 py-1 text-xs rounded ${slippageBps === Math.round(pct * 100) ? 'bg-violet-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:text-white'}`}
              >
                {pct}%
              </button>
            ))}
          </div>
        </div>
        <div className="flex items-center justify-between">
          <label className="text-xs text-zinc-500">Deadline</label>
          <div className="flex gap-1">
            {DEADLINE_OPTIONS.map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => setDeadlineMin(m)}
                className={`px-2 py-1 text-xs rounded ${deadlineMin === m ? 'bg-violet-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:text-white'}`}
              >
                {m}m
              </button>
            ))}
          </div>
        </div>

        <ReferrerNotice state={referrer} />

        {gate.needsSwitch ? (
          <button type="button" onClick={gate.switchToMainnet} className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 py-3 text-sm font-semibold">
            Switch to Ethereum mainnet
          </button>
        ) : needsErc20Approval ? (
          <button
            type="button"
            onClick={() => void handleApproveErc20()}
            disabled={busy || !gate.ok || overBalance}
            className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 disabled:cursor-not-allowed py-3 text-sm font-semibold"
          >
            {pendingAction === 'approve-erc20' && busy ? (isPending ? 'Confirm in wallet…' : 'Approving…') : `1. Approve exactly ${amountIn} ${tokenSymbol} to Permit2`}
          </button>
        ) : needsPermit2Approval ? (
          <button
            type="button"
            onClick={() => void handleApprovePermit2()}
            disabled={busy || !gate.ok}
            className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 disabled:cursor-not-allowed py-3 text-sm font-semibold"
          >
            {pendingAction === 'approve-permit2' && busy ? (isPending ? 'Confirm in wallet…' : 'Approving…') : `2. Let the router spend it for ${deadlineMin + 5} minutes`}
          </button>
        ) : (
          <button
            type="button"
            onClick={() => void handleSwap()}
            disabled={!canSwap || busy}
            className={`w-full rounded-lg py-3 text-sm font-semibold transition-colors ${
              canSwap && !busy ? (direction === 'buy' ? 'bg-green-600 hover:bg-green-500' : 'bg-red-600 hover:bg-red-500') : 'bg-zinc-700 cursor-not-allowed text-zinc-400'
            }`}
          >
            {swapLabel()}
          </button>
        )}

        {(actionError || writeError) && (
          <div className="rounded-lg border border-red-900 bg-red-950/30 p-3 text-xs text-red-300 max-h-32 overflow-auto">
            <p className="font-semibold mb-1">{actionError ? 'Not sent' : 'Transaction failed'}</p>
            <pre className="whitespace-pre-wrap break-all font-mono text-red-400/80">{actionError ?? describeError(writeError)}</pre>
          </div>
        )}
        {reverted && (
          <div className="rounded-lg border border-red-900 bg-red-950/30 p-3 text-xs text-red-300">
            The transaction was mined but reverted. Nothing was swapped.
          </div>
        )}
        {receipt && receipt.status === 'success' && pendingAction === 'swap' && (
          <div className="rounded-lg border border-green-900 bg-green-950/30 p-3 text-xs text-green-300">
            Swap confirmed in block {receipt.blockNumber.toString()}.
          </div>
        )}
      </div>
    </div>
  );
}
