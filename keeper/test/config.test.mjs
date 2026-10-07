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
  assert.equal(cfg.maxGasWei, 14_000_000_000n);
  assert.equal(cfg.intervalSeconds, 600);
  // KR-01 / KR-14 cadence: checks 111 hourly, LAYER daily, v2 hourly; runs at most every 6 h, 24 h, 6 h
  assert.deepEqual(cfg.keepers.map((k) => [k.id, k.checkIntervalSeconds, k.minRunIntervalSeconds]), [['111', 3600, 21600], ['layer', 86400, 86400]]);
  assert.equal(cfg.progressMinBps, 5000);
  assert.equal(cfg.maxImpactBps, 100);
  assert.deepEqual([cfg.pendingTimeoutSeconds, cfg.maxReplacements, cfg.backoffMinSeconds, cfg.backoffMaxSeconds], [1800, 3, 3600, 86400]);
  // KR-06: the funding need is the largest gas limit at the fee cap, and the low balance warning defaults to it
  assert.equal(cfg.requiredBalanceWei, 3_500_000n * 14_000_000_000n);
  assert.equal(cfg.lowBalanceWei, cfg.requiredBalanceWei);
  assert.ok(cfg.requiredBalanceWei <= cfg.highBalanceWei, 'the default cap fits under the 0.05 eth hot key limit');
  assert.equal(cfg.thresholds['111'].uncollectedEth, parseEther('0.02'));
  assert.equal(cfg.thresholds['111'].uncollectedCoin, 10_000n * 10n ** 18n);
  assert.equal(cfg.thresholds['111'].escrowedEth, parseEther('0.05'));
  assert.equal(cfg.thresholds.layer.combinedWeth, parseEther('0.01'));
  assert.deepEqual([...cfg.privateKeepers], ['111', 'layer', 'v2']);
  assert.equal(cfg.statusToken, null);
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

// the real registry without its keeper rows, for tests that record their own
function registryWithoutKeepers() {
  const reg = realRegistry();
  reg.contracts = reg.contracts.filter((c) => c.role !== 'keeper');
  return reg;
}

test('the recorded 111 keeper resolves from the real registry', () => {
  const env = { KEEPER_PRIVATE_KEY: TEST_KEY, STATE_PATH: tmpDir() + '/s.json', DRY_RUN: '1' };
  const k = loadConfig(env, realRegistry()).keepers.find((x) => x.id === '111');
  assert.equal(k.address, getAddress('0xa8fd2c8DB6A8EDfBa9eC2993b37F534e34D0B50E'));
});

