import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { decodeFunctionData, encodeFunctionData, toFunctionSelector, getAbiItem, type Address, type Hex } from 'viem';
import { factoryV2Abi } from '../src/lib/abi/v2/factory';
import {
  buildLaunchConfigV2,
  encodeDevBuyDataV2,
  LaunchConfigError,
  maxBountyBps,
  percentToBps,
  percentToPips,
  percentToSkim,
  validateLaunch,
  type LaunchContext,
} from '../src/lib/encodeV2';
import { defaultLaunchForm } from '../src/lib/launchForm';
import { presetPositions } from '../src/lib/launchDefaults';
import { DEAD } from '../src/lib/constants';
import type { LaunchForm } from '../src/lib/types';

const SENDER: Address = '0x00000000000000000000000000000000000A11CE'.replace(/A11CE$/, 'a11ce') as Address;
const ctx = (over: Partial<LaunchContext> = {}): LaunchContext => ({
  sender: '0x1111111111111111111111111111111111111111',
  hook: '0x2222222222222222222222222222222222222222',
  locker: '0x3333333333333333333333333333333333333333',
  mevModule: '0x4444444444444444444444444444444444444444',
  vault: '0x5555555555555555555555555555555555555555',
  airdrop: '0x6666666666666666666666666666666666666666',
  devBuy: '0x7777777777777777777777777777777777777777',
  protocolBps: 2000,
  minProtocolSkimShareBps: 1667,
  deployFee: 69_000_000_000_000_000n,
  salt: `0x${'ab'.repeat(32)}` as Hex,
  ...over,
});
const form = (): LaunchForm => {
  const f = defaultLaunchForm(2000);
  f.token.name = 'Test';
  f.token.symbol = 'TST';
  return f;
};
void SENDER;

test('deployToken selector and tuple signature match the compiled interface artifact', (t) => {
  const art = '../../foundry-out/IArtCoinsFactoryV2.sol/IArtCoinsFactoryV2.json';
  const path = new URL(art, import.meta.url);
  if (!existsSync(path)) return t.skip('foundry-out artifact not built');
  const ids = JSON.parse(readFileSync(path, 'utf8')).methodIdentifiers as Record<string, string>;
  const item = getAbiItem({ abi: factoryV2Abi, name: 'deployToken' });
  const selector = toFunctionSelector(item).slice(2);
  const entry = Object.entries(ids).find(([sig]) => sig.startsWith('deployToken('));
  assert.ok(entry);
  assert.equal(selector, entry![1]);
  assert.equal(selector, '73dd3f0f');
});

test('default form builds a config that encodes and decodes through the factory abi', () => {
  const c = ctx();
  const built = buildLaunchConfigV2(form(), c);
  const data = encodeFunctionData({ abi: factoryV2Abi, functionName: 'deployToken', args: [built.config] });
  assert.equal(data.slice(0, 10), '0x73dd3f0f');
  const back = decodeFunctionData({ abi: factoryV2Abi, data });
  assert.equal(back.functionName, 'deployToken');
  const cfg = (back.args as readonly unknown[])[0] as typeof built.config;
  assert.equal(cfg.token.tokenAdmin, '0x1111111111111111111111111111111111111111');
  assert.equal(cfg.token.renderer, '0x0000000000000000000000000000000000000000');
  assert.equal(cfg.pool.tickIfToken0IsArtCoin, -230400);
  assert.equal(cfg.pool.tickSpacing, 200);
});

test('units: pips, skim denominator, bps, window seconds', () => {
  const { config } = buildLaunchConfigV2(form(), ctx());
  assert.equal(config.fee.lpFee, 5000); // 0.5% in 1e6 pips
  assert.equal(config.fee.baselineSkimBps, 6000); // 6% of 1e5
  assert.equal(config.fee.bountyBps, 8333);
  assert.equal(config.fee.maxReferralBpsOfVolume, 250);
  assert.equal(config.mev.startingSkimBps, 68_690);
  assert.equal(config.mev.windowSeconds, 69 * 60);
  assert.equal(percentToPips(10), 100_000);
  assert.equal(percentToSkim(1), 1_000);
  assert.equal(percentToBps(1), 100);
});

test('locker: project side sums to 10000 minus the protocol slot and positions mirror LaunchDefaults', () => {
  const { config } = buildLaunchConfigV2(form(), ctx());
  assert.deepEqual(config.locker.rewardBps, [8000]);
  assert.equal(config.locker.rewardBps.reduce((a, b) => a + b, 0) + 2000, 10_000);
  assert.deepEqual(config.locker.positionBps, [2500, 4500, 2000, 1000]);
  assert.deepEqual(config.locker.tickLower, [-230400, -214000, -155000, -141000]);
  assert.deepEqual(config.locker.tickUpper, [-214000, -155000, -141000, -120000]);
  assert.equal(presetPositions('taper12', -190_400).at(-1)!.tickUpper, -130_400);
  assert.equal(presetPositions('taper12', -190_400).reduce((s, p) => s + p.bps, 0), 10_000);
});

