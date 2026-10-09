// Mirror of script/LaunchDefaults.sol (the 4 position presets and the 12 position taper) plus the
// live coin 111 fee numbers. Position offsets are from the starting tick, token0 frame, spacing 200.
import {
  BPS,
  DEFAULT_MEV_WINDOW,
  DEFAULT_START_SKIM_BPS,
} from './constants';
import type { LpPosition, PositionPreset } from './types';

export const DEFAULT_TICK_SPACING = 200;
/** LaunchTestToken / ui default, about 0.1 eth fdv at 1B supply */
export const DEFAULT_STARTING_TICK = -230_400;

/** [lowerOffset, upperOffset, bps] */
type Offsets = readonly (readonly [number, number, number])[];

const DEFAULT_4: Offsets = [
  [0, 16_400, 1000],
  [16_400, 75_400, 6000],
  [75_400, 89_400, 2000],
  [89_400, 110_400, 1000],
];

/** LaunchDefaults.buildRecommendedPositions, the ui default (25/45/20/10) */
const RECOMMENDED_4: Offsets = [
  [0, 16_400, 2500],
  [16_400, 75_400, 4500],
  [75_400, 89_400, 2000],
  [89_400, 110_400, 1000],
];

/** LaunchDefaults.buildLayerThinFloor12Positions */
const TAPER_12: Offsets = [
  [0, 1_400, 50],
  [1_400, 3_400, 150],
  [3_400, 6_000, 300],
  [6_000, 9_400, 500],
  [9_400, 14_000, 800],
  [14_000, 19_400, 1300],
  [19_400, 26_000, 1700],
  [26_000, 33_000, 1700],
  [33_000, 40_000, 1300],
  [40_000, 47_000, 1000],
  [47_000, 53_400, 800],
  [53_400, 60_000, 400],
];

const PRESETS: Record<Exclude<PositionPreset, 'custom'>, Offsets> = {
  recommended: RECOMMENDED_4,
  default: DEFAULT_4,
  taper12: TAPER_12,
};

export const PRESET_LABELS: Record<PositionPreset, string> = {
  recommended: 'Recommended (4 positions, 25/45/20/10)',
  default: 'Baseline (4 positions, 10/60/20/10)',
  taper12: 'Thin floor taper (12 positions)',
  custom: 'Custom',
};

/** Presets assume tick spacing 200 (every offset is a multiple of 200). */
export function presetPositions(preset: Exclude<PositionPreset, 'custom'>, startingTick: number): LpPosition[] {
  return PRESETS[preset].map(([lo, hi, bps]) => ({
    tickLower: startingTick + lo,
    tickUpper: startingTick + hi,
    bps,
  }));
}

export function presetFitsSpacing(startingTick: number, tickSpacing: number): boolean {
  return startingTick % tickSpacing === 0 && DEFAULT_TICK_SPACING % tickSpacing === 0 && 200 % tickSpacing === 0;
}

/**
 * Fee defaults, copied from the live coin 111 pool (skimConfig: lpFeePips 5000, baseline 600 bps,
 * bounty 8333, max referral 25 bps) and Constants.DEFAULT_START_SKIM_BPS / DEFAULT_MEV_WINDOW.
 */
export const FEE_DEFAULTS = {
  lpFeePercent: 0.5, // 5000 pips
  baselineSkimPercent: 6, // 600 bps
  bountyPercent: 83.33, // 8333 bps
  referralCapPercent: 0.25, // 25 bps
  mevStartPercent: (DEFAULT_START_SKIM_BPS * 100) / BPS, // 68.69
  mevWindowMin: DEFAULT_MEV_WINDOW / 60, // 69
} as const;
