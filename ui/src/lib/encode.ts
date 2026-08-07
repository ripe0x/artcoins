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

