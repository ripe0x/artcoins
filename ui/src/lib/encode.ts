import { encodeAbiParameters, parseAbiParameters, type Address } from 'viem';

export function generateSalt(): `0x${string}` {
  const random = crypto.getRandomValues(new Uint8Array(32));
  return `0x${Array.from(random).map(b => b.toString(16).padStart(2, '0')).join('')}` as `0x${string}`;
}

export function encodePoolData(buyFee: number, sellFee: number): `0x${string}` {
  const feeData = encodeAbiParameters(
    parseAbiParameters('uint24, uint24'),
    [buyFee, sellFee]
  );
  return encodeAbiParameters(
    parseAbiParameters('address, bytes, bytes'),
    ['0x0000000000000000000000000000000000000000', '0x', feeData]
  );
}

export function encodeMevLinearData(startingFee: number, endingFee: number, durationSeconds: number): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters('uint24, uint24, uint32'),
    [startingFee, endingFee, durationSeconds]
  );
}

export function encodeMevDescendingData(startingFee: number, endingFee: number, secondsToDecay: number): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters('uint24, uint24, uint256'),
    [startingFee, endingFee, BigInt(secondsToDecay)]
  );
}

export function encodeVaultData(admin: Address, lockupDays: number, vestingDays: number): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters('address, uint256, uint256'),
    [admin, BigInt(lockupDays * 86400), BigInt(vestingDays * 86400)]
  );
}

export function encodeAirdropData(admin: Address, merkleRoot: `0x${string}`, lockupDays: number, vestingDays: number): `0x${string}` {
  return encodeAbiParameters(
    parseAbiParameters('address, bytes32, uint256, uint256'),
    [admin, merkleRoot, BigInt(lockupDays * 86400), BigInt(vestingDays * 86400)]
  );
}

export function percentToFeeUnits(percent: number): number {
  return Math.round(percent * 10_000);
}

export function feeUnitsToPercent(units: number): number {
  return units / 10_000;
}

// WARNING: do NOT use this for token supply. `amount` is a JS `number`,
// which loses integer precision above 2^53 (~9.007e15) and `Math.floor`
// silently rounds any fractional bits away — for a token supply typed by a
// user as a digit string, that means silent, wrong on-chain supply values
// for anything above ~9 quadrillion whole tokens. Token supply must be
// computed with exact bigint math instead: `BigInt(totalSupplyDigits) *
// 10n ** 18n` (see ReviewAndDeploy.handleDeploy), which is safe once
// `validateDeploy` has confirmed the input is a digits-only string.
//
// This helper remains for genuinely fractional, human-scale amounts (e.g.
// display-only unit conversions) where the 2^53 range is not a concern. For
// ETH-amount inputs (e.g. dev-buy amount) use viem's `parseEther`, which
// parses the decimal string exactly instead of round-tripping through a
// JS `number`.
export function toWei(amount: number): bigint {
  return BigInt(Math.floor(amount)) * 10n ** 18n;
}
