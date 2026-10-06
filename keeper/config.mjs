// Runner configuration: addresses from the deployment registry (deployments/mainnet.json, copied into the
// image), rpc urls and the hot key from the environment, thresholds overridable by env. Pure: no network.
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { getAddress, isAddress, parseEther, parseUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const DEFAULT_RPC = 'https://mainnet.gateway.tenderly.co';
export const DEFAULT_REGISTRY = fileURLToPath(new URL('../deployments/mainnet.json', import.meta.url));

// fixed gas limits (RUNBOOK part 1 actions 3 and 2b, 2b keeper table). never estimated: the keepers revert
// `InsufficientGas` on a shortfall, and an estimateGas search would only find the cheapest passing path
export const GAS_LIMIT = Object.freeze({ '111': 1_200_000n, layer: 3_500_000n, v2: 2_000_000n });
export const SLIPPAGE_DEFAULT = Object.freeze({ '111': 100, layer: 200, v2: 100 });
export const MAX_SLIPPAGE_BPS = 1000; // same bound as script/v2/RunKeeper*.s.sol

export const KEEPER_NAMES = Object.freeze({
  '111': 'CollectFlushKeeperV1',
  layer: 'CollectFlushKeeperLayer',
  v2: 'ArtCoinsKeeperV2',
});

export class ConfigError extends Error {}
const fail = (m) => { throw new ConfigError(m); };

export function readRegistry(file = DEFAULT_REGISTRY) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

const live = (reg, c) => c.address && c.status !== 'planned' && reg.stacks?.[c.stack]?.status !== 'planned';

/// one deployed contract by name (optionally in one stack). role `keeper` wins over any other role when
/// several entries share the name; more than one candidate after that is an error, never a guess.
export function findContract(reg, name, stack) {
  let hits = (reg.contracts || []).filter((c) => c.name === name && (!stack || c.stack === stack) && live(reg, c));
  if (hits.some((c) => c.role === 'keeper')) hits = hits.filter((c) => c.role === 'keeper');
  const addrs = [...new Set(hits.map((c) => c.address.toLowerCase()))];
  if (addrs.length > 1) fail(`registry has ${addrs.length} live ${name} entries${stack ? ' in stack ' + stack : ''}: ${addrs.join(', ')}`);
  return hits[0] ? getAddress(hits[0].address) : null;
}

function envAddress(env, key) {
  const v = env[key];
  if (v === undefined || v === '') return null;
  if (!isAddress(v, { strict: false })) fail(`${key} is not an address: ${v}`);
  return getAddress(v);
}

function envInt(env, key, def, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const v = env[key];
  if (v === undefined || v === '') return def;
  if (!/^\d+$/.test(String(v).trim())) fail(`${key} must be a non negative integer, got ${v}`);
  const n = Number(v);
  if (n < min || n > max) fail(`${key} must be in [${min}, ${max}], got ${v}`);
  return n;
}

function envAmount(env, key, def, decimals = 18) {
  const v = env[key] ?? def;
  try {
    return decimals === 18 && key.endsWith('_ETH') ? parseEther(String(v)) : parseUnits(String(v), decimals);
  } catch {
    return fail(`${key} is not a decimal amount: ${v}`);
  }
}

function slippage(env, id) {
  const specific = `KEEPER_${id.toUpperCase()}_SLIPPAGE_BPS`;
  const key = env[specific] !== undefined && env[specific] !== '' ? specific : 'KEEPER_SLIPPAGE_BPS';
  return envInt(env, key, SLIPPAGE_DEFAULT[id], { max: MAX_SLIPPAGE_BPS });
}

/// Every address an owner field in the registry names. The hot key must not be one of them.
export function ownerAddresses(reg) {
  const s = new Set();
  if (reg.owner) s.add(getAddress(reg.owner));
  for (const c of reg.contracts || []) if (c.owner && isAddress(c.owner, { strict: false })) s.add(getAddress(c.owner));
  return s;
}

/// Builds the runner config. `env` is process.env (or a test object), `reg` the parsed registry.
export function loadConfig(env = process.env, reg = readRegistry(env.REGISTRY_PATH || DEFAULT_REGISTRY)) {
  if (reg.chainId !== 1) fail(`registry chainId ${reg.chainId}, expected 1`);

  const pk = env.KEEPER_PRIVATE_KEY;
  if (!pk) fail('KEEPER_PRIVATE_KEY is not set (fly secrets set KEEPER_PRIVATE_KEY=...)');
  const key = pk.startsWith('0x') ? pk : '0x' + pk;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) fail('KEEPER_PRIVATE_KEY must be 32 bytes hex');
  const account = privateKeyToAccount(key);
  if (ownerAddresses(reg).has(getAddress(account.address))) {
    fail(`KEEPER_PRIVATE_KEY is the owner key ${account.address}. use a dedicated hot key funded under 0.05 eth`);
  }

  const enabled = new Set(String(env.KEEPERS ?? '111,layer,v2').split(',').map((x) => x.trim().toLowerCase()).filter(Boolean));
  for (const k of enabled) if (!['111', 'layer', 'v2'].includes(k)) fail(`KEEPERS: unknown keeper ${k} (111, layer, v2)`);

  // env overrides the registry until the keepers are recorded there (RUNBOOK actions 3 and 2b)
  const k111 = envAddress(env, 'KEEPER_111') ?? findContract(reg, KEEPER_NAMES['111']);
  const kLayer = envAddress(env, 'KEEPER_LAYER') ?? findContract(reg, KEEPER_NAMES.layer);

  // v2: only when a deployed v2 stack exists. coins are the registry coins with stack "v2"
  const v2Stack = reg.stacks?.v2;
  const v2Live = Boolean(v2Stack && v2Stack.status !== 'planned');
  const kV2 = v2Live ? envAddress(env, 'KEEPER_V2') ?? findContract(reg, KEEPER_NAMES.v2, 'v2') : null;
  const v2Coins = v2Live ? (reg.coins || []).filter((c) => c.stack === 'v2' && c.address).map((c) => ({ symbol: c.symbol, address: getAddress(c.address) })) : [];

  const keepers = [];
  if (enabled.has('111')) keepers.push({ id: '111', kind: '111', address: k111, gas: GAS_LIMIT['111'], slippageBps: slippage(env, '111') });
  if (enabled.has('layer')) keepers.push({ id: 'layer', kind: 'layer', address: kLayer, gas: GAS_LIMIT.layer, slippageBps: slippage(env, 'layer') });
  if (enabled.has('v2')) {
    for (const coin of v2Coins) {
      keepers.push({ id: `v2:${coin.symbol}`, kind: 'v2', address: kV2, token: coin.address, symbol: coin.symbol, gas: GAS_LIMIT.v2, slippageBps: slippage(env, 'v2') });
    }
  }

  const privateKeepers = new Set(String(env.PRIVATE_RPC_KEEPERS ?? '111').split(',').map((x) => x.trim().toLowerCase()).filter(Boolean));

  return {
    account,
    rpcUrl: env.MAINNET_RPC_URL || DEFAULT_RPC,
    privateRpcUrl: env.PRIVATE_RPC_URL || null,
    privateKeepers,
    chainId: reg.chainId,
    intervalSeconds: envInt(env, 'INTERVAL_SECONDS', 600, { min: 5 }),
    weeklySeconds: envInt(env, 'WEEKLY_SECONDS', 7 * 24 * 3600, { min: 60 }),
    maxGasWei: BigInt(envInt(env, 'MAX_GAS_GWEI', 30, { min: 1, max: 10_000 })) * 1_000_000_000n,
    maxPriorityWei: parseUnits(String(env.MAX_PRIORITY_GWEI ?? '2'), 9),
    receiptTimeoutSeconds: envInt(env, 'RECEIPT_TIMEOUT_SECONDS', 600, { min: 30 }),
    dropAfterSeconds: envInt(env, 'DROP_AFTER_SECONDS', 1800, { min: 60 }),
    revertCooldownSeconds: envInt(env, 'REVERT_COOLDOWN_SECONDS', 3600),
    lowBalanceWei: envAmount(env, 'LOW_BALANCE_ETH', '0.005'),
    highBalanceWei: envAmount(env, 'HIGH_BALANCE_ETH', '0.05'),
    statePath: env.STATE_PATH || './state.json',
    port: envInt(env, 'PORT', 8080, { max: 65535 }),
    dryRun: env.DRY_RUN === '1' || env.DRY_RUN === 'true',
    thresholds: {
      '111': {
        uncollectedEth: envAmount(env, 'K111_MIN_UNCOLLECTED_ETH', '0.02'),
        uncollectedCoin: envAmount(env, 'K111_MIN_UNCOLLECTED_COIN', '10000'),
        escrowedEth: envAmount(env, 'K111_MAX_ESCROWED_ETH', '0.05'),
      },
      layer: { combinedWeth: envAmount(env, 'KLAYER_MIN_COMBINED_WETH', '0.01') },
      v2: {
        accruedPaired: envAmount(env, 'KV2_MIN_PAIRED_ETH', '0.02'),
        accruedArtCoin: envAmount(env, 'KV2_MIN_COIN', '10000'),
      },
    },
    v2: { live: v2Live, keeper: kV2, coins: v2Coins },
    keepers,
  };
}
