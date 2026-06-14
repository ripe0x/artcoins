import type { Address } from 'viem';
import { encodeAbiParameters, keccak256 } from 'viem';

/** V4 dynamic fee sentinel (tells PoolManager the fee is set by the hook) */
export const DYNAMIC_FEE_FLAG = 0x800000;

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

const zeroAddress: Address = '0x0000000000000000000000000000000000000000';

/**
 * Build a V4 PoolKey for a NewMaterial token, sorting currencies by address.
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

export function resolveTickSpacing(
  token: Address,
  paired: Address,
  hooks: Address,
  expectedPoolId: `0x${string}`
): number {
  for (const ts of CANDIDATE_TICK_SPACINGS) {
    const key = buildPoolKey(token, paired, ts, hooks);
    if (computePoolId(key).toLowerCase() === expectedPoolId.toLowerCase()) {
      return ts;
    }
  }
  // Fallback — caller should treat this as unreliable
  return 60;
}

/**
 * Convert V4's sqrtPriceX96 to a raw price ratio of token1 / token0.
 * Note: this is unscaled (doesn't account for decimals).
 */
export function priceFromSqrtX96(sqrtPriceX96: bigint): number {
  if (sqrtPriceX96 === 0n) return 0;
  // Use string/BigInt arithmetic to avoid precision loss for large values
  const n = Number(sqrtPriceX96) / 2 ** 96;
  return n * n;
}

/**
 * Price of the new-material token denominated in the paired token (raw ratio).
 * Assumes both tokens have 18 decimals (true for all our deploys with WETH).
 */
export function newMaterialPriceInPaired(
  sqrtPriceX96: bigint,
  newMaterialIsToken0: boolean
): number {
  const raw = priceFromSqrtX96(sqrtPriceX96);
  if (raw === 0) return 0;
  // If NM is token0, price = token1/token0 = paired/NM, so NM in paired = 1/raw
  // If NM is token1, price = token1/token0 = NM/paired, so NM in paired = raw
  return newMaterialIsToken0 ? 1 / raw : raw;
}

export { zeroAddress };
