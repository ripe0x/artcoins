// v2 quote path against a local anvil (no fork, no network): a stand in contract at the keeper address emits
// SwapperServiced like ArtCoinsKeeperV2.collectAndForward, the io quotes it through eth_simulateV1. A second
// stand in reverts InsufficientGas(3) for the v2, 111 and LAYER simulation paths. Skipped when anvil is not on PATH. No v2 stack exists on chain yet, so
// this is the only on node check of the v2 path.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import net from 'node:net';
import { toEventSelector, pad, toHex, concat, getAddress } from 'viem';
import { createIo, SimRevert } from '../chain.mjs';
import { loadConfig } from '../config.mjs';
import { argsV2 } from '../decide.mjs';
import { registryWithV2, baseEnv, tmpDir, KV2, COIN_V2 } from './helpers.mjs';

const has = (bin) => { try { execFileSync(bin, ['--version'], { stdio: 'ignore' }); return true; } catch { return false; } };
const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, () => { const p = s.address().port; s.close(() => res(p)); }); });
const SWAPPER = '0x6666666666666666666666666666666666666666';
const REVERTER = '0x7777777777777777777777777777777777777777';

// PUSH32 a, PUSH1 0, MSTORE, PUSH32 b, PUSH1 0x20, MSTORE, PUSH32 swapper, PUSH1 4, CALLDATALOAD (token),
// PUSH32 topic0, PUSH1 0x40, PUSH1 0, LOG3, STOP
const emitter = (flushed, converted) => concat([
  '0x7f', pad(toHex(flushed)), '0x600052', '0x7f', pad(toHex(converted)), '0x602052',
  '0x7f', pad(SWAPPER), '0x600435', '0x7f', toEventSelector('SwapperServiced(address,address,uint256,uint256)'), '0x60406000a300',
]);
// revert InsufficientGas(3): selector at 0, the uint8 word at 4, revert(0, 0x24)
const reverter = concat(['0x7f', pad('0x969aeb08', { dir: 'right' }), '0x600052', '0x6003600452', '0x60246000fd']);

test('v2 quote via eth_simulateV1: SwapperServiced decoded, reverts surface as SimRevert', { skip: has('anvil') ? false : 'anvil not on PATH', timeout: 60_000 }, async () => {
  const port = await freePort();
  const proc = spawn('anvil', ['--port', String(port), '--silent'], { stdio: 'ignore' });
  const url = `http://127.0.0.1:${port}`;
  const rpc = async (method, params) => {
    const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
    return (await r.json()).result;
  };
  try {
    for (let i = 0; i < 60 && !(await rpc('eth_chainId', []).catch(() => null)); i++) await new Promise((r) => setTimeout(r, 250));
    await rpc('anvil_setChainId', [1]);
    await rpc('anvil_setCode', [KV2, emitter(7n, 2_000_000n)]);
    await rpc('anvil_setCode', [REVERTER, reverter]);
    const cfg = loadConfig(baseEnv(tmpDir(), { MAINNET_RPC_URL: url, KEEPERS: 'v2' }), registryWithV2());
    const io = createIo(cfg);
    const k = cfg.keepers[0];
    assert.equal(k.address, KV2);
    const serviced = await io.simulateZero(k);
    assert.deepEqual(serviced.map((s) => [getAddress(s.swapper), s.flushed, s.converted]), [[getAddress(SWAPPER), 7n, 2_000_000n]]);
    const market = { swappers: [{ address: SWAPPER, accruedCoin: 2_000_000n, maxStepIn: 10n ** 30n, sqrtPriceX96: 1n << 96n, lpFeePpm: 0, skimPpm: 0 }] };
    assert.deepEqual(argsV2(COIN_V2, serviced, k.slippageBps, market).args, [COIN_V2, true, 1_980_000n]);
    await assert.rejects(io.simulateZero({ ...k, address: REVERTER }), (e) => e instanceof SimRevert && e.description === 'InsufficientGas(3: convert)');
    // the 111 and LAYER path (simulateContract) decodes the same way
    await assert.rejects(io.simulateZero({ ...k, kind: '111', address: REVERTER, gas: 1_200_000n }), (e) => e instanceof SimRevert && e.description === 'InsufficientGas(3: convert)');
    await assert.rejects(io.simulateZero({ ...k, kind: 'layer', address: REVERTER, gas: 3_500_000n }), (e) => e instanceof SimRevert && e.description === 'InsufficientGas(3: processFees)');
  } finally {
    proc.kill('SIGTERM');
  }
});
