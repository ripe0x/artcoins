import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeAbiParameters, encodeErrorResult, encodeEventTopics, getAddress } from 'viem';
import { keeper111Abi, keeperLayerAbi, keeperV2Abi, reasonsAbi } from '../abi.mjs';
import { decodeKeeperLogs, decodeReason, describeError, servicedFrom, revertDataOf } from '../events.mjs';
import { argsV2 } from '../decide.mjs';

const K = '0x1111111111111111111111111111111111111111';
const OTHER = '0x9999999999999999999999999999999999999999';
const reason = (errorName, args) => encodeErrorResult({ abi: reasonsAbi, errorName, args });
const log = (abi, eventName, args, data, address = K) => ({
  address, topics: encodeEventTopics({ abi, eventName, args }), data, blockNumber: 1n, logIndex: 0, transactionHash: '0x' + '00'.repeat(32),
});

test('111: ConvertSkipped and FlushSkipped decode their reasons; other contracts ignored', () => {
  const logs = [
    log(keeper111Abi, 'FlushSkipped', {}, encodeAbiParameters([{ type: 'bytes' }], [reason('NothingToFlush')])),
    log(keeper111Abi, 'ConvertSkipped', {}, encodeAbiParameters([{ type: 'bytes' }], [reason('ConvertTooEarly', [26130300n])])),
    log(keeper111Abi, 'ConvertSkipped', {}, encodeAbiParameters([{ type: 'bytes' }], [reason('NothingToConvert')]), OTHER),
    log(keeper111Abi, 'KeeperRun', { caller: OTHER }, encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }], [1n, 2n, 3n])),
  ];
  const d = decodeKeeperLogs(logs, '111', K);
  assert.equal(d.length, 3);
  assert.equal(d[0].event, 'FlushSkipped');
  assert.equal(d[0].reason, 'NothingToFlush()');
  assert.equal(d[1].reason, 'ConvertTooEarly(26130300)');
  assert.equal(d[2].event, 'KeeperRun');
  assert.equal(d[2].args.converted, 3n);
});

test('LAYER: StepSkipped with step, target and router reason', () => {
  const data = encodeAbiParameters([{ type: 'bytes' }], [reason('SlippageFloorNotSet')]);
  const d = decodeKeeperLogs([log(keeperLayerAbi, 'StepSkipped', { step: 5, target: OTHER }, data)], 'layer', K);
  assert.equal(d[0].event, 'StepSkipped');
  assert.equal(d[0].step, '5: processBurnWeth');
  assert.equal(d[0].reason, 'SlippageFloorNotSet()');
  assert.equal(getAddress(d[0].args.target), OTHER);
  const v4 = encodeAbiParameters([{ type: 'bytes' }], [reason('V4TooLittleReceived', [5n, 4n])]);
  assert.equal(decodeKeeperLogs([log(keeperLayerAbi, 'StepSkipped', { step: 5, target: OTHER }, v4)], 'layer', K)[0].reason, 'V4TooLittleReceived(5, 4)');
});

test('v2: FlushSkipped and SwapperServiced, quote from the serviced events', () => {
  const tok = '0x4444444444444444444444444444444444444444';
  const logs = [
    log(keeperV2Abi, 'FlushSkipped', { token: tok, swapper: OTHER }, encodeAbiParameters([{ type: 'bytes' }], [reason('NothingToFlush')])),
    log(keeperV2Abi, 'SwapperServiced', { token: tok, swapper: OTHER }, encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }], [0n, 5_000_000n])),
  ];
  const d = decodeKeeperLogs(logs, 'v2', K);
  assert.equal(d[0].reason, 'NothingToFlush()');
  const s = servicedFrom(d);
  assert.deepEqual(s.map((x) => x.converted), [5_000_000n]);
  // KR-03: the swapper's own floor from a market read (price 1, no fees) sits under the simulated output
  const market = { swappers: [{ address: s[0].swapper, accruedCoin: 5_000_000n, maxStepIn: 10n ** 30n, sqrtPriceX96: 1n << 96n, lpFeePpm: 0, skimPpm: 0 }] };
  assert.deepEqual(argsV2(tok, s, 100, market).args, [tok, true, 4_950_000n]);
  assert.deepEqual(argsV2(tok, s, 100, null).args, [tok, false, 0n]); // no independent floor, no convert
});

test('InsufficientGas and unknown and empty reverts', () => {
  const ig = encodeErrorResult({ abi: keeper111Abi, errorName: 'InsufficientGas', args: [3] });
  assert.equal(describeError(decodeReason(ig, '111'), '111'), 'InsufficientGas(3: convert)');
  const igl = encodeErrorResult({ abi: keeperLayerAbi, errorName: 'InsufficientGas', args: [5] });
  assert.equal(describeError(decodeReason(igl, 'layer'), 'layer'), 'InsufficientGas(5: processBurnWeth)');
  assert.equal(describeError(decodeReason('0xdeadbeef', '111'), '111'), 'unknown revert 0xdeadbeef');
  assert.match(describeError(decodeReason('0x', '111'), '111'), /empty revert/);
  const str = encodeErrorResult({ abi: [{ type: 'error', name: 'Error', inputs: [{ type: 'string', name: 'm' }] }], errorName: 'Error', args: ['eth forward failed'] });
  assert.equal(describeError(decodeReason(str, '111'), '111'), 'Error(eth forward failed)');
});

test('revertDataOf walks the viem error chain', () => {
  const inner = { data: '0x969aeb08' + '0'.repeat(62) + '01' };
  assert.equal(revertDataOf({ message: 'x', cause: { cause: inner } }), inner.data);
  assert.equal(revertDataOf({ cause: { data: { errorName: 'X' }, raw: '0x12345678' } }), '0x12345678');
  assert.equal(revertDataOf({ message: 'no data' }), null);
});
