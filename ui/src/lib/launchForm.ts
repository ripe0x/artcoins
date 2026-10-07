import { DEFAULT_STARTING_TICK, DEFAULT_TICK_SPACING, FEE_DEFAULTS, presetPositions } from './launchDefaults';
import { projectSideBps } from './encodeV2';
import type { LaunchForm } from './types';

/**
 * Defaults mirror the live coin 111 fee numbers and the LaunchDefaults presets. `protocolBps` is the
 * factory's `defaultProtocolFeeBps` (read from chain), the single project recipient takes the rest.
 */
export function defaultLaunchForm(protocolBps = 2_000): LaunchForm {
  return {
    token: {
      name: '',
      symbol: '',
      admin: '',
      totalSupply: '1000000000',
      image: '',
      metadata: '',
      context: '',
      renderer: '',
    },
    pool: {
      tickSpacing: DEFAULT_TICK_SPACING,
      startingTick: DEFAULT_STARTING_TICK,
      lpFeePercent: FEE_DEFAULTS.lpFeePercent,
      baselineSkimPercent: FEE_DEFAULTS.baselineSkimPercent,
      bountyPercent: FEE_DEFAULTS.bountyPercent,
      referralCapPercent: FEE_DEFAULTS.referralCapPercent,
      bountyRecipient: '',
    },
    mev: {
      enabled: true,
      startPercent: FEE_DEFAULTS.mevStartPercent,
      windowMin: FEE_DEFAULTS.mevWindowMin,
    },
    restriction: { restricted: false, allowed: '' },
    rewards: {
      preset: 'recommended',
      // the factory appends the protocol slot, so the project side sums to 10_000 - protocolBps
      recipients: [{ recipient: '', bps: projectSideBps(protocolBps) }],
      positions: presetPositions('recommended', DEFAULT_STARTING_TICK),
    },
    extensions: {
      vault: { enabled: false, beneficiary: '', allocationPercent: 10, lockupDays: 30, vestingDays: 90 },
      airdrop: { enabled: false, sweepRecipient: '', allocationPercent: 5, merkleRoot: '', lockupDays: 7, vestingDays: 30 },
      devBuy: { enabled: false, ethAmount: '0.1', recipient: '', refundRecipient: '', minTokenOut: '', toleranceBps: 500 },
    },
  };
}

