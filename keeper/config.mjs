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
// KR-01: minimum spacing between successful runs, enforced from the state file (the weekly timer never shortens it)
export const MIN_RUN_INTERVAL_DEFAULT = Object.freeze({ '111': 6 * 3600, layer: 24 * 3600, v2: 6 * 3600 });
// KR-14: how often each keeper's preview is read and decided, RUNBOOK cadence rows (111 hourly, LAYER daily cron,
// v2 hourly cron). the loop itself ticks every INTERVAL_SECONDS to settle and replace a tx in flight
export const CHECK_INTERVAL_DEFAULT = Object.freeze({ '111': 3600, layer: 24 * 3600, v2: 3600 });
// KR-14 value vs gas rule (runbook: skip when pending is worth less than the gas unless the timer is due). typical
// gas of one run, not the limit: 111 measured 870k, v2 unmeasured (v1 figures plus room)
export const EXPECTED_GAS = Object.freeze({ '111': 900_000n, layer: 900_000n, v2: 1_200_000n });
// KR-09: privileged eoas the hot key must never be, whatever the registry says (owner of nearly everything and the
// ui protocol payout). OWNER_ADDRESS env adds one more
export const DEFAULT_OWNER = '0xCB43078C32423F5348Cab5885911C3B5faE217F9';
export const REFUSED_KEYS = Object.freeze([DEFAULT_OWNER, '0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4']);
export const KEEPER_IDS = Object.freeze(['111', 'layer', 'v2']);
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

/// per keeper env `KEEPER_<ID>_<NAME>` wins over the global `<global>` env, then the default
function perKeeper(env, id, name, global, def, bounds) {
  const specific = `KEEPER_${id.toUpperCase()}_${name}`;
  const key = env[specific] !== undefined && env[specific] !== '' ? specific : global;
  return envInt(env, key, def, bounds);
}
const slippage = (env, id) => perKeeper(env, id, 'SLIPPAGE_BPS', 'KEEPER_SLIPPAGE_BPS', SLIPPAGE_DEFAULT[id], { max: MAX_SLIPPAGE_BPS });

/// KR-07: dry run unless DRY_RUN is unset, empty, "0" or "false". any other value (TRUE, yes, on, typos) is dry
export function parseDryRun(v) {
  if (v === undefined || v === null) return false;
  const t = String(v).trim().toLowerCase();
  return !(t === '' || t === '0' || t === 'false');
}

const csv = (v) => String(v).split(',').map((x) => x.trim().toLowerCase()).filter(Boolean);

