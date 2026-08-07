import type { Address } from 'viem';
import { encodeAbiParameters, keccak256 } from 'viem';

/** V4 dynamic fee sentinel (tells PoolManager the fee is set by the hook) */
const DYNAMIC_FEE_FLAG = 0x800000;

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

/**
 * Build a V4 PoolKey for an artcoin token, sorting currencies by address.
 */
export function buildPoolKey(
  token: Address,
  paired: Address,
  tickSpacing: number,
  hooks: Address,
  fee: number = DYNAMIC_FEE_FLAG
): PoolKey {
  const [c0, c1] =
    token.toLowerCase() < paired.toLowerCase() ? [token, paired] : [paired, token];
  return { currency0: c0, currency1: c1, fee, tickSpacing, hooks };
}

/**
 * Compute the poolId (= keccak256 of abi.encoded PoolKey).
 */
export function computePoolId(key: PoolKey): `0x${string}` {
  const encoded = encodeAbiParameters(
    [
      { type: 'address' },
      { type: 'address' },
      { type: 'uint24' },
      { type: 'int24' },
      { type: 'address' },
    ],
    [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]
  );
  return keccak256(encoded);
}

/**
 * The TokenCreated event doesn't include tickSpacing, so we derive it by
 * trying common values and matching the resulting poolId against the event's.
 * Every deploy via our factory uses tickSpacing=60, so the first try hits.
 */
const CANDIDATE_TICK_SPACINGS = [60, 10, 200, 1, 30, 100];

/**
 * Returns the tickSpacing whose derived poolId matches `expectedPoolId`, or
 * `null` when none of the candidates match. `null` means we don't have a
 * trustworthy PoolKey for this pool — callers must NOT substitute a fallback
 * value; a wrong tickSpacing produces a poolKey whose poolId doesn't match
 * the real pool, which would make a swap widget quote/swap against a
 * nonexistent pool.
 */
export function resolveTickSpacing(
  token: Address,
  paired: Address,
  hooks: Address,
  expectedPoolId: `0x${string}`
): number | null {
  for (const ts of CANDIDATE_TICK_SPACINGS) {
    const key = buildPoolKey(token, paired, ts, hooks);
    if (computePoolId(key).toLowerCase() === expectedPoolId.toLowerCase()) {
      return ts;
    }
  }
  return null;
}

/**
 * Convert V4's sqrtPriceX96 to a raw price ratio of token1 / token0.
 * Note: this is unscaled (doesn't account for decimals).
 */
function priceFromSqrtX96(sqrtPriceX96: bigint): number {
  if (sqrtPriceX96 === 0n) return 0;
  // Approximate float conversion for display only — converts sqrtPriceX96 to
  // a JS `number` before squaring, so this is not exact for large values.
  // Fine for UI price display; do not use for on-chain amounts.
  const n = Number(sqrtPriceX96) / 2 ** 96;
  return n * n;
}

/**
 * Price of the artcoin token denominated in the paired token (raw ratio).
 * Assumes both tokens have 18 decimals (true for all our deploys with WETH).
 */
export function artCoinPriceInPaired(
  sqrtPriceX96: bigint,
  artCoinIsToken0: boolean
): number {
  const raw = priceFromSqrtX96(sqrtPriceX96);
  if (raw === 0) return 0;
  // If the artcoin is token0, price = token1/token0 = paired/artcoin, so artcoin in paired = 1/raw
  // If the artcoin is token1, price = token1/token0 = artcoin/paired, so artcoin in paired = raw
  return artCoinIsToken0 ? 1 / raw : raw;
}