test('keeper addresses come from the registry when recorded, env overrides', () => {
  const reg = registryWithoutKeepers();
  reg.contracts.push({ name: 'CollectFlushKeeperV1', address: '0x00000000000000000000000000000000000000aa', stack: 'current', role: 'keeper', status: 'current' });
  reg.contracts.push({ name: 'CollectFlushKeeperLayer', address: '0x00000000000000000000000000000000000000bb', stack: 'legacy', role: 'keeper', status: 'legacy' });
  const env = { KEEPER_PRIVATE_KEY: TEST_KEY, STATE_PATH: tmpDir() + '/s.json', DRY_RUN: '1' };
  const cfg = loadConfig(env, reg);
  assert.deepEqual(cfg.keepers.map((k) => k.address), [getAddress('0x00000000000000000000000000000000000000aa'), getAddress('0x00000000000000000000000000000000000000bb')]);
  const over = loadConfig({ ...env, KEEPER_111: K111 }, reg);
  assert.equal(over.keepers[0].address, K111);
  // neither recorded nor set: address null (the runner logs no_address and skips it)
  assert.equal(loadConfig(env, registryWithoutKeepers()).keepers[0].address, null);
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

// KR-07: anything but unset, empty, "0" or "false" is a dry run
test('KR-07 DRY_RUN fails closed: only unset, "", "0" and "false" are live', () => {
  for (const v of ['1', 'true', 'TRUE', 'True', 'yes', 'on', ' 1', 'no', 'live?']) {
    assert.equal(loadConfig(baseEnv(tmpDir(), { DRY_RUN: v }), realRegistry()).dryRun, true, v);
  }
  for (const v of [undefined, '', '0', 'false', ' FALSE ']) {
    assert.equal(loadConfig(baseEnv(tmpDir(), { DRY_RUN: v }), realRegistry()).dryRun, false, String(v));
  }
});

// KR-08: live 111 needs the private relay unless ALLOW_PUBLIC_MEMPOOL=1; PRIVATE_RPC_KEEPERS entries are validated
test('KR-08 111 live without PRIVATE_RPC_URL refuses to start unless ALLOW_PUBLIC_MEMPOOL=1', () => {
  const env = (x) => baseEnv(tmpDir(), { ALLOW_PUBLIC_MEMPOOL: '', ...x });
  assert.throws(() => loadConfig(env({}), realRegistry()), /PRIVATE_RPC_URL/);
  assert.throws(() => loadConfig(env({ PRIVATE_RPC_URL: 'https://rpc.flashbots.net/fast', PRIVATE_RPC_KEEPERS: 'layer' }), realRegistry()), /PRIVATE_RPC_URL/);
  assert.throws(() => loadConfig(env({ PRIVATE_RPC_URL: 'https://rpc.flashbots.net/fast', PRIVATE_RPC_KEEPERS: 'v2:CRED' }), realRegistry()), /unknown keeper/);
  const ok = loadConfig(env({ PRIVATE_RPC_URL: 'https://rpc.flashbots.net/fast' }), realRegistry());
  assert.deepEqual([...ok.privateKeepers], ['111', 'layer', 'v2']);
  assert.equal(loadConfig(env({ ALLOW_PUBLIC_MEMPOOL: '1' }), realRegistry()).allowPublicMempool, true);
  assert.equal(loadConfig(env({ DRY_RUN: '1' }), realRegistry()).dryRun, true); // dry run sends nothing
  assert.equal(loadConfig(env({ KEEPERS: 'layer' }), realRegistry()).keepers.length, 1); // no 111, no rule
});

// KR-09: the built in owner and payout eoas and OWNER_ADDRESS are refused even when the registry does not name them
test('KR-09 owner refusal also uses OWNER_ADDRESS and the built in list, not only the registry', () => {
  const reg = realRegistry();
  reg.owner = '0x0000000000000000000000000000000000000001';
  for (const c of reg.contracts) c.owner = null;
  assert.equal(loadConfig(baseEnv(tmpDir()), reg).account.address, TEST_ADDR);
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { OWNER_ADDRESS: TEST_ADDR }), reg), /owner key/);
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { OWNER_ADDRESS: 'nope' }), reg), /OWNER_ADDRESS/);
  const noOwner = realRegistry();
  delete noOwner.owner;
  assert.throws(() => loadConfig(baseEnv(tmpDir()), noOwner), /no owner field/);
});

// KR-13: an out of range key is refused without echoing it
test('KR-13 invalid key: fixed message, no key material', () => {
  const zero = '0x' + '0'.repeat(64);
  const bad = 'f'.repeat(64); // above the curve order
  for (const k of [zero, bad]) {
    try {
      loadConfig(baseEnv(tmpDir(), { KEEPER_PRIVATE_KEY: k }), realRegistry());
      assert.fail('accepted');
    } catch (e) {
      assert.ok(e instanceof ConfigError);
      assert.ok(!e.message.includes(k.replace(/^0x/, '')) && !/\d{20,}/.test(e.message), e.message);
    }
  }
  assert.throws(() => loadConfig(baseEnv(tmpDir(), { STATUS_TOKEN: 'short' }), realRegistry()), /STATUS_TOKEN/);
});
