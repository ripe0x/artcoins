import test from 'node:test';
import assert from 'node:assert/strict';
import type { Address } from 'viem';
import { deriveRewardRows, recipientEditState, validateRecipient } from '../src/lib/recipients';

const A = (n: number) => `0x${n.toString(16).padStart(40, '0')}` as Address;
const f = { coin: A(1), hook: A(2), locker: A(3), escrow: A(4), poolManager: A(5) };

test('validateRecipient: accepts a plain address', () => {
  const r = validateRecipient(A(0x99), f);
  assert.equal(r.ok, true);
});

test('validateRecipient: rejects empty, malformed, zero and the stack contracts', () => {
  assert.equal(validateRecipient('', f).ok, false);
  assert.equal(validateRecipient('0x123', f).ok, false);
  assert.equal(validateRecipient(A(0), f).ok, false);
  for (const n of [1, 2, 3, 4, 5]) assert.equal(validateRecipient(A(n), f).ok, false, String(n));
});

test('validateRecipient: a zero escrow in the context does not reject the zero-adjacent address', () => {
  const r = validateRecipient(A(0x99), { ...f, escrow: A(0) });
  assert.equal(r.ok, true);
});

test('deriveRewardRows: marks the last row as protocol slot when it pays the protocol recipient', () => {
  const rows = deriveRewardRows([8000, 2000], [A(10), A(11)], A(11));
  assert.deepEqual(rows.map((r) => r.protocolSlot), [false, true]);
  assert.equal(rows[0].bps, 8000);
});

test('deriveRewardRows: no protocol slot when the last row pays someone else or none is known', () => {
  assert.equal(deriveRewardRows([10000], [A(10)], A(11))[0].protocolSlot, false);
  assert.equal(deriveRewardRows([10000], [A(10)], undefined)[0].protocolSlot, false);
  assert.deepEqual(deriveRewardRows([], [], A(11)), []);
});

test('recipientEditState', () => {
  assert.equal(recipientEditState(true, undefined), 'unknown');
  assert.equal(recipientEditState(true, true), 'locked');
  assert.equal(recipientEditState(false, false), 'not-admin');
  assert.equal(recipientEditState(true, false), 'editable');
});
