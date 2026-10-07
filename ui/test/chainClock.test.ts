import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  CHAIN_DEADLINE_MARGIN_SEC,
  estimateChainNow,
  latestChainTimestamp,
  permit2Covers,
  permit2Expiration,
  sellApprovalSteps,
} from '../src/lib/chainClock.ts';

test('estimateChainNow: the chain timestamp wins over a skewed browser clock', () => {
  // browser is 9 hours ahead of the chain, 5 seconds after the block was read
  const browserMs = (1_000_000 + 9 * 3600) * 1000 + 5_000;
  const fetchedMs = (1_000_000 + 9 * 3600) * 1000;
  assert.equal(estimateChainNow(1_000_000n, fetchedMs, browserMs), 1_000_005);
});

test('estimateChainNow: falls back to the browser clock without a block, never goes backwards', () => {
  assert.equal(estimateChainNow(undefined, undefined, 1_700_000_123_456), 1_700_000_123);
  assert.equal(estimateChainNow(500, 10_000, 5_000), 500);
});

test('latestChainTimestamp: reads the block, falls back to the browser clock on an rpc error', async () => {
  assert.equal(await latestChainTimestamp({ getBlock: async () => ({ timestamp: 1234n }) }), 1234);
  const fb = await latestChainTimestamp({ getBlock: async () => { throw new Error('rpc down'); } });
  assert.ok(Math.abs(fb - Math.floor(Date.now() / 1000)) < 5);
});

test('permit2Covers: needs the amount and an expiry past the deadline plus the margin', () => {
  const base = { amount: 10n, need: 10n, chainNow: 1000, deadlineMin: 5 };
  assert.equal(permit2Covers({ ...base, expiration: 1000 + 300 + CHAIN_DEADLINE_MARGIN_SEC }), true);
  assert.equal(permit2Covers({ ...base, expiration: 1000 + 300 + CHAIN_DEADLINE_MARGIN_SEC - 1 }), false);
  assert.equal(permit2Covers({ ...base, amount: 9n, expiration: 99999 }), false);
  assert.equal(permit2Covers({ ...base, expiration: 0 }), false);
});

test('permit2Expiration: chain now plus the deadline plus 5 minutes', () => {
  assert.equal(permit2Expiration(1000, 5), 1000 + 600);
  // a deadline-sized approval always clears its own check
  assert.equal(permit2Covers({ amount: 1n, need: 1n, chainNow: 1000, deadlineMin: 30, expiration: permit2Expiration(1000, 30) }), true);
});

const sell = { direction: 'sell' as const, erc20ToPermit2: 0n, permit2Amount: 0n, permit2Expiration: 0, chainNow: 1000, deadlineMin: 5 };

test('sellApprovalSteps: above the balance no approval is offered (UI-E2E-02)', () => {
  const r = sellApprovalSteps({ ...sell, amountIn: 11n, balance: 10n });
  assert.deepEqual(r, { needsErc20Approval: false, needsPermit2Approval: false });
  // also with the erc20 allowance missing
  assert.equal(sellApprovalSteps({ ...sell, amountIn: 11n, balance: 10n, erc20ToPermit2: 0n }).needsErc20Approval, false);
});

test('sellApprovalSteps: within the balance the steps come in order', () => {
  assert.deepEqual(sellApprovalSteps({ ...sell, amountIn: 10n, balance: 10n }), { needsErc20Approval: true, needsPermit2Approval: false });
  assert.deepEqual(sellApprovalSteps({ ...sell, amountIn: 10n, balance: 10n, erc20ToPermit2: 10n }), { needsErc20Approval: false, needsPermit2Approval: true });
  assert.deepEqual(
    sellApprovalSteps({ ...sell, amountIn: 10n, balance: 10n, erc20ToPermit2: 10n, permit2Amount: 10n, permit2Expiration: 5000 }),
    { needsErc20Approval: false, needsPermit2Approval: false }
  );
});

test('sellApprovalSteps: an approval that expires on the chain clock is renewed, whatever the browser says', () => {
  // chain now 1000, approval expires at 1100: inside deadline (300s) plus margin, so it is renewed
  const r = sellApprovalSteps({ ...sell, amountIn: 10n, balance: 10n, erc20ToPermit2: 10n, permit2Amount: 10n, permit2Expiration: 1100 });
  assert.equal(r.needsPermit2Approval, true);
});

test('sellApprovalSteps: buys never need approvals', () => {
  assert.deepEqual(sellApprovalSteps({ ...sell, direction: 'buy', amountIn: 5n, balance: 10n }), { needsErc20Approval: false, needsPermit2Approval: false });
});