/// Every address the hot key must not be: each owner field in the registry, the built in privileged eoas
/// (REFUSED_KEYS) and `OWNER_ADDRESS` from the env (KR-09).
export function ownerAddresses(reg, env = {}) {
  const s = new Set(REFUSED_KEYS.map((a) => getAddress(a)));
  if (env.OWNER_ADDRESS) {
    if (!isAddress(env.OWNER_ADDRESS, { strict: false })) fail(`OWNER_ADDRESS is not an address: ${env.OWNER_ADDRESS}`);
    s.add(getAddress(env.OWNER_ADDRESS));
  }
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
  let account;
  try {
    account = privateKeyToAccount(key);
  } catch {
    // KR-13: viem's message prints the scalar; never echo any part of the key
    fail('KEEPER_PRIVATE_KEY is not a valid secp256k1 private key');
  }
  if (!reg.owner) fail('registry has no owner field: refusing to start without the owner refusal list');
  if (ownerAddresses(reg, env).has(getAddress(account.address))) {
    fail(`KEEPER_PRIVATE_KEY is the owner key ${account.address}. use a dedicated hot key funded under 0.05 eth`);
  }

  const enabled = new Set(csv(env.KEEPERS ?? KEEPER_IDS.join(',')));
  for (const k of enabled) if (!KEEPER_IDS.includes(k)) fail(`KEEPERS: unknown keeper ${k} (111, layer, v2)`);

  // env overrides the registry until the keepers are recorded there (RUNBOOK actions 3 and 2b)
  const k111 = envAddress(env, 'KEEPER_111') ?? findContract(reg, KEEPER_NAMES['111']);
  const kLayer = envAddress(env, 'KEEPER_LAYER') ?? findContract(reg, KEEPER_NAMES.layer);

  // v2: only when a deployed v2 stack exists. coins are the registry coins with stack "v2"
  const v2Stack = reg.stacks?.v2;
  const v2Live = Boolean(v2Stack && v2Stack.status !== 'planned');
  const kV2 = v2Live ? envAddress(env, 'KEEPER_V2') ?? findContract(reg, KEEPER_NAMES.v2, 'v2') : null;
  const v2Coins = v2Live ? (reg.coins || []).filter((c) => c.stack === 'v2' && c.address).map((c) => ({ symbol: c.symbol, address: getAddress(c.address) })) : [];

  const common = (id) => ({
    gas: GAS_LIMIT[id],
    slippageBps: slippage(env, id),
    minRunIntervalSeconds: perKeeper(env, id, 'MIN_RUN_INTERVAL_SECONDS', 'MIN_RUN_INTERVAL_SECONDS', MIN_RUN_INTERVAL_DEFAULT[id]),
    checkIntervalSeconds: perKeeper(env, id, 'CHECK_INTERVAL_SECONDS', 'CHECK_INTERVAL_SECONDS', CHECK_INTERVAL_DEFAULT[id]),
    expectedGas: EXPECTED_GAS[id],
  });
  const keepers = [];
  if (enabled.has('111')) keepers.push({ id: '111', kind: '111', address: k111, ...common('111') });
  if (enabled.has('layer')) keepers.push({ id: 'layer', kind: 'layer', address: kLayer, ...common('layer') });
  if (enabled.has('v2')) {
    for (const coin of v2Coins) {
      keepers.push({ id: `v2:${coin.symbol}`, kind: 'v2', address: kV2, token: coin.address, symbol: coin.symbol, ...common('v2') });
    }
  }

  // KR-08: every keeper goes through the relay when one is set (LAYER burns and v2 converts are sandwichable too).
  // unknown entries are an error, not ignored
  const privateKeepers = new Set(csv(env.PRIVATE_RPC_KEEPERS ?? KEEPER_IDS.join(',')));
  for (const k of privateKeepers) if (!KEEPER_IDS.includes(k)) fail(`PRIVATE_RPC_KEEPERS: unknown keeper ${k} (111, layer, v2)`);
  const privateRpcUrl = env.PRIVATE_RPC_URL || null;
  const dryRun = parseDryRun(env.DRY_RUN);
  const allowPublicMempool = env.ALLOW_PUBLIC_MEMPOOL === '1';
  // the 111 convert carries an absolute minOut for up to 30 minutes: live mode needs the relay for it
  if (!dryRun && enabled.has('111') && !(privateRpcUrl && privateKeepers.has('111')) && !allowPublicMempool) {
    fail('the 111 keeper sends through the public mempool: set PRIVATE_RPC_URL (with 111 in PRIVATE_RPC_KEEPERS) or ALLOW_PUBLIC_MEMPOOL=1');
  }

  const statusToken = env.STATUS_TOKEN || null;
  if (statusToken && statusToken.length < 16) fail('STATUS_TOKEN must be at least 16 characters');

  const maxGasWei = BigInt(envInt(env, 'MAX_GAS_GWEI', 14, { min: 1, max: 10_000 })) * 1_000_000_000n;
  // KR-06: the node refuses a tx unless balance >= gas limit * maxFeePerGas. the worst case is the largest enabled
  // gas limit at the fee cap; LOW_BALANCE_ETH defaults to that
  const maxLimit = keepers.reduce((m, k) => (k.gas > m ? k.gas : m), 0n) || GAS_LIMIT['111'];
  const requiredBalanceWei = maxLimit * maxGasWei;

  return {
    account,
    rpcUrl: env.MAINNET_RPC_URL || DEFAULT_RPC,
    privateRpcUrl,
    privateKeepers,
    allowPublicMempool,
    chainId: reg.chainId,
    intervalSeconds: envInt(env, 'INTERVAL_SECONDS', 600, { min: 5 }),
    weeklySeconds: envInt(env, 'WEEKLY_SECONDS', 7 * 24 * 3600, { min: 60 }),
    maxGasWei,
    maxPriorityWei: parseUnits(String(env.MAX_PRIORITY_GWEI ?? '2'), 9),
    requiredBalanceWei,
    receiptTimeoutSeconds: envInt(env, 'RECEIPT_TIMEOUT_SECONDS', 600, { min: 30 }),
    // KR-04: an unmined tx is replaced at the same nonce after this long, MAX_REPLACEMENTS times, then cancelled
    pendingTimeoutSeconds: envInt(env, 'PENDING_TIMEOUT_SECONDS', 1800, { min: 60 }),
    maxReplacements: envInt(env, 'MAX_REPLACEMENTS', 3, { max: 10 }),
    revertCooldownSeconds: envInt(env, 'REVERT_COOLDOWN_SECONDS', 3600),
    // KR-01: a successful run must drop each threshold metric that triggered it by this share, else backoff
    progressMinBps: envInt(env, 'PROGRESS_MIN_BPS', 5000, { max: 10_000 }),
    backoffMinSeconds: envInt(env, 'BACKOFF_MIN_SECONDS', 3600, { min: 60 }),
    backoffMaxSeconds: envInt(env, 'BACKOFF_MAX_SECONDS', 24 * 3600, { min: 60 }),
    // KR-02: spot floor allowance for price impact, on top of slippage
    maxImpactBps: envInt(env, 'MAX_IMPACT_BPS', 100, { max: 2000 }),
    lowBalanceWei: env.LOW_BALANCE_ETH ? envAmount(env, 'LOW_BALANCE_ETH', '0') : requiredBalanceWei,
    highBalanceWei: envAmount(env, 'HIGH_BALANCE_ETH', '0.05'),
    statePath: env.STATE_PATH || './state.json',
    ephemeralState: env.EPHEMERAL_STATE === '1',
    port: envInt(env, 'PORT', 8080, { max: 65535 }),
    statusToken,
    dryRun,
    thresholds: {
      '111': {
        uncollectedEth: envAmount(env, 'K111_MIN_UNCOLLECTED_ETH', '0.02'),
        uncollectedCoin: envAmount(env, 'K111_MIN_UNCOLLECTED_COIN', '10000'),
        escrowedEth: envAmount(env, 'K111_MAX_ESCROWED_ETH', '0.05'),
      },
      layer: { combinedWeth: envAmount(env, 'KLAYER_MIN_COMBINED_WETH', '0.01') },
      v2: {
        accruedPaired: envAmount(env, 'KV2_MIN_PAIRED_ETH', '0.02'),
        accruedCoin: envAmount(env, 'KV2_MIN_COIN', '10000'),
      },
    },
    v2: { live: v2Live, keeper: kV2, coins: v2Coins },
    keepers,
  };
}