test('value is deployFee plus extension eth, dev buy takes no supply', () => {
  const f = form();
  f.extensions.devBuy = { enabled: true, ethAmount: '0.25', recipient: '', refundRecipient: '', minTokenOut: '1000', toleranceBps: 500 };
  const built = buildLaunchConfigV2(f, ctx());
  assert.equal(built.extensionValue, 250_000_000_000_000_000n);
  assert.equal(built.value, 69_000_000_000_000_000n + 250_000_000_000_000_000n);
  const ext = built.config.extensions[0];
  assert.equal(ext.extensionBps, 0);
  assert.equal(ext.msgValue, 250_000_000_000_000_000n);
  assert.equal((ext.extensionData.length - 2) / 2, 96); // ArtCoinsUniv4EthDevBuyV2 requires exactly 96 bytes
  assert.equal(ext.extensionData, encodeDevBuyDataV2(ctx().sender, ctx().sender, 1000n * 10n ** 18n));
});

test('dev buy with a zero min out is rejected', () => {
  const f = form();
  f.extensions.devBuy = { enabled: true, ethAmount: '0.1', recipient: '', refundRecipient: '', minTokenOut: '0', toleranceBps: 500 };
  assert.throws(() => buildLaunchConfigV2(f, ctx()), LaunchConfigError);
  f.extensions.devBuy.minTokenOut = '';
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'devBuy.minTokenOut'));
});

test('reward bps that ignore the protocol slot are rejected (UI-05)', () => {
  const f = form();
  f.rewards.recipients = [{ recipient: '', bps: 10_000 }];
  const issues = validateLaunch(f, ctx());
  assert.ok(issues.some((i) => i.field === 'rewards.sum' && i.severity === 'error'));
  assert.throws(() => buildLaunchConfigV2(f, ctx()), LaunchConfigError);
  // with a zero protocol slot (owner path) 10000 is right
  assert.equal(validateLaunch(f, ctx({ protocolBps: 0 })).filter((i) => i.severity === 'error').length, 0);
});

test('bounty share is capped by the factory minimum protocol share', () => {
  assert.equal(maxBountyBps(1667), 8333);
  assert.equal(maxBountyBps(0), 9999);
  const f = form();
  f.pool.bountyPercent = 90;
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'pool.bounty'));
});

test('mev window is limited to 180 minutes and the start to 90 percent and the baseline', () => {
  const f = form();
  f.mev.windowMin = 181;
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'mev.window'));
  f.mev.windowMin = 69;
  f.mev.startPercent = 91;
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'mev.start'));
  f.mev.startPercent = 5; // below the 6% baseline
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'mev.start'));
  f.mev.enabled = false;
  const { config } = buildLaunchConfigV2(f, ctx());
  assert.deepEqual(config.mev, { module: '0x0000000000000000000000000000000000000000', startingSkimBps: 0, windowSeconds: 0 });
});

test('mev on without a configured module is refused, not silently disabled', () => {
  assert.ok(validateLaunch(form(), ctx({ mevModule: '0x0000000000000000000000000000000000000000' })).some((i) => i.field === 'mev'));
});

test('tax modes encode as the token and factory expect', () => {
  const f = form();
  f.tax = { mode: 1, taxPercent: 2, maxPercent: 5, sink: 'dead', venueAdmin: '', exempt: '' };
  let { config } = buildLaunchConfigV2(f, ctx());
  assert.deepEqual([config.tax.mode, config.tax.taxBps, config.tax.taxBpsMax, config.tax.taxSink], [1, 200, 500, DEAD]);
  f.tax.sink = 'bounty';
  ({ config } = buildLaunchConfigV2(f, ctx()));
  assert.equal(config.tax.taxSink, '0x1111111111111111111111111111111111111111'); // defaults to the sender
  f.tax = { mode: 2, taxPercent: 3, maxPercent: 3, sink: 'dead', venueAdmin: '', exempt: '0x2222222222222222222222222222222222222222' };
  ({ config } = buildLaunchConfigV2(f, ctx()));
  assert.deepEqual([config.tax.mode, config.tax.taxBps, config.tax.taxBpsMax, config.tax.exempt.length], [2, 0, 0, 0]);
  f.tax = { mode: 1, taxPercent: 2, maxPercent: 25, sink: 'dead', venueAdmin: '', exempt: '' };
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'tax.max'));
});

test('ticks must be aligned and positions single sided', () => {
  const f = form();
  f.pool.startingTick = -230_410;
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'pool.startingTick'));
  const g = form();
  g.rewards.positions[0].tickLower = -230_600; // below the start
  assert.ok(validateLaunch(g, ctx()).some((i) => i.field === 'positions.0'));
});

test('invalid or mixed case addresses are rejected', () => {
  const f = form();
  f.token.admin = '0x41c3bd8a36f8fe9bb77900ca02400b32bb35a6a4'; // lowercase passes
  assert.equal(validateLaunch(f, ctx()).filter((i) => i.field === 'token.admin').length, 0);
  f.token.admin = '0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A5'; // bad checksum
  assert.ok(validateLaunch(f, ctx()).some((i) => i.field === 'token.admin'));
});
