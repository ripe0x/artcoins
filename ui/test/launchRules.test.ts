import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { decodeFunctionData, encodeFunctionData, toFunctionSelector, getAbiItem, type Address, type Hex } from 'viem';
import { escrowV2Abi } from '../src/lib/abi/v2/escrow';
import { factoryV2Abi } from '../src/lib/abi/v2/factory';
import * as C from '../src/lib/constants';
import { buildLaunchConfigV2, percentToBps, percentToSkim, validateLaunch, type LaunchContext } from '../src/lib/encodeV2';
import { escrowClaimBlock, escrowClaimCall } from '../src/lib/escrowClaim';
import {
  classifyExempt,
  EXEMPT_NOT_ALLOWED,
  maxReferralCapSkim,
  referralCapWithinFloor,
  STRING_CAPS,
  stringCapIssue,
  utf8ByteLength,
} from '../src/lib/launchRules';
import { defaultLaunchForm } from '../src/lib/launchForm';
import type { LaunchForm } from '../src/lib/types';

const BPS = 10_000;
const LOCKER: Address = '0x3333333333333333333333333333333333333333';
const HOOK: Address = '0x2222222222222222222222222222222222222222';
const ctx = (over: Partial<LaunchContext> = {}): LaunchContext => ({
  sender: '0x1111111111111111111111111111111111111111',
  hook: HOOK,
  locker: LOCKER,
  mevModule: '0x4444444444444444444444444444444444444444',
  vault: '0x5555555555555555555555555555555555555555',
  airdrop: '0x6666666666666666666666666666666666666666',
  devBuy: '0x7777777777777777777777777777777777777777',
  protocolBps: 2000,
  minProtocolSkimShareBps: 1000, // what the deploy script sets (D52)
  minLpFee: 3000, // DEFAULT_MIN_LP_FEE (D53)
  exemptStatus: null,
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
const errorsOf = (f: LaunchForm, c: LaunchContext, field: string) =>
  validateLaunch(f, c).filter((i) => i.severity === 'error' && (i.field === field || i.field.startsWith(`${field}.`)));

// ── drift guards against the solidity sources ───────────────────────────────────────────────────

test('string caps equal ArtCoinsTokenV2.MAX_*_BYTES in the contract source', (t) => {
  const src = new URL('../../src/v2/ArtCoinsTokenV2.sol', import.meta.url);
  if (!existsSync(src)) return t.skip('contract source not found');
  const text = readFileSync(src, 'utf8');
  const read = (n: string) => Number(new RegExp(`uint256 public constant ${n} = (\\d+);`).exec(text)?.[1]);
  assert.equal(STRING_CAPS.name, read('MAX_NAME_BYTES'));
  assert.equal(STRING_CAPS.symbol, read('MAX_SYMBOL_BYTES'));
  assert.equal(STRING_CAPS.image, read('MAX_IMAGE_BYTES'));
  assert.equal(STRING_CAPS.metadata, read('MAX_METADATA_BYTES'));
  assert.equal(STRING_CAPS.context, read('MAX_CONTEXT_BYTES'));
  assert.deepEqual(STRING_CAPS, { name: 64, symbol: 16, image: 2048, metadata: 4096, context: 4096 });
});

test('fee constants the rules use equal src/Constants.sol', (t) => {
  const src = new URL('../../src/Constants.sol', import.meta.url);
  if (!existsSync(src)) return t.skip('Constants.sol not found');
  const text = readFileSync(src, 'utf8');
  const read = (n: string) => Number(new RegExp(`constant ${n} = ([\\d_]+);`).exec(text)?.[1].replaceAll('_', ''));
  assert.equal(C.BPS, read('BPS'));
  assert.equal(C.MAX_REFERRAL_CAP_OF_VOLUME, read('MAX_REFERRAL_CAP_OF_VOLUME'));
  assert.equal(C.MAX_BASELINE_SKIM_BPS, read('MAX_BASELINE_SKIM_BPS'));
  assert.equal(C.MAX_LP_FEE, read('MAX_LP_FEE'));
  assert.equal(C.MAX_BOUNTY_BPS, read('MAX_BOUNTY_BPS'));
});

// ── utf8 byte caps ──────────────────────────────────────────────────────────────────────────────

test('utf8ByteLength counts bytes, not characters', () => {
  assert.equal(utf8ByteLength(''), 0);
  assert.equal(utf8ByteLength('abc'), 3);
  assert.equal(utf8ByteLength('é'), 2);
  assert.equal(utf8ByteLength('日'), 3);
  assert.equal(utf8ByteLength('😀'), 4); // 2 utf16 units, 1 code point, 4 bytes
  assert.equal('😀'.length, 2);
  assert.equal(utf8ByteLength('é'), 3); // combining accent, 2 chars
});

test('name cap is 64 bytes: 64 ascii pass, 65 fail, 32 two byte chars pass, 33 fail', () => {
  assert.equal(stringCapIssue('name', 'a'.repeat(64)), null);
  assert.match(stringCapIssue('name', 'a'.repeat(65)) ?? '', /65 bytes, the cap is 64/);
  assert.equal(stringCapIssue('name', 'é'.repeat(32)), null);
  assert.notEqual(stringCapIssue('name', 'é'.repeat(33)), null);
  // 22 chars of 3 bytes = 66 bytes: short in characters, over in bytes
  assert.equal('日'.repeat(22).length, 22);
  assert.notEqual(stringCapIssue('name', '日'.repeat(22)), null);
  assert.equal(stringCapIssue('name', '日'.repeat(21)), null);
});

test('every field cap boundary: at the cap passes, one byte over fails', () => {
  for (const f of ['name', 'symbol', 'image', 'metadata', 'context'] as const) {
    const cap = STRING_CAPS[f];
    assert.equal(stringCapIssue(f, 'x'.repeat(cap)), null, `${f} at cap`);
    assert.notEqual(stringCapIssue(f, 'x'.repeat(cap + 1)), null, `${f} over cap`);
  }
  // emoji symbol: 4 emoji = 16 bytes passes, 5 = 20 fails, though 5 is far below 16 characters
  assert.equal(stringCapIssue('symbol', '😀'.repeat(4)), null);
  assert.notEqual(stringCapIssue('symbol', '😀'.repeat(5)), null);
});

test('validateLaunch rejects each over cap string with its own field', () => {
  const f = form();
  f.token.name = '日'.repeat(22);
  f.token.symbol = '😀'.repeat(5);
  f.token.image = `https://x.test/${'a'.repeat(2048)}`;
  f.token.metadata = 'm'.repeat(4097);
  f.token.context = 'c'.repeat(4097);
  const c = ctx();
  for (const field of ['name', 'symbol', 'image', 'metadata', 'context']) {
    assert.equal(errorsOf(f, c, `token.${field}`).length, 1, field);
  }
  assert.throws(() => buildLaunchConfigV2(f, c));
  // the builder trims name, symbol and image, so trailing spaces do not count against the cap
  const g = form();
  g.token.name = `${'a'.repeat(64)}   `;
  assert.equal(errorsOf(g, c, 'token.name').length, 0);
});

// ── referral cap ────────────────────────────────────────────────────────────────────────────────

/** the solidity expression with bigint, no helper: cap * BPS <= baseline * (BPS - bounty - minShare) */
const solidityOk = (cap: number, baseline: number, bounty: number, min: number): boolean => {
  const room = BigInt(BPS) - BigInt(bounty) - BigInt(min);
  if (room < 0n) return false;
  return BigInt(cap) * BigInt(BPS) <= BigInt(baseline) * room;
};

test('referral cap maximum: worked values', () => {
  // live coin 111 style fees, protocol floor 10% of the skim: 6000 * (10000 - 8333 - 1000) / 10000 = 400.2
  assert.equal(maxReferralCapSkim(6000, 8333, 1000), 400);
  // floor 16.67%: 6000 * 1667 / 10000 = 1000.2 -> wait that is room 1667 - 0, bounty 8333 leaves 0
  assert.equal(maxReferralCapSkim(6000, 8333, 1667), 0);
  // no bounty, no floor: room is the whole skim, 6000 * 10000 / 10000 = 6000, clamped to the 1% ceiling
  assert.equal(maxReferralCapSkim(6000, 0, 0), C.MAX_REFERRAL_CAP_OF_VOLUME);
  // half the skim to the bounty, 10% floor: 10000 * 4000 / 10000 = 4000 -> clamp 1000
  assert.equal(maxReferralCapSkim(10_000, 5000, 1000), 1000);
  // 2% baseline, 50% bounty, 10% floor: 2000 * 4000 / 10000 = 800
  assert.equal(maxReferralCapSkim(2000, 5000, 1000), 800);
  // no baseline skim, nothing to carve a referral from
  assert.equal(maxReferralCapSkim(0, 0, 0), 0);
  // bounty past the floor: no room, never negative
  assert.equal(maxReferralCapSkim(6000, 9500, 1000), 0);
});

test('referral cap maximum is tight: the max passes the factory expression, one more fails (unless clamped)', () => {
  let checked = 0;
  for (const baseline of [0, 1, 500, 2500, 6000, 9999, 10_000]) {
    for (const bounty of [0, 1, 2500, 5000, 8333, 8999, 9000, 9999]) {
      for (const min of [0, 1000, 1667, 5000]) {
        const max = maxReferralCapSkim(baseline, bounty, min);
        const ok = solidityOk(max, baseline, bounty, min);
        assert.equal(referralCapWithinFloor(max, baseline, bounty, min), ok);
        if (BPS - bounty - min >= 0) assert.ok(ok, `max ${max} must pass for ${baseline}/${bounty}/${min}`);
        if (max < C.MAX_REFERRAL_CAP_OF_VOLUME) {
          assert.equal(solidityOk(max + 1, baseline, bounty, min), false, `max+1 must fail for ${baseline}/${bounty}/${min}`);
          assert.equal(referralCapWithinFloor(max + 1, baseline, bounty, min), false);
        }
        checked++;
      }
    }
  }
  assert.ok(checked > 200);
});

test('referralCapWithinFloor equals the solidity expression on a grid, including negative room', () => {
  for (const cap of [0, 1, 250, 400, 401, 1000]) {
    for (const baseline of [0, 1000, 6000, 10_000]) {
      for (const bounty of [0, 5000, 8333, 9000, 9999]) {
        for (const min of [0, 1000, 1667, 3000]) {
          assert.equal(referralCapWithinFloor(cap, baseline, bounty, min), solidityOk(cap, baseline, bounty, min));
        }
      }
    }
  }
});

test('validateLaunch: referral cap above the maximum is an error, at the maximum it is not', () => {
  const c = ctx();
  const f = form(); // baseline 6%, bounty 83.33%, cap 0.25%
  assert.equal(errorsOf(f, c, 'pool.referralCap').length, 0);
  f.pool.referralCapPercent = 0.4; // 400, the maximum for 6000 / 8333 / 1000
  assert.equal(errorsOf(f, c, 'pool.referralCap').length, 0);
  f.pool.referralCapPercent = 0.401; // 401
  const errs = errorsOf(f, c, 'pool.referralCap');
  assert.equal(errs.length, 1);
  assert.match(errs[0].message, /maximum of 0\.4% of volume/);
  assert.throws(() => buildLaunchConfigV2(f, c));
  // a higher protocol floor lowers the maximum for the same form: bounty 8333 + floor 1667 leaves no room
  const g = form();
  g.pool.bountyPercent = 80;
  g.pool.referralCapPercent = 0.4; // room at floor 1000 = 1000, 6000 * 1000 / 10000 = 600, ok
  assert.equal(errorsOf(g, ctx({ minProtocolSkimShareBps: 1000 }), 'pool.referralCap').length, 0);
  assert.equal(errorsOf(g, ctx({ minProtocolSkimShareBps: 1900 }), 'pool.referralCap').length, 1); // room 100 -> 60
});

test('built config always satisfies the factory referral expression at the maximum', () => {
  const f = form();
  f.pool.referralCapPercent = maxReferralCapSkim(percentToSkim(f.pool.baselineSkimPercent), percentToBps(f.pool.bountyPercent), 1000) / 1000;
  const built = buildLaunchConfigV2(f, ctx());
  const { baselineSkimBps, bountyBps, maxReferralBpsOfVolume } = built.config.fee;
  assert.ok(solidityOk(maxReferralBpsOfVolume, baselineSkimBps, bountyBps, 1000));
});

// ── lp fee minimum ──────────────────────────────────────────────────────────────────────────────

test('validateLaunch: lp fee below the factory minimum is an error, at the minimum it is not', () => {
  const f = form();
  f.pool.lpFeePercent = 0.3; // 3000 pips = minLpFee
  assert.equal(errorsOf(f, ctx(), 'pool.lpFee').length, 0);
  f.pool.lpFeePercent = 0.29;
  assert.equal(errorsOf(f, ctx(), 'pool.lpFee').length, 1);
  f.pool.lpFeePercent = 0.5;
  assert.equal(errorsOf(f, ctx({ minLpFee: 6000 }), 'pool.lpFee').length, 1);
  assert.equal(errorsOf(f, ctx({ minLpFee: 5000 }), 'pool.lpFee').length, 0);
  assert.equal(errorsOf(f, ctx({ minLpFee: 0 }), 'pool.lpFee').length, 0);
});

// ── exempt allowlist ────────────────────────────────────────────────────────────────────────────

const EX1 = '0x00000000000000000000000000000000000000a1';
const EX2 = '0x00000000000000000000000000000000000000a2';
const venueForm = (exempt: string): LaunchForm => {
  const f = form();
  f.tax = { mode: 1, taxPercent: 5, maxPercent: 10, sink: 'dead', venueAdmin: '', exempt };
  return f;
};

test('classifyExempt mirrors the factory: allowlist, enabled escrow or extension, this launch locker or hook', () => {
  const none = { exemptAllowed: false, enabledEscrow: false, enabledExtension: false };
  assert.equal(classifyExempt(none, EX1, LOCKER, HOOK), 'not-allowed');
  assert.equal(classifyExempt({ ...none, exemptAllowed: true }, EX1, LOCKER, HOOK), 'allowed');
  assert.equal(classifyExempt({ ...none, enabledEscrow: true }, EX1, LOCKER, HOOK), 'allowed');
  assert.equal(classifyExempt({ ...none, enabledExtension: true }, EX1, LOCKER, HOOK), 'allowed');
  assert.equal(classifyExempt(none, LOCKER.toUpperCase().replace('0X', '0x'), LOCKER, HOOK), 'allowed');
  assert.equal(classifyExempt(none, HOOK, LOCKER, HOOK), 'allowed');
  // a failed read is never reported as allowed or as refused
  assert.equal(classifyExempt({ exemptAllowed: false, enabledEscrow: undefined, enabledExtension: false }, EX1, LOCKER, HOOK), 'unknown');
  assert.equal(classifyExempt({ exemptAllowed: undefined, enabledEscrow: undefined, enabledExtension: undefined }, EX1, LOCKER, HOOK), 'unknown');
});

test('validateLaunch: exempt entries must be allowlisted by the launcher owner', () => {
  const f = venueForm(`${EX1}, ${EX2}`);
  const c = ctx({ exemptStatus: { [EX1]: 'allowed', [EX2]: 'not-allowed' } });
  const errs = errorsOf(f, c, 'tax.exempt');
  assert.equal(errs.length, 1);
  assert.ok(errs[0].message.includes(EX2));
  assert.ok(errs[0].message.includes(EXEMPT_NOT_ALLOWED));
  assert.equal(EXEMPT_NOT_ALLOWED, 'not allowed by the launcher owner');
  assert.throws(() => buildLaunchConfigV2(f, c));
  // all allowed: builds, entries go out in order
  const ok = ctx({ exemptStatus: { [EX1]: 'allowed', [EX2]: 'allowed' } });
  assert.deepEqual(buildLaunchConfigV2(f, ok).config.tax.exempt.map((a) => a.toLowerCase()), [EX1, EX2]);
});

test('validateLaunch: an unchecked exempt entry blocks, no factory means no check, duplicates fail', () => {
  const f = venueForm(EX1);
  assert.equal(errorsOf(f, ctx({ exemptStatus: {} }), 'tax.exempt').length, 1); // not read yet
  assert.equal(errorsOf(f, ctx({ exemptStatus: { [EX1]: 'unknown' } }), 'tax.exempt').length, 1);
  assert.equal(errorsOf(f, ctx({ exemptStatus: null }), 'tax.exempt').length, 0); // preview, nothing can be sent
  const d = venueForm(`${EX1} ${EX1.toUpperCase().replace('0X', '0x')}`);
  assert.ok(errorsOf(d, ctx({ exemptStatus: { [EX1]: 'allowed' } }), 'tax.exempt').some((e) => /twice/.test(e.message)));
  // no tax mode: the allowlist is never consulted
  assert.equal(errorsOf(form(), ctx({ exemptStatus: {} }), 'tax').length, 0);
});

// ── escrow claim (D57) ──────────────────────────────────────────────────────────────────────────

const ESCROW: Address = '0x7559689765aE86cBB38e68CD1294830CccB125F2';
const REFERRER: Address = '0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4';

test('escrow claim call is claim(referrer, address(0)) with the foundry selector', (t) => {
  const call = escrowClaimCall(ESCROW, REFERRER);
  assert.equal(call.address, ESCROW);
  assert.deepEqual(call.args, [REFERRER, C.ZERO_ADDRESS]);
  const data = encodeFunctionData({ abi: call.abi, functionName: 'claim', args: [REFERRER, C.ZERO_ADDRESS] });
  const back = decodeFunctionData({ abi: escrowV2Abi, data });
  assert.equal(back.functionName, 'claim');
  assert.equal((back.args as readonly string[])[1], C.ZERO_ADDRESS);
  const item = getAbiItem({ abi: escrowV2Abi, name: 'claim' });
  const art = new URL('../../foundry-out/ArtCoinsFeeEscrowV2.sol/ArtCoinsFeeEscrowV2.json', import.meta.url);
  if (!existsSync(art)) return t.skip('foundry-out artifact not built');
  const ids = JSON.parse(readFileSync(art, 'utf8')).methodIdentifiers as Record<string, string>;
  assert.equal(toFunctionSelector(item).slice(2), ids['claim(address,address)']);
});

test('escrow claim blocks: nothing to claim, and self claim only for a stranger', () => {
  const stranger: Address = '0x1111111111111111111111111111111111111111';
  assert.match(escrowClaimBlock({ balance: 0n, selfClaimOnly: false, caller: stranger, referrer: REFERRER }) ?? '', /No referral earnings/);
  assert.equal(escrowClaimBlock({ balance: 5n, selfClaimOnly: false, caller: stranger, referrer: REFERRER }), null);
  assert.match(escrowClaimBlock({ balance: 5n, selfClaimOnly: true, caller: stranger, referrer: REFERRER }) ?? '', /self claim only/);
  assert.equal(escrowClaimBlock({ balance: 5n, selfClaimOnly: true, caller: REFERRER.toLowerCase() as Address, referrer: REFERRER }), null);
});

test('factory abi carries the additive reads the form uses', () => {
  for (const name of ['minLpFee', 'minProtocolSkimShareBps', 'exemptAllowed', 'enabledEscrows', 'enabledExtensions', 'owner']) {
    assert.ok(getAbiItem({ abi: factoryV2Abi, name }), name);
  }
  for (const name of ['ExemptNotAllowed', 'ReferralCapAboveProtocolFloor', 'LpFeeBelowMinimum', 'StringTooLong']) {
    assert.ok(getAbiItem({ abi: factoryV2Abi, name }), name);
  }
});
