// Form state for the v2 launch flow. Percent fields are human units; encodeV2.ts converts to the
// contract units (pips for the lp fee, 1e5 skim denominator, bps).

export interface TokenFormState {
  name: string;
  symbol: string;
  /** token admin, defaults to the connected wallet */
  admin: string;
  /** whole tokens, '' or '0' = factory default (1B) */
  totalSupply: string;
  image: string;
  metadata: string;
  context: string;
  /** metadata renderer, '' = none (default on chain json) */
  renderer: string;
}

export interface PoolFormState {
  /** v4 tick spacing. Positions and the starting tick must be multiples of it */
  tickSpacing: number;
  /** `tickIfToken0IsArtCoin`: the starting tick as if the coin were currency0. The coin is always
   *  currency1 against native eth, the contracts mirror it (pool tick = -startingTick). */
  startingTick: number;
  /** lp fee, percent of the swap amount (pips / 10_000). Max 10 */
  lpFeePercent: number;
  /** baseline skim, percent of volume (skim units / 1_000). Max 10 */
  baselineSkimPercent: number;
  /** bounty share of the skim, percent (bps / 100). The rest is the protocol side */
  bountyPercent: number;
  /** referral cap, percent of volume (skim units / 1_000). Max 1 */
  referralCapPercent: number;
  /** receives the bounty share, defaults to the connected wallet */
  bountyRecipient: string;
}

export interface MevFormState {
  enabled: boolean;
  /** starting anti sniper skim, percent of volume. Max 90, at least the baseline */
  startPercent: number;
  /** window in minutes, 1 to 180 */
  windowMin: number;
}

export type TaxMode = 0 | 1 | 2;

export interface TaxFormState {
  /** 0 none, 1 venue (tax on coin leaving a listed venue), 2 hard (canonical flows only) */
  mode: TaxMode;
  taxPercent: number;
  maxPercent: number;
  /** DEAD (burn) or the bounty recipient */
  sink: 'dead' | 'bounty';
  /** blank = token admin */
  venueAdmin: string;
  /** comma or space separated addresses, at most 16 */
  exempt: string;
}

export interface RewardRecipient {
  recipient: string;
  /** share of ALL lp rewards in bps. Project slots plus the protocol slot sum to 10_000 */
  bps: number;
}

export interface LpPosition {
  /** token0 frame ticks (coin as currency0), same frame as the starting tick */
  tickLower: number;
  tickUpper: number;
  bps: number;
}

export type PositionPreset = 'recommended' | 'default' | 'taper12' | 'custom';

export interface RewardsFormState {
  preset: PositionPreset;
  recipients: RewardRecipient[];
  positions: LpPosition[];
}

export interface VaultConfig {
  enabled: boolean;
  beneficiary: string;
  allocationPercent: number;
  lockupDays: number;
  vestingDays: number;
}

export interface AirdropConfig {
  enabled: boolean;
  sweepRecipient: string;
  allocationPercent: number;
  merkleRoot: string;
  lockupDays: number;
  vestingDays: number;
}

export interface DevBuyConfig {
  enabled: boolean;
  ethAmount: string;
  /** receives the bought coin, defaults to the connected wallet */
  recipient: string;
  /** receives unspent eth, defaults to the connected wallet */
  refundRecipient: string;
  /** whole coins, must be nonzero. Filled from the curve estimate */
  minTokenOut: string;
  /** slippage tolerance used when filling minTokenOut from the estimate, percent */
  toleranceBps: number;
}

export interface ExtensionsFormState {
  vault: VaultConfig;
  airdrop: AirdropConfig;
  devBuy: DevBuyConfig;
}

export interface LaunchForm {
  token: TokenFormState;
  pool: PoolFormState;
  mev: MevFormState;
  tax: TaxFormState;
  rewards: RewardsFormState;
  extensions: ExtensionsFormState;
}
