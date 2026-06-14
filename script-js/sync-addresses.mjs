#!/usr/bin/env node
/**
 * Reads Foundry broadcast run-latest.json files and patches MAINNET_ADDRESSES
 * (or SEPOLIA_ADDRESSES) in the artcoins app's src/lib/launcher/config.ts.
 *
 * Usage:
 *   node script-js/sync-addresses.mjs [options]
 *
 * Options:
 *   --chain <id>           Chain ID to sync (default: 1 = mainnet)
 *   --broadcast-dir <dir>  Path to broadcast/ directory (default: ./broadcast)
 *   --config-path <path>   Path to config.ts (default: ../artcoins/src/lib/launcher/config.ts)
 *                          Override with ARTCOINS_CONFIG env var.
 *   --env-path <path>      Path to local .env to update (default: ./.env).
 *                          Pass --no-env to skip the .env update.
 *   --dry-run              Print changes without writing the file
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';

// ─── Args ────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');

function argVal(flag) {
  const i = args.indexOf(flag);
  return i !== -1 ? args[i + 1] : undefined;
}

const chainId   = parseInt(argVal('--chain') ?? '1', 10);
const broadcastDir = resolve(argVal('--broadcast-dir') ?? 'broadcast');
const configPath   = resolve(
  argVal('--config-path') ??
  process.env.ARTCOINS_CONFIG ??
  '../artcoins/src/lib/launcher/config.ts'
);
const skipEnv = args.includes('--no-env');
const envPath = skipEnv ? null : resolve(argVal('--env-path') ?? '.env');
const TARGET_CONST = chainId === 1 ? 'MAINNET_ADDRESSES' : 'SEPOLIA_ADDRESSES';

// UI config field → .env variable name. Keep aligned with the artcoins UI.
const FIELD_TO_ENV = {
  factory:               'FACTORY',
  feeLocker:             'FEE_LOCKER',
  poolExtAllowlist:      'POOL_EXT_ALLOWLIST',
  hook:                  'HOOK',
  locker:                'LOCKER',
  vault:                 'VAULT',
  airdrop:               'AIRDROP',
  devBuy:                'DEV_BUY',
  mevSteppedFees:        'MEV_SNIPER_STEPPED',
  mevLinearFees:         'MEV_LINEAR',
  mevDescFees:           'MEV_DESC_FEES',
  mevTimeDelay:          'MEV_TIME_DELAY',
  burnExtension:         'BURN_EXTENSION',
  defaultRenderer:       'DEFAULT_RENDERER',
  llCounter:             'LL_COUNTER',
  llRenderer:            'LL_RENDERER',
  burnRouter:            'BURN_ROUTER',
  protocolFeeController: 'PROTOCOL_FEE_CONTROLLER',
  liquiditySupport:      'LIQUIDITY_SUPPORT',
};

// ─── Contract name → config field mapping ───────────────────────────────────
//
// Each entry is { script, contracts: [{ name, field }] }.
// The first match for a given field wins (Deploy.s.sol is listed first so its
// output takes priority over standalone deploy scripts).

const MAPPINGS = [
  {
    script: 'Deploy.s.sol',
    contracts: [
      { name: 'ArtCoinsFactory',             field: 'factory'          },
      { name: 'ArtCoinsFeeLocker',           field: 'feeLocker'        },
      { name: 'ArtCoinsPoolExtensionAllowlist', field: 'poolExtAllowlist' },
      // Hook can be deployed under a few names depending on salt iteration
      { name: 'ArtCoinsHookStaticFeeV2',     field: 'hook'             },
      { name: 'NewMaterialHookStaticFeeV2',  field: 'hook'             },
      { name: 'ArtCoinsLpLockerMultiple',    field: 'locker'           },
      { name: 'ArtCoinsVault',               field: 'vault'            },
      { name: 'ArtCoinsAirdrop',           field: 'airdrop'          },
      { name: 'BurnExtension',               field: 'burnExtension'    },
      { name: 'ArtCoinsUniv4EthDevBuy',      field: 'devBuy'           },
      // Deploy.s.sol includes stepped fees starting with the audit-fixed version
      { name: 'ArtCoinsMevSniperSteppedFees', field: 'mevSteppedFees' },
      { name: 'ArtCoinsMevLinearFees',       field: 'mevLinearFees'    },
      { name: 'ArtCoinsMevDescendingFees',   field: 'mevDescFees'      },
      { name: 'ArtCoinsMevTimeDelay',        field: 'mevTimeDelay'     },
      { name: 'DefaultMetadataRenderer',     field: 'defaultRenderer'  },
      { name: 'LiquidityLayerCounterPoolExtension', field: 'llCounter' },
      { name: 'LiquidityLayerOnchainRenderer', field: 'llRenderer'     },
    ],
  },
  {
    // Older separate stepped-fees deploy (pre-audit); fallback if not in Deploy
    script: 'DeployMevSteppedFees.s.sol',
    contracts: [
      { name: 'ArtCoinsMevSteppedFees',      field: 'mevSteppedFees'  },
    ],
  },
  {
    script: 'DeployBurnExtension.s.sol',
    contracts: [
      { name: 'BurnExtension',               field: 'burnExtension'    },
    ],
  },
  {
    script: 'DeployProtocolFeeStack.s.sol',
    contracts: [
      { name: 'BurnRouter',                  field: 'burnRouter'       },
      { name: 'ProtocolFeeController',       field: 'protocolFeeController' },
      { name: 'LiquiditySupportReceiver',    field: 'liquiditySupport' },
    ],
  },
];

// ─── Read broadcast files ────────────────────────────────────────────────────

function readBroadcast(scriptName) {
  const path = join(broadcastDir, scriptName, String(chainId), 'run-latest.json');
  if (!existsSync(path)) return {};
  let data;
  try {
    data = JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    console.warn(`  warn: could not parse ${path}`);
    return {};
  }
  const map = {};
  for (const tx of data.transactions ?? []) {
    if (
      (tx.transactionType === 'CREATE' || tx.transactionType === 'CREATE2') &&
      tx.contractName &&
      tx.contractAddress
    ) {
      // Keep first occurrence (contracts deployed multiple times in one run
      // are unusual but possible in test helpers — first is the real one).
      if (!map[tx.contractName]) {
        map[tx.contractName] = tx.contractAddress.toLowerCase();
      }
    }
  }
  return map;
}

// Build field → address (first match wins across scripts)
const found = {}; // field -> { address, source }
for (const { script, contracts } of MAPPINGS) {
  const deployed = readBroadcast(script);
  for (const { name, field } of contracts) {
    if (deployed[name] && !found[field]) {
      found[field] = { address: deployed[name], source: script, contractName: name };
    }
  }
}

// ─── Validate ────────────────────────────────────────────────────────────────

if (Object.keys(found).length === 0) {
  console.error(
    `No addresses found.\n` +
    `  broadcast dir: ${broadcastDir}\n` +
    `  chain ID:      ${chainId}\n` +
    `Check that run-latest.json files exist for chain ${chainId}.`
  );
  process.exit(1);
}

if (!existsSync(configPath)) {
  console.error(`config.ts not found at:\n  ${configPath}`);
  process.exit(1);
}

// ─── Patch config.ts ─────────────────────────────────────────────────────────

let src = readFileSync(configPath, 'utf8');

// Locate the target const block.
// Matches:  const MAINNET_ADDRESSES: ContractAddresses = {  ...  };
const blockRe = new RegExp(
  `(const ${TARGET_CONST}[^=]*=\\s*\\{)([\\s\\S]*?)(\\};)`,
);
const match = src.match(blockRe);
if (!match) {
  console.error(`Could not locate "${TARGET_CONST}" block in:\n  ${configPath}`);
  process.exit(1);
}

let block = match[2];
const patches = [];
const skipped = [];

for (const [field, { address, source, contractName }] of Object.entries(found)) {
  // Matches:  field: 'anything',   OR   field: ZERO,
  const fieldRe = new RegExp(
    `(\\b${field}:\\s*)(?:'0x[0-9a-fA-F]+'|ZERO)`,
    'g',
  );
  const replacement = `$1'${address}'`;
  const next = block.replace(fieldRe, replacement);
  if (next !== block) {
    block = next;
    patches.push({ field, address, contractName, source });
  } else {
    skipped.push(field);
  }
}

const newSrc =
  src.slice(0, match.index) +
  match[1] +
  block +
  match[3] +
  src.slice(match.index + match[0].length);

// ─── Report ──────────────────────────────────────────────────────────────────

const chain = chainId === 1 ? 'mainnet' : `chain ${chainId}`;
console.log(`\nsync-addresses — ${chain} → ${TARGET_CONST}\n`);

if (patches.length > 0) {
  console.log('Patching:');
  for (const { field, address, contractName, source } of patches) {
    console.log(`  ${field.padEnd(24)} ${address}  (${contractName} from ${source})`);
  }
} else {
  console.log('No fields changed (all addresses already up to date or fields not found).');
}

if (skipped.length > 0) {
  console.log(`\nSkipped (field not found in block — check field name):`);
  for (const f of skipped) console.log(`  ${f}`);
}

// ─── Write ────────────────────────────────────────────────────────────────────

if (dryRun) {
  console.log('\n--dry-run: config.ts not written.');
} else {
  writeFileSync(configPath, newSrc);
  console.log(`\nWrote ${patches.length} field(s) to:\n  ${configPath}`);
}

// ─── Update local .env ──────────────────────────────────────────────────────

if (envPath) {
  if (!existsSync(envPath)) {
    console.log(`\n.env not found at ${envPath} — skipping local env update.`);
  } else {
    const envSrc = readFileSync(envPath, 'utf8');
    const envLines = envSrc.split('\n');
    const envUpdates = {};
    for (const [field, { address }] of Object.entries(found)) {
      const key = FIELD_TO_ENV[field];
      if (key) envUpdates[key] = address;
    }
    const seen = new Set();
    const newLines = envLines.map((line) => {
      const m = line.match(/^([A-Z_][A-Z0-9_]*)=/);
      if (m && envUpdates[m[1]] !== undefined) {
        seen.add(m[1]);
        return `${m[1]}=${envUpdates[m[1]]}`;
      }
      return line;
    });
    for (const [k, v] of Object.entries(envUpdates)) {
      if (!seen.has(k)) newLines.push(`${k}=${v}`);
    }
    const newEnv = newLines.join('\n');
    if (dryRun) {
      console.log('\n--dry-run: .env not written.');
    } else if (newEnv !== envSrc) {
      writeFileSync(envPath, newEnv);
      console.log(`Wrote ${Object.keys(envUpdates).length} key(s) to:\n  ${envPath}`);
    } else {
      console.log(`\n.env already up to date.`);
    }
  }
}
