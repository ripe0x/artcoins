// Universal Router calldata for buying and selling a coin against its native eth pool (every v2 pool and
// the live skim pools) and, for old weth paired pools, against weth.
//
// Command order matters. Router facts (lib/universal-router, lib/v4-periphery V4Router):
//   SETTLE_ALL(currency, max)   pays the whole debt: native eth from the router's own balance (msg.value),
//                               erc20 from msg.sender through permit2
//   TAKE_ALL(currency, min)     pays the whole credit to msg.sender, reverts below `min`
//   TAKE(currency, to, amount)  amount 0 = the whole credit, `to` address(2) = the router itself
//   UNWRAP_WETH(to, min)        unwraps the router's own weth balance, reverts when it holds less than `min`
// Old sell path (UI-06): TAKE_ALL sent the weth to the user, UNWRAP_WETH then saw a zero balance and
// reverted InsufficientETH. The weth sell now takes to the router first, then unwraps. Native pools need
// neither wrap nor unwrap: the PoolManager sends eth straight to the user on TAKE_ALL.
import { encodeAbiParameters, type Address, type Hex } from 'viem';
import type { PoolKey } from './pool';
import { ZERO_ADDRESS } from './constants';

// Universal Router commands
export const CMD_V4_SWAP = 0x10;
export const CMD_WRAP_ETH = 0x0b;
export const CMD_UNWRAP_WETH = 0x0c;

// V4 router actions (lib/v4-periphery Actions.sol)
export const ACT_SWAP_EXACT_IN_SINGLE = 0x06;
export const ACT_SETTLE = 0x0b; // (Currency, uint256 amount, bool payerIsUser)
export const ACT_SETTLE_ALL = 0x0c; // (Currency, uint256 maxAmount), payer is always msg.sender
export const ACT_TAKE = 0x0e; // (Currency, address recipient, uint256 amount)
export const ACT_TAKE_ALL = 0x0f; // (Currency, uint256 minAmount), recipient is always msg.sender

/** ActionConstants: recipient meaning the router itself, amount meaning "the whole open delta" */
export const ADDRESS_THIS: Address = '0x0000000000000000000000000000000000000002';
export const OPEN_DELTA = 0n;
/** WRAP_ETH amount sentinel: the router's whole eth balance */
export const CONTRACT_BALANCE: bigint = 1n << 255n;

const ETH_ADDRESS: Address = ZERO_ADDRESS;

function packBytes1(values: number[]): Hex {
  return `0x${values.map((v) => v.toString(16).padStart(2, '0')).join('')}` as Hex;
}

const poolKeyComponents = [
  { name: 'currency0', type: 'address' },
  { name: 'currency1', type: 'address' },
  { name: 'fee', type: 'uint24' },
  { name: 'tickSpacing', type: 'int24' },
  { name: 'hooks', type: 'address' },
] as const;

const exactInputSingleComponents = [
  { name: 'poolKey', type: 'tuple', components: poolKeyComponents },
  { name: 'zeroForOne', type: 'bool' },
  { name: 'amountIn', type: 'uint128' },
  { name: 'amountOutMinimum', type: 'uint128' },
  { name: 'hookData', type: 'bytes' },
] as const;

const same = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

export type PoolKind = 'native' | 'weth';

/** The pool pairs the coin with native eth, with `weth` (old pools), or is not a pool this ui can trade. */
export function classifyPool(poolKey: PoolKey, coin: Address, weth: Address): PoolKind | null {
  const coinIs0 = same(poolKey.currency0, coin);
  const coinIs1 = same(poolKey.currency1, coin);
  if (coinIs0 === coinIs1) return null;
  const other = coinIs0 ? poolKey.currency1 : poolKey.currency0;
  if (same(other, ETH_ADDRESS)) return 'native';
  if (same(other, weth)) return 'weth';
  return null;
}

/** Direction is derived from the pool key and the coin address, never from a chain read. */
export function coinIsCurrency0(poolKey: PoolKey, coin: Address): boolean {
  return same(poolKey.currency0, coin);
}

