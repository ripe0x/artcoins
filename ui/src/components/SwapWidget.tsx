import { useEffect, useMemo, useState } from 'react';
import {
  useAccount,
  useBalance,
  useChainId,
  usePublicClient,
  useReadContract,
  useReadContracts,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { formatUnits, parseUnits, type Address, type Hex } from 'viem';

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

type Direction = 'buy' | 'sell';

interface Props {
  tokenAddress: Address;
  tokenSymbol: string;
  poolKey: PoolKey;
  newMaterialIsToken0: boolean;
  /** Is the MEV module currently active? Warn user if yes. */
  mevActive?: boolean;
}

const SLIPPAGE_OPTIONS = [0.5, 1, 2, 5];
const DEFAULT_DEADLINE_SECS = 60 * 10; // 10 minutes

const inputClass =
  'w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2.5 text-base text-white placeholder-zinc-500 focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500';

export default function SwapWidget({
  tokenAddress,
  tokenSymbol,
  poolKey,
  newMaterialIsToken0,
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
  const { data: erc20ToPermit2 } = useReadContract({
    address: tokenAddress,
    abi: erc20Abi,
    functionName: 'allowance',
    args: address ? [address, addresses.permit2] : undefined,
    query: { enabled: !!address && direction === 'sell', refetchInterval: 15_000 },
  });

  const { data: permit2Allow } = useReadContracts({
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

  // ── Quote ──────────────────────────────────────────────────────────
  // Uses Uniswap V4 Quoter. The quoter function is nonpayable (not view)
  // because it uses a revert-to-return pattern internally. We use
  // simulateContract which handles this cleanly.
  useEffect(() => {
    let cancelled = false;
    if (!client || amountInWei === 0n) {
      setQuote(null);
      setQuoteError(null);
      return;
    }
    if (addresses.quoter === '0x0000000000000000000000000000000000000000') {
      setQuoteError('Quoter not configured on this chain');
      setQuote(null);
      return;
    }

    setQuoting(true);
    setQuoteError(null);

    const zeroForOne =
      direction === 'buy' ? !newMaterialIsToken0 : newMaterialIsToken0;

    (async () => {
      try {
        const { result } = await client.simulateContract({
          address: addresses.quoter,
          abi: quoterAbi,
          functionName: 'quoteExactInputSingle',
          args: [
            {
              poolKey: {
                currency0: poolKey.currency0,
                currency1: poolKey.currency1,
                fee: poolKey.fee,
                tickSpacing: poolKey.tickSpacing,
                hooks: poolKey.hooks,
              },
              zeroForOne,
              exactAmount: amountInWei,
              hookData: '0x',
            },
          ],
        });
        if (cancelled) return;
        const [amountOut] = result as readonly [bigint, bigint];
        setQuote(amountOut);
      } catch (e: unknown) {
        if (cancelled) return;
        const msg = e instanceof Error ? e.message : String(e);
        setQuoteError(msg.split('\n')[0].slice(0, 120));
        setQuote(null);
      } finally {
        if (!cancelled) setQuoting(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [
    client,
    addresses.quoter,
    amountInWei,
    direction,
    newMaterialIsToken0,
    poolKey.currency0,
    poolKey.currency1,
    poolKey.fee,
    poolKey.tickSpacing,
    poolKey.hooks,
  ]);

  const minOut = useMemo(() => {
    if (quote === null) return 0n;
    return applySlippage(quote, slippageBps);
  }, [quote, slippageBps]);

  // ── Write functions ───────────────────────────────────────────────
  const { writeContract, data: txHash, isPending, reset, error: writeError } =
    useWriteContract();

  const { data: receipt, isLoading: confirming } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const [pendingAction, setPendingAction] = useState<
    'approve-erc20' | 'approve-permit2' | 'swap' | null
  >(null);

  // Reset state when tx is confirmed
  useEffect(() => {
    if (receipt && pendingAction === 'swap') {
      setAmountIn('');
      refetchTokenBalance();
    }
    if (receipt) {
      setTimeout(() => {
        setPendingAction(null);
        reset();
      }, 2500);
    }
  }, [receipt, pendingAction, refetchTokenBalance, reset]);

  // ── Action handlers ───────────────────────────────────────────────
  const handleApproveErc20 = () => {
    setPendingAction('approve-erc20');
    writeContract({
      address: tokenAddress,
      abi: erc20Abi,
      functionName: 'approve',
      args: [addresses.permit2, MAX_UINT256],
    });
  };

  const handleApprovePermit2 = () => {
    setPendingAction('approve-permit2');
    // expiration: now + ~30 days (max uint48 is ~8.9M years, any sane value works)
    const expiration = Math.floor(Date.now() / 1000) + 30 * 86400;
    writeContract({
      address: addresses.permit2,
      abi: permit2Abi,
      functionName: 'approve',
      args: [tokenAddress, addresses.universalRouter, MAX_UINT160, expiration],
    });
  };

  const referrer = useReferrer();
  const handleSwap = () => {
    if (!address || amountInWei === 0n || quote === null) return;
    setPendingAction('swap');
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
        newMaterialIsToken0,
        weth: addresses.weth,
        token: tokenAddress,
        ethAmount: amountInWei,
        minTokenOut: minOut,
        hookData,
      });
      writeContract({
        address: addresses.universalRouter,
        abi: universalRouterAbi,
        functionName: 'execute',
        args: [commands, inputs, deadline],
        value,
      });
    } else {
      const { commands, inputs, value } = buildSellCalldata({
        poolKey,
        newMaterialIsToken0,
        weth: addresses.weth,
        token: tokenAddress,
        tokenAmount: amountInWei,
        minEthOut: minOut,
        recipient: address,
        hookData,
      });
      writeContract({
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

  const canSwap =
    isConnected &&
    amountInWei > 0n &&
    quote !== null &&
    !overBalance &&
    !needsErc20Approval &&
    !needsPermit2Approval;

  const swapButtonLabel = () => {
    if (!isConnected) return 'Connect wallet';
    if (!amountInWei) return 'Enter amount';
    if (overBalance) return `Insufficient ${balanceLabel}`;
    if (quoting) return 'Fetching quote…';
    if (quote === null) return 'No quote available';
    if (pendingAction === 'swap' && (isPending || confirming)) {
      return isPending ? 'Confirm in wallet…' : 'Swapping…';
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
              onClick={() => {
                setDirection(d);
                setAmountIn('');
                setQuote(null);
                setQuoteError(null);
              }}
              className={`px-3 py-1 text-xs font-medium rounded-md transition-colors ${
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
        {mevActive && (
          <div className="rounded-lg border border-violet-600/30 bg-violet-950/20 p-3 text-xs text-violet-200">
            <strong>Anti-sniper fee active.</strong> Buy fees are currently very high. See the MEV
            panel above for countdown.
          </div>
        )}

        {/* Amount in */}
        <div>
          <div className="flex items-center justify-between mb-1">
            <label className="text-xs text-zinc-500">
              You {direction === 'buy' ? 'pay' : 'sell'}
            </label>
            {isConnected && (
              <button
                type="button"
                onClick={() => setAmountIn(formatUnits(balance, 18))}
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
              type="text"
              inputMode="decimal"
              placeholder="0.0"
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
            disabled={isPending || confirming}
            className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 disabled:cursor-not-allowed py-3 text-sm font-semibold"
          >
            {pendingAction === 'approve-erc20' && (isPending || confirming)
              ? isPending
                ? 'Confirm in wallet…'
                : 'Approving…'
              : `1. Approve ${tokenSymbol}`}
          </button>
        ) : needsPermit2Approval ? (
          <button
            type="button"
            onClick={handleApprovePermit2}
            disabled={isPending || confirming}
            className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 disabled:cursor-not-allowed py-3 text-sm font-semibold"
          >
            {pendingAction === 'approve-permit2' && (isPending || confirming)
              ? isPending
                ? 'Confirm in wallet…'
                : 'Approving…'
              : '2. Approve Permit2'}
          </button>
        ) : (
          <button
            type="button"
            onClick={handleSwap}
            disabled={!canSwap || isPending || confirming}
            className={`w-full rounded-lg py-3 text-sm font-semibold transition-colors ${
              canSwap && !isPending && !confirming
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
        {writeError && (
          <div className="rounded-lg border border-red-900 bg-red-950/30 p-3 text-xs text-red-300 max-h-32 overflow-auto">
            <p className="font-semibold mb-1">Swap failed</p>
            <pre className="whitespace-pre-wrap break-all font-mono text-red-400/80">
              {(writeError as Error).message.slice(0, 500)}
            </pre>
          </div>
        )}

        {receipt && pendingAction === 'swap' && (
          <div className="rounded-lg border border-green-900 bg-green-950/30 p-3 text-xs text-green-300">
            Swap confirmed in block {receipt.blockNumber.toString()}.
          </div>
        )}
      </div>
    </div>
  );
}
