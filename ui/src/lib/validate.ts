import { isAddress } from 'viem';
import type {
  TokenFormState,
  PoolFormState,
  RewardsFormState,
  ExtensionsFormState,
} from './types';

/**
 * Result of checking a single LP position's ticks against the pool's starting
 * tick and tick spacing. This is the SINGLE implementation of that logic —
 * both RewardsForm (inline warnings) and validateRewardsStep (the deploy
 * gate) call this function so the two can never drift apart.
 *
 * Single-sided liquidity requires tickLower >= startingTick, and both ticks
 * must be exact multiples of the pool's tickSpacing.
 */
export interface TickValidation {
  invalidLower: boolean;
  invalidSpacing: boolean;
  invalidRange: boolean;
}

export function validatePositionTicks(
  tickLower: number,
  tickUpper: number,
  startingTick: number,
  tickSpacing: number
): TickValidation {
  return {
    invalidLower: tickLower < startingTick,
    invalidSpacing: tickLower % tickSpacing !== 0 || tickUpper % tickSpacing !== 0,
    invalidRange: tickLower >= tickUpper,
  };
}

// Mirrors the "empty string falls back to the connected wallet" semantics
// used throughout ReviewAndDeploy.handleDeploy (e.g. `tokenForm.admin ||
// address`) — an empty address field is NOT an error, only a
// non-empty-but-malformed one is. Do not change that fallback behavior;
// these functions only validate it.

/**
 * Validates step 1 (Token Configuration): name, symbol, admin, total supply.
 */
export function validateTokenStep(tokenForm: TokenFormState): string[] {
  const errors: string[] = [];

  if (!tokenForm.name.trim()) {
    errors.push('Token name is required.');
  }
  if (!tokenForm.symbol.trim()) {
    errors.push('Token symbol is required.');
  }
  if (tokenForm.admin.trim() && !isAddress(tokenForm.admin.trim())) {
    errors.push('Token admin is not a valid address.');
  }

  // Total supply: digits only (no decimal point, no sign). An empty string
  // or "0" means "use the factory default" (see TokenConfigForm) and is
  // valid as-is; the on-chain MIN_TOKEN_SUPPLY is 1e18 wei (1 whole token),
  // which any non-zero digit string already satisfies once multiplied by
  // 1e18, so no separate minimum check is needed beyond the digits-only
  // shape check.
  const supplyStr = tokenForm.totalSupply.trim();
  if (supplyStr !== '' && !/^[0-9]+$/.test(supplyStr)) {
    errors.push('Total supply must be a whole number with digits only (no decimals or signs).');
  }

  return errors;
}

/**
 * Validates step 2 (Pool Configuration): only the custom paired token, since
 * that's the only pool field a user can put an invalid value into.
 */
export function validatePoolStep(poolForm: PoolFormState): string[] {
  const errors: string[] = [];

  if (poolForm.pairedToken === 'custom') {
    const custom = poolForm.customPairedToken.trim();
    if (!custom || !isAddress(custom)) {
      errors.push('Custom paired token address is invalid.');
    }
  }

  return errors;
}

/**
 * Validates step 4 (LP Rewards): recipient/admin addresses, recipient BPS,
 * LP position ticks, and position BPS.
 */
export function validateRewardsStep(
  rewardsForm: RewardsFormState,
  poolForm: PoolFormState
): string[] {
  const errors: string[] = [];

  const totalRecipientBps = rewardsForm.recipients.reduce((s, r) => s + r.bps, 0);
  rewardsForm.recipients.forEach((r, i) => {
    if (r.admin.trim() && !isAddress(r.admin.trim())) {
      errors.push(`Reward recipient ${i + 1} has an invalid admin address.`);
    }
    if (r.recipient.trim() && !isAddress(r.recipient.trim())) {
      errors.push(`Reward recipient ${i + 1} has an invalid address.`);
    }
    if (r.bps <= 0) {
      errors.push(`Reward recipient ${i + 1} must have a BPS allocation greater than 0.`);
    }
  });
  if (totalRecipientBps !== 10000) {
    errors.push(`Reward recipient BPS must sum to 10,000 (currently ${totalRecipientBps}).`);
  }

  const totalPositionBps = rewardsForm.positions.reduce((s, p) => s + p.bps, 0);
  rewardsForm.positions.forEach((p, i) => {
    const { invalidLower, invalidSpacing, invalidRange } = validatePositionTicks(
      p.tickLower,
      p.tickUpper,
      poolForm.startingTick,
      poolForm.tickSpacing
    );
    if (invalidLower) {
      errors.push(
        `LP position ${i + 1}: tick lower must be greater than or equal to the starting tick (${poolForm.startingTick.toLocaleString()}).`
      );
    }
    if (invalidSpacing) {
      errors.push(
        `LP position ${i + 1}: ticks must be multiples of the pool's tick spacing (${poolForm.tickSpacing}).`
      );
    }
    if (invalidRange) {
      errors.push(`LP position ${i + 1}: tick upper must be greater than tick lower.`);
    }
    if (p.bps <= 0) {
      errors.push(`LP position ${i + 1} must have a BPS allocation greater than 0.`);
    }
  });
  if (totalPositionBps !== 10000) {
    errors.push(`LP position BPS must sum to 10,000 (currently ${totalPositionBps}).`);
  }

  return errors;
}

/**
 * Validates step 5 (Extensions): vault admin, and (when enabled) airdrop
 * admin + merkle root.
 */
export function validateExtensionsStep(extensionsForm: ExtensionsFormState): string[] {
  const errors: string[] = [];

  if (extensionsForm.vault.enabled) {
    const vaultAdmin = extensionsForm.vault.admin.trim();
    if (vaultAdmin && !isAddress(vaultAdmin)) {
      errors.push('Vault admin is not a valid address.');
    }
  }

  if (extensionsForm.airdrop.enabled) {
    const airdropAdmin = extensionsForm.airdrop.admin.trim();
    if (airdropAdmin && !isAddress(airdropAdmin)) {
      errors.push('Airdrop admin is not a valid address.');
    }
    if (!/^0x[0-9a-fA-F]{64}$/.test(extensionsForm.airdrop.merkleRoot.trim())) {
      errors.push('Airdrop merkle root must be 0x followed by 64 hex characters.');
    }
  }

  return errors;
}

export interface ValidateDeployArgs {
  tokenForm: TokenFormState;
  poolForm: PoolFormState;
  rewardsForm: RewardsFormState;
  extensionsForm: ExtensionsFormState;
}

/**
 * Pure validation for the full deploy form. Returns a list of human-readable
 * error strings; an empty array means the config is safe to submit. This is
 * the deploy gate used by ReviewAndDeploy — it's the concatenation of the
 * same per-step checks DeployPage uses to flag which step has a problem, so
 * there is exactly one implementation of every rule.
 */
export function validateDeploy({
  tokenForm,
  poolForm,
  rewardsForm,
  extensionsForm,
}: ValidateDeployArgs): string[] {
  return [
    ...validateTokenStep(tokenForm),
    ...validatePoolStep(poolForm),
    ...validateRewardsStep(rewardsForm, poolForm),
    ...validateExtensionsStep(extensionsForm),
  ];
}
