// v4 tick and price math in bigint, used for the implied price, fdv and the dev buy estimate.
// Ports of v4-core TickMath.getSqrtPriceAtTick and the exact in single step of SwapMath
// restricted to what a fresh single sided launch pool needs. test/curve.test.ts checks it
// against float math and against a closed form for a one position pool.
import { MAX_TICK, MIN_TICK } from './constants';

export const Q96 = 1n << 96n;

/** sqrt(1.0001^tick) * 2^96, v4-core TickMath.getSqrtPriceAtTick */
export function getSqrtPriceAtTick(tick: number): bigint {
  if (!Number.isInteger(tick) || tick < MIN_TICK || tick > MAX_TICK) throw new Error(`tick ${tick} out of range`);
  const abs = BigInt(Math.abs(tick));
  let ratio = (abs & 0x1n) !== 0n ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
  const m: [bigint, bigint][] = [
    [0x2n, 0xfff97272373d413259a46990580e213an],
    [0x4n, 0xfff2e50f5f656932ef12357cf3c7fdccn],
    [0x8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
    [0x10n, 0xffcb9843d60f6159c9db58835c926644n],
    [0x20n, 0xff973b41fa98c081472e6896dfb254c0n],
    [0x40n, 0xff2ea16466c96a3843ec78b326b52861n],
    [0x80n, 0xfe5dee046a99a2a811c461f1969c3053n],
    [0x100n, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
    [0x200n, 0xf987a7253ac413176f2b074cf7815e54n],
    [0x400n, 0xf3392b0822b70005940c7a398e4b70f3n],
    [0x800n, 0xe7159475a2c29b7443b29c7fa6e889d9n],
    [0x1000n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
    [0x2000n, 0xa9f746462d870fdf8a65dc1f90e061e5n],
    [0x4000n, 0x70d869a156d2a1b890bb3df62baf32f7n],
    [0x8000n, 0x31be135f97d08fd981231505542fcfa6n],
    [0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
    [0x20000n, 0x5d6af8dedb81196699c329225ee604n],
    [0x40000n, 0x2216e584f5fa1ea926041bedfe98n],
    [0x80000n, 0x48a170391f7dc42444e8fa2n],
  ];
  for (const [bit, mul] of m) {
    if ((abs & bit) !== 0n) ratio = (ratio * mul) >> 128n;
  }
  if (tick > 0) ratio = ((1n << 256n) - 1n) / ratio;
  // shift to q96, rounding up
  return (ratio >> 32n) + ((ratio & 0xffffffffn) === 0n ? 0n : 1n);
}

/** raw price token1/token0 at a tick, as a float (display only) */
export function tickToPrice(tick: number): number {
  return Math.pow(1.0001, tick);
}

/**
 * Coin price in eth at the starting tick. `tickIfToken0IsArtCoin` is the tick with the coin as
 * currency0, so price token1/token0 = eth per coin = 1.0001^tick.
 */
export function startPriceEthPerCoin(tickIfToken0IsArtCoin: number): number {
  return tickToPrice(tickIfToken0IsArtCoin);
}

/** implied fully diluted value in eth at the starting price, `supply` in whole coins */
export function impliedFdvEth(tickIfToken0IsArtCoin: number, supplyWholeCoins: number): number {
  return startPriceEthPerCoin(tickIfToken0IsArtCoin) * supplyWholeCoins;
}

export interface CurvePosition {
  /** token0 frame ticks, as passed to the factory */
  tickLower: number;
  tickUpper: number;
  /** coin amount (wei) seeded into this position */
  coinAmount: bigint;
}

/**
 * Coin received for `ethIn` wei buying from a fresh launch pool, fees excluded (pass the net amount).
 * Pool frame: the coin is currency1, the factory mirrors the ranges to [-upper, -lower], liquidity per
 * position L = amount1 * Q96 / (sqrtUpper - sqrtLower). A buy is zeroForOne and walks the price down
 * through the positions nearest the start first.
 */
export function quoteBuyFromFreshPool(
  startingTick: number,
  positions: CurvePosition[],
  ethIn: bigint
): { coinOut: bigint; ethUsed: bigint; exhausted: boolean } {
  let remaining = ethIn;
  let out = 0n;
  let used = 0n;
  let sqrtCur = getSqrtPriceAtTick(-startingTick);
  const ordered = [...positions].sort((a, b) => a.tickLower - b.tickLower);
  for (const p of ordered) {
    if (remaining === 0n) break;
    const sqrtLower = getSqrtPriceAtTick(-p.tickUpper);
    const sqrtUpper = getSqrtPriceAtTick(-p.tickLower);
    if (sqrtUpper <= sqrtLower) continue;
    const L = (p.coinAmount * Q96) / (sqrtUpper - sqrtLower);
    if (L === 0n) continue;
    // the price may sit above this range (gap) or inside it, never below on a launch pool
    if (sqrtCur > sqrtUpper) sqrtCur = sqrtUpper;
    if (sqrtCur <= sqrtLower) continue;
    // eth to move the price from sqrtCur down to sqrtLower: L * Q96 * (cur - lower) / (cur * lower)
    const needed = ceilDiv(L * Q96 * (sqrtCur - sqrtLower), sqrtCur * sqrtLower);
    if (remaining >= needed) {
      out += (L * (sqrtCur - sqrtLower)) / Q96;
      used += needed;
      remaining -= needed;
      sqrtCur = sqrtLower;
    } else {
      // new sqrt = L*Q96*cur / (L*Q96 + remaining*cur), rounded up
      const numerator = L * Q96 * sqrtCur;
      const denominator = L * Q96 + remaining * sqrtCur;
      const next = ceilDiv(numerator, denominator);
      out += (L * (sqrtCur - next)) / Q96;
      used += remaining;
      remaining = 0n;
      sqrtCur = next;
    }
  }
  return { coinOut: out, ethUsed: used, exhausted: remaining > 0n };
}

function ceilDiv(a: bigint, b: bigint): bigint {
  return (a + b - 1n) / b;
}
