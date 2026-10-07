// Mirror of src/Constants.sol (the values the ui needs). The v2 contracts enforce these; the ui uses
// them to validate before sending. test/constants.test.ts pins the numbers, update both together.
export const BPS = 10_000;
/** skim and referral cap denominator: 100_000 = 100% of volume */
export const SKIM_DENOMINATOR = 100_000;
/** uniswap v4 lp fee denominator: 1_000_000 = 100%, a pip is 1e-6 */
export const FEE_DENOMINATOR = 1_000_000;

export const MAX_LP_FEE = 100_000; // 10%, in pips
export const MAX_SKIM_BPS = 90_000; // anti sniper skim ceiling, SKIM_DENOMINATOR units
export const MAX_BASELINE_SKIM_BPS = 10_000; // 10% of volume
export const MAX_REFERRAL_CAP_OF_VOLUME = 1_000; // 1% of volume
export const MAX_BOUNTY_BPS = 9_999;

export const MIN_MEV_WINDOW = 60; // seconds
export const DEFAULT_MEV_WINDOW = 69 * 60;
export const MAX_MEV_WINDOW = 180 * 60;
export const DEFAULT_START_SKIM_BPS = 68_690;

export const MAX_REWARD_PARTICIPANTS = 7; // project slots plus the protocol slot
export const MAX_LP_POSITIONS = 14;
export const DEFAULT_TOKEN_SUPPLY = 1_000_000_000n * 10n ** 18n;
export const MIN_TOKEN_SUPPLY = 10n ** 18n;
export const MAX_EXTENSIONS = 10;
export const MAX_EXTENSION_BPS = 9_000;
export const MAX_PROTOCOL_FEE_BPS = 3_000;
export const MAX_DEPLOY_FEE = 10n ** 18n;

/** Constants.MAX_ALLOWED: bound on the assembled token allowlist (seeded entries plus the launch's own) */
export const MAX_ALLOWED = 64;

/**
 * ArtCoinsTokenV2.MAX_*_BYTES (the factory checks the same caps before deploying). Utf8 BYTES, not
 * characters. test/launchRules.test.ts reads src/v2/ArtCoinsTokenV2.sol and fails when these drift.
 */
export const MAX_NAME_BYTES = 64;
export const MAX_SYMBOL_BYTES = 16;
export const MAX_IMAGE_BYTES = 2_048;
export const MAX_METADATA_BYTES = 4_096;
export const MAX_CONTEXT_BYTES = 4_096;

export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const;

/** v4 TickMath bounds */
export const MIN_TICK = -887_272;
export const MAX_TICK = 887_272;

export const SECONDS_PER_DAY = 86_400;
/** extension contract limits (ArtCoinsVaultV2, ArtCoinsAirdropV2), not part of Constants.sol */
export const VAULT_MIN_LOCKUP_DAYS = 7;
export const VAULT_MIN_VESTING_DAYS = 90;
export const EXTENSION_MAX_DURATION_DAYS = 3_650;