function swapInput(p: {
  poolKey: PoolKey;
  zeroForOne: boolean;
  amountIn: bigint;
  amountOutMinimum: bigint;
  hookData: Hex;
}): Hex {
  // abi.encode(struct) with a dynamic member carries a leading offset word, V4Router decodes it
  return encodeAbiParameters(
    [{ type: 'tuple', components: exactInputSingleComponents }],
    [
      {
        poolKey: {
          currency0: p.poolKey.currency0,
          currency1: p.poolKey.currency1,
          fee: p.poolKey.fee,
          tickSpacing: p.poolKey.tickSpacing,
          hooks: p.poolKey.hooks,
        },
        zeroForOne: p.zeroForOne,
        amountIn: p.amountIn,
        amountOutMinimum: p.amountOutMinimum,
        hookData: p.hookData,
      },
    ]
  );
}

const addrUint = [{ type: 'address' }, { type: 'uint256' }] as const;
const UINT128_MAX = (1n << 128n) - 1n;

function checkAmounts(amountIn: bigint, minOut: bigint): void {
  if (amountIn <= 0n || amountIn > UINT128_MAX) throw new Error('amount in out of range');
  // never send a swap without a floor: a missing quote must block the swap, not become a zero minimum
  if (minOut <= 0n || minOut > UINT128_MAX) throw new Error('refusing a swap with a zero or invalid minimum out');
}

export interface BuiltSwap {
  commands: Hex;
  inputs: Hex[];
  value: bigint;
}

export interface BuildBuyArgs {
  poolKey: PoolKey;
  token: Address;
  /** weth address, only used to recognise an old weth pool */
  weth: Address;
  ethAmount: bigint;
  /** floor from a fresh quote, must be > 0 */
  minTokenOut: bigint;
  hookData?: Hex;
}

/**
 * Buy. Native pool: V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL(eth), TAKE_ALL(coin)] with msg.value = eth.
 * Weth pool: WRAP_ETH to the router first, then V4_SWAP with SETTLE(payerIsUser false).
 */
export function buildBuyCalldata(args: BuildBuyArgs): BuiltSwap {
  const kind = classifyPool(args.poolKey, args.token, args.weth);
  if (!kind) throw new Error('pool is not a coin / native eth or coin / weth pool');
  checkAmounts(args.ethAmount, args.minTokenOut);
  const hookData: Hex = args.hookData ?? '0x';

  if (kind === 'native') {
    // eth is currency0 (address 0 sorts first), buying the coin is zeroForOne
    const swap = swapInput({
      poolKey: args.poolKey,
      zeroForOne: true,
      amountIn: args.ethAmount,
      amountOutMinimum: args.minTokenOut,
      hookData,
    });
    const actions = packBytes1([ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL]);
    const settle = encodeAbiParameters([...addrUint], [ETH_ADDRESS, args.ethAmount]);
    const take = encodeAbiParameters([...addrUint], [args.token, args.minTokenOut]);
    return {
      commands: packBytes1([CMD_V4_SWAP]),
      inputs: [encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], [actions, [swap, settle, take]])],
      value: args.ethAmount,
    };
  }

  // weth pool
  const wethIs0 = same(args.poolKey.currency0, args.weth);
  const swap = swapInput({
    poolKey: args.poolKey,
    zeroForOne: wethIs0,
    amountIn: args.ethAmount,
    amountOutMinimum: args.minTokenOut,
    hookData,
  });
  const actions = packBytes1([ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE, ACT_TAKE_ALL]);
  const settle = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }, { type: 'bool' }],
    [args.weth, args.ethAmount, false]
  );
  const take = encodeAbiParameters([...addrUint], [args.token, args.minTokenOut]);
  const wrap = encodeAbiParameters([...addrUint], [ADDRESS_THIS, CONTRACT_BALANCE]);
  return {
    commands: packBytes1([CMD_WRAP_ETH, CMD_V4_SWAP]),
    inputs: [wrap, encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], [actions, [swap, settle, take]])],
    value: args.ethAmount,
  };
}

