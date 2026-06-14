export interface TokenFormState {
  name: string;
  symbol: string;
  admin: string;
  totalSupply: string;
  image: string;
  metadata: string;
  context: string;
}

export interface PoolFormState {
  pairedToken: string;
  customPairedToken: string;
  tickSpacing: number;
  startingTick: number;
  buyFeePercent: number;
  sellFeePercent: number;
}

export type MevModuleType = 'none' | 'linear' | 'descending' | 'timeDelay';

export interface MevFormState {
  moduleType: MevModuleType;
  linearStartPercent: number;
  linearEndPercent: number;
  linearDurationMin: number;
  descStartPercent: number;
  descEndPercent: number;
  descDurationSec: number;
  timeDelaySec: number;
}

export interface RewardRecipient {
  admin: string;
  recipient: string;
  bps: number;
}

export interface LpPosition {
  tickLower: number;
  tickUpper: number;
  bps: number;
}

export interface RewardsFormState {
  mode: 'simple' | 'advanced';
  recipients: RewardRecipient[];
  positions: LpPosition[];
}

export interface VaultConfig {
  enabled: boolean;
  admin: string;
  allocationPercent: number;
  lockupDays: number;
  vestingDays: number;
}

export interface AirdropConfig {
  enabled: boolean;
  admin: string;
  allocationPercent: number;
  merkleRoot: string;
  lockupDays: number;
  vestingDays: number;
}

export interface DevBuyConfig {
  enabled: boolean;
  ethAmount: string;
  allocationPercent: number;
}

export interface ExtensionsFormState {
  vault: VaultConfig;
  airdrop: AirdropConfig;
  devBuy: DevBuyConfig;
}
