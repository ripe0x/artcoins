import { test } from 'node:test';
import assert from 'node:assert/strict';
import { getAddress, parseEther } from 'viem';
import { loadConfig, findContract, ConfigError, GAS_LIMIT } from '../config.mjs';
import { realRegistry, registryWithV2, baseEnv, tmpDir, TEST_KEY, K111, KLAYER, KV2, COIN_V2 } from './helpers.mjs';

// the owner eoa's key is not known here: emulate by making the test key's address the registry owner
const TEST_ADDR = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';

test('defaults: fixed gas limits, slippage 100 / 200, thresholds, rpc fallback, no v2 stack', () => {
  const cfg = loadConfig(baseEnv(tmpDir()), realRegistry());
  assert.equal(cfg.rpcUrl, 'https://mainnet.gateway.tenderly.co');
  assert.deepEqual(cfg.keepers.map((k) => [k.id, k.address, k.gas, k.slippageBps]), [
    ['111', K111, 1_200_000n, 100],
    ['layer', KLAYER, 3_500_000n, 200],
  ]);
  assert.equal(cfg.v2.live, false);
  assert.equal(cfg.maxGasWei, 30_000_000_000n);
  assert.equal(cfg.intervalSeconds, 600);
  assert.equal(cfg.thresholds['111'].uncollectedEth, parseEther('0.02'));
  assert.equal(cfg.thresholds['111'].uncollectedCoin, 10_000n * 10n ** 18n);
  assert.equal(cfg.thresholds['111'].escrowedEth, parseEther('0.05'));
  assert.equal(cfg.thresholds.layer.combinedWeth, parseEther('0.01'));
  assert.deepEqual([...cfg.privateKeepers], ['111']);
  assert.equal(GAS_LIMIT.v2, 2_000_000n);
});

test('env overrides thresholds and slippage, global and per keeper', () => {
  const cfg = loadConfig(baseEnv(tmpDir(), {
    K111_MIN_UNCOLLECTED_ETH: '0.5', KLAYER_MIN_COMBINED_WETH: '0.02', KEEPER_SLIPPAGE_BPS: '150', KEEPER_LAYER_SLIPPAGE_BPS: '300', MAX_GAS_GWEI: '12', INTERVAL_SECONDS: '60',
  }), realRegistry());
  assert.equal(cfg.thresholds['111'].uncollectedEth, parseEther('0.5'));
  assert.equal(cfg.thresholds.layer.combinedWeth, parseEther('0.02'));
  assert.deepEqual(cfg.keepers.map((k) => k.slippageBps), [150, 300]);
  assert.equal(cfg.maxGasWei, 12_000_000_000n);
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { KEEPER_SLIPPAGE_BPS: '1001' }), realRegistry()), ConfigError);
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { MAX_GAS_GWEI: 'lots' }), realRegistry()), ConfigError);
});

test('refuses the owner key', () => {
  const reg = realRegistry();
  reg.owner = TEST_ADDR;
  assert.throws(() => loadConfig(baseEnv(tmpDir()), reg), /owner key/);
  const reg2 = realRegistry();
  reg2.contracts[0].owner = TEST_ADDR; // any owner field in the registry counts
  assert.throws(() => loadConfig(baseEnv(tmpDir()), reg2), /owner key/);
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { KEEPER_PRIVATE_KEY: '' }), realRegistry()), /KEEPER_PRIVATE_KEY/);
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { KEEPER_PRIVATE_KEY: '0x1234' }), realRegistry()), /32 bytes/);
});

test('keeper addresses come from the registry when recorded, env overrides', () => {
  const reg = realRegistry();
  reg.contracts.push({ name: 'CollectFlushKeeperV1', address: '0x00000000000000000000000000000000000000aa', stack: 'current', role: 'keeper', status: 'current' });
  reg.contracts.push({ name: 'CollectFlushKeeperLayer', address: '0x00000000000000000000000000000000000000bb', stack: 'legacy', role: 'keeper', status: 'legacy' });
  const env = { KEEPER_PRIVATE_KEY: TEST_KEY, STATE_PATH: tmpDir() + '/s.json' };
  const cfg = loadConfig(env, reg);
  assert.deepEqual(cfg.keepers.map((k) => k.address), [getAddress('0x00000000000000000000000000000000000000aa'), getAddress('0x00000000000000000000000000000000000000bb')]);
  const over = loadConfig({ ...env, KEEPER_111: K111 }, reg);
  assert.equal(over.keepers[0].address, K111);
  // neither recorded nor set: address null (the runner logs no_address and skips it)
  assert.equal(loadConfig(env, realRegistry()).keepers[0].address, null);
  // two different live entries with the same name: refuse to guess
  reg.contracts.push({ name: 'CollectFlushKeeperV1', address: '0x00000000000000000000000000000000000000cc', stack: 'current', role: 'keeper', status: 'current' });
  assert.throws(() => findContract(reg, 'CollectFlushKeeperV1'), /2 live/);
});

test('v2: skipped without a deployed v2 stack, one keeper per v2 coin when present', () => {
  assert.equal(loadConfig(baseEnv(tmpDir()), registryWithV2({ status: 'planned' })).v2.live, false);
  const cfg = loadConfig(baseEnv(tmpDir()), registryWithV2());
  const v2 = cfg.keepers.filter((k) => k.kind === 'v2');
  assert.deepEqual(v2.map((k) => [k.id, k.address, k.token, k.gas, k.slippageBps]), [['v2:CRED', KV2, COIN_V2, 2_000_000n, 100]]);
  const only = loadConfig(baseEnv(tmpDir(), { KEEPERS: 'v2' }), registryWithV2());
  assert.deepEqual(only.keepers.map((k) => k.id), ['v2:CRED']);
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { KEEPERS: '111,foo' }), realRegistry()), /unknown keeper/);
});
