import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decodeAbiParameters, hexToBigInt, size, slice, type Address, type Hex } from 'viem';
import { encodeAttributionHookData, encodeSwapHookData } from '../src/lib/attribution';

const USER: Address = '0x1111111111111111111111111111111111111111';
const REF: Address = '0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4';
const ZERO = '0x0000000000000000000000000000000000000000';

const POOL_SWAP_DATA = [
  {
    type: 'tuple',
    components: [
      { name: 'mevModuleSwapData', type: 'bytes' },
      { name: 'poolExtensionSwapData', type: 'bytes' },
    ],
  },
] as const;

/** port of HookCalldata.refundTo (src/v2/hooks/libraries/HookCalldata.sol), same bounds and layout checks */
function refundTo(d: Hex): Address | typeof ZERO {
  const n = size(d);
  const word = (i: number): bigint => hexToBigInt(slice(d, i, i + 32));
  if (n < 0x60) return ZERO;
  const t = Number(word(0));
  if (t > n - 0x40) return ZERO;
  const o = Number(word(t));
  if (o > n) return ZERO;
  const p = t + o;
  if (p > n - 0x40) return ZERO;
  if (word(p) !== 0x20n) return ZERO;
  const w = word(p + 0x20);
  if (w >> 160n !== 0n) return ZERO;
  return `0x${w.toString(16).padStart(40, '0')}` as Address;
}

/** port of the attribution part of HookCalldata.decode: the referrer inside poolExtensionSwapData */
function referrerOf(d: Hex): string {
  const [outer] = decodeAbiParameters(POOL_SWAP_DATA, d);
  const ext = outer.poolExtensionSwapData;
  if (size(ext) < 0xa0) return ZERO;
  const t2 = Number(hexToBigInt(slice(ext, 0, 32)));
  return `0x${hexToBigInt(slice(ext, t2 + 0x20, t2 + 0x40)).toString(16).padStart(40, '0')}`;
}

test('v2 swap hookData names the connected wallet as refund address (D58, V2H-03)', () => {
  const d = encodeSwapHookData({ refundTo: USER });
  assert.equal(refundTo(d).toLowerCase(), USER);
  const [outer] = decodeAbiParameters(POOL_SWAP_DATA, d);
  // mevModuleSwapData is exactly abi.encode(address): 32 bytes, high bits clean
  assert.equal(size(outer.mevModuleSwapData), 32);
  assert.equal(outer.poolExtensionSwapData, '0x');
  assert.equal(referrerOf(d), ZERO);
});

test('refund address and referral attribution travel together, attribution layout unchanged', () => {
  const d = encodeSwapHookData({ refundTo: USER, referrer: REF });
  assert.equal(refundTo(d).toLowerCase(), USER);
  assert.equal(referrerOf(d).toLowerCase(), REF.toLowerCase());
  // the extension part is byte for byte what the attribution only encoder produced
  const [withRefund] = decodeAbiParameters(POOL_SWAP_DATA, d);
  const [attrOnly] = decodeAbiParameters(POOL_SWAP_DATA, encodeAttributionHookData({ referrer: REF }));
  assert.equal(withRefund.poolExtensionSwapData, attrOnly.poolExtensionSwapData);
  assert.equal(attrOnly.mevModuleSwapData, '0x');
  assert.equal(refundTo(encodeAttributionHookData({ referrer: REF })), ZERO);
});

test('no refund address and no attribution is plain 0x, a zero or invalid refund address is never encoded', () => {
  assert.equal(encodeSwapHookData({}), '0x');
  assert.equal(encodeSwapHookData({ refundTo: ZERO }), '0x');
  assert.equal(encodeSwapHookData({ refundTo: 'nope' as Address }), '0x');
  const d = encodeSwapHookData({ referrer: REF });
  assert.equal(refundTo(d), ZERO);
  assert.equal(referrerOf(d).toLowerCase(), REF.toLowerCase());
});

test('refund address is checksum insensitive and lands lowercase-equal in the encoding', () => {
  const d = encodeSwapHookData({ refundTo: REF.toLowerCase() as Address });
  assert.equal(refundTo(d).toLowerCase(), REF.toLowerCase());
});
