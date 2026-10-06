import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decodeAbiParameters, type Address, type Hex } from 'viem';
import {
  ACT_SETTLE_ALL,
  ACT_SWAP_EXACT_IN_SINGLE,
  ACT_TAKE,
  ACT_TAKE_ALL,
  ADDRESS_THIS,
  applySlippage,
  buildBuyCalldata,
  buildSellCalldata,
  classifyPool,
  CMD_UNWRAP_WETH,
  CMD_V4_SWAP,
  CMD_WRAP_ETH,
  priceImpactPercent,
} from '../src/lib/swap';

const COIN: Address = '0x61C9d89fe1212F6b55fF888816A151463287B8ae';
const WETH: Address = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
const HOOK: Address = '0x636c050296B5Cc528D8785169Bf8923716FCa9cc';
const ZERO: Address = '0x0000000000000000000000000000000000000000';
const nativeKey = { currency0: ZERO, currency1: COIN, fee: 0x800000, tickSpacing: 200, hooks: HOOK };
const wethKey = { currency0: COIN, currency1: WETH, fee: 0x800000, tickSpacing: 60, hooks: HOOK }; // coin sorts below weth here

const hex = (h: Hex) => (h.slice(2).match(/../g) ?? []).map((b) => parseInt(b, 16));
function actionsOf(input: Hex): { actions: number[]; params: Hex[] } {
  const [a, p] = decodeAbiParameters([{ type: 'bytes' }, { type: 'bytes[]' }], input);
  return { actions: hex(a as Hex), params: [...(p as readonly Hex[])] };
}

test('classifyPool', () => {
  assert.equal(classifyPool(nativeKey, COIN, WETH), 'native');
  assert.equal(classifyPool(wethKey, COIN, WETH), 'weth');
  assert.equal(classifyPool({ ...nativeKey, currency0: '0x0000000000000000000000000000000000000009' }, COIN, WETH), null);
});

test('native buy: one V4_SWAP, SETTLE_ALL then TAKE_ALL, value is the eth in, direction zeroForOne', () => {
  const b = buildBuyCalldata({ poolKey: nativeKey, token: COIN, weth: WETH, ethAmount: 10n ** 17n, minTokenOut: 5n });
  assert.deepEqual(hex(b.commands), [CMD_V4_SWAP]);
  assert.equal(b.value, 10n ** 17n);
  const { actions, params } = actionsOf(b.inputs[0]);
  assert.deepEqual(actions, [ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL]);
  const [settleCur, settleMax] = decodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], params[1]);
  assert.equal(settleCur, ZERO);
  assert.equal(settleMax, 10n ** 17n);
  const [takeCur, takeMin] = decodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], params[2]);
  assert.equal(takeCur, COIN);
  assert.equal(takeMin, 5n);
});

test('native sell (UI-06): no unwrap, the coin settles through the user and eth is taken to the user', () => {
  const s = buildSellCalldata({ poolKey: nativeKey, token: COIN, weth: WETH, tokenAmount: 10n ** 20n, minEthOut: 7n, recipient: COIN });
  assert.deepEqual(hex(s.commands), [CMD_V4_SWAP]);
  assert.equal(s.value, 0n);
  const { actions, params } = actionsOf(s.inputs[0]);
  assert.deepEqual(actions, [ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL]);
  const [settleCur] = decodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], params[1]);
  const [takeCur, takeMin] = decodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], params[2]);
  assert.equal(settleCur, COIN);
  assert.equal(takeCur, ZERO);
  assert.equal(takeMin, 7n);
});

test('weth sell (UI-06): TAKE to the router then UNWRAP_WETH, never TAKE_ALL before the unwrap', () => {
  const s = buildSellCalldata({ poolKey: wethKey, token: COIN, weth: WETH, tokenAmount: 10n ** 20n, minEthOut: 7n, recipient: HOOK });
  assert.deepEqual(hex(s.commands), [CMD_V4_SWAP, CMD_UNWRAP_WETH]);
  const { actions, params } = actionsOf(s.inputs[0]);
  assert.deepEqual(actions, [ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE]);
  assert.ok(!actions.includes(ACT_TAKE_ALL));
  const [cur, to, amount] = decodeAbiParameters([{ type: 'address' }, { type: 'address' }, { type: 'uint256' }], params[2]);
  assert.equal(cur, WETH);
  assert.equal(to, ADDRESS_THIS);
  assert.equal(amount, 0n); // OPEN_DELTA = the whole credit
  const [rcpt, min] = decodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], s.inputs[1]);
  assert.equal(rcpt, HOOK);
  assert.equal(min, 7n);
});

test('weth buy wraps first', () => {
  const b = buildBuyCalldata({ poolKey: wethKey, token: COIN, weth: WETH, ethAmount: 10n ** 17n, minTokenOut: 5n });
  assert.deepEqual(hex(b.commands), [CMD_WRAP_ETH, CMD_V4_SWAP]);
});

test('a zero or missing floor is refused (UI-14)', () => {
  assert.throws(() => buildBuyCalldata({ poolKey: nativeKey, token: COIN, weth: WETH, ethAmount: 1n, minTokenOut: 0n }));
  assert.throws(() => buildSellCalldata({ poolKey: nativeKey, token: COIN, weth: WETH, tokenAmount: 1n, minEthOut: 0n, recipient: COIN }));
});

test('slippage and price impact', () => {
  assert.equal(applySlippage(10_000n, 100), 9_900n);
  assert.throws(() => applySlippage(1n, 10_000));
  // mid 1000 coin per eth, buy 1 eth for 900 coin = 10% worse
  const buy = priceImpactPercent('buy', 10n ** 18n, 900n * 10n ** 18n, 1000);
  assert.ok(buy !== null && Math.abs(buy - 10) < 1e-9);
  // sell 1000 coin for 0.9 eth: executed 1111 coin per eth, 11.1% worse
  const sell = priceImpactPercent('sell', 1000n * 10n ** 18n, 9n * 10n ** 17n, 1000);
  assert.ok(sell !== null && Math.abs(sell - 11.111111) < 1e-4);
  assert.equal(priceImpactPercent('buy', 0n, 1n, 1000), null);
});