export interface BuildSellArgs {
  poolKey: PoolKey;
  token: Address;
  weth: Address;
  tokenAmount: bigint;
  /** floor from a fresh quote, must be > 0 */
  minEthOut: bigint;
  /** receives the eth, used only on the weth path (the native path pays msg.sender) */
  recipient: Address;
  hookData?: Hex;
}

/**
 * Sell. Native pool: V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL(coin), TAKE_ALL(eth)], eth lands at msg.sender.
 * Weth pool: V4_SWAP[SWAP_EXACT_IN_SINGLE, SETTLE_ALL(coin), TAKE(weth, router)] then UNWRAP_WETH(recipient).
 * The user approves coin -> permit2 and permit2 -> router beforehand.
 */
export function buildSellCalldata(args: BuildSellArgs): BuiltSwap {
  const kind = classifyPool(args.poolKey, args.token, args.weth);
  if (!kind) throw new Error('pool is not a coin / native eth or coin / weth pool');
  checkAmounts(args.tokenAmount, args.minEthOut);
  const hookData: Hex = args.hookData ?? '0x';
  const swap = swapInput({
    poolKey: args.poolKey,
    zeroForOne: coinIsCurrency0(args.poolKey, args.token),
    amountIn: args.tokenAmount,
    amountOutMinimum: args.minEthOut,
    hookData,
  });
  const settle = encodeAbiParameters([...addrUint], [args.token, args.tokenAmount]);

  if (kind === 'native') {
    const actions = packBytes1([ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL]);
    const take = encodeAbiParameters([...addrUint], [ETH_ADDRESS, args.minEthOut]);
    return {
      commands: packBytes1([CMD_V4_SWAP]),
      inputs: [encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], [actions, [swap, settle, take]])],
      value: 0n,
    };
  }

  const actions = packBytes1([ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE]);
  const take = encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }, { type: 'uint256' }],
    [args.weth, ADDRESS_THIS, OPEN_DELTA]
  );
  const unwrap = encodeAbiParameters([...addrUint], [args.recipient, args.minEthOut]);
  return {
    commands: packBytes1([CMD_V4_SWAP, CMD_UNWRAP_WETH]),
    inputs: [encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], [actions, [swap, settle, take]]), unwrap],
    value: 0n,
  };
}

/** Apply slippage tolerance (bps) to an expected amount. 0 bps keeps the quote, never goes below 1 wei. */
export function applySlippage(expected: bigint, slippageBps: number): bigint {
  if (!Number.isFinite(slippageBps) || slippageBps < 0 || slippageBps >= 10_000) throw new Error('slippage out of range');
  const out = (expected * BigInt(10_000 - Math.round(slippageBps))) / 10_000n;
  return out > 0n ? out : 0n;
}

/**
 * Execution price versus the pool mid price, in percent, positive = worse than mid. Includes fees and the
 * anti sniper skim because the quote does. `midCoinPerEth` is coin per eth at the current tick.
 * buy:  amountIn eth,  amountOut coin  -> executed coin per eth = out / in
 * sell: amountIn coin, amountOut eth   -> executed coin per eth = in / out
 */
export function priceImpactPercent(
  direction: 'buy' | 'sell',
  amountIn: bigint,
  amountOut: bigint,
  midCoinPerEth: number
): number | null {
  if (amountIn <= 0n || amountOut <= 0n || !(midCoinPerEth > 0) || !Number.isFinite(midCoinPerEth)) return null;
  const executed = direction === 'buy' ? Number(amountOut) / Number(amountIn) : Number(amountIn) / Number(amountOut);
  if (!Number.isFinite(executed) || executed <= 0) return null;
  return direction === 'buy' ? (1 - executed / midCoinPerEth) * 100 : (executed / midCoinPerEth - 1) * 100;
}

/** Permit2 only reads `amount` and `expiration` as uint160 / uint48 */
export const MAX_UINT160 = (1n << 160n) - 1n;
export const MAX_UINT256 = (1n << 256n) - 1n;

export { ETH_ADDRESS };
