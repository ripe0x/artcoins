#!/usr/bin/env node
/**
 * Reads Foundry broadcast run-latest.json files and patches MAINNET_ADDRESSES
 * (or SEPOLIA_ADDRESSES) — plus, whenever the factory address itself is
 * patched, the matching entry in `factoryDeploymentBlocks` — in THIS repo's
 * `ui/src/lib/config.ts` (the `ContractAddresses` interface defined there:
 * factory, hook, locker, mevLinearFees, mevDescFees, mevTimeDelay, vault,
 * airdrop, devBuy, weth, poolManager, stateView, quoter, universalRouter,
 * permit2). It does NOT target the sibling permanent-collection app's
 * config — run with --config-path if you need to point it elsewhere.
 *
 * Usage:
 *   node script-js/sync-addresses.mjs [options]
 *
 * Options:
 *   --chain <id>           Chain ID to sync (default: 1 = mainnet)
 *   --broadcast-dir <dir>  Path to broadcast/ directory (default: ./broadcast)
 *   --config-path <path>   Path to config.ts (default: ./ui/src/lib/config.ts,
 *                          i.e. this repo's UI config).
 *                          Override with ARTCOINS_CONFIG env var.
 *   --env-path <path>      Path to local .env to update (default: ./.env).
 *                          Pass --no-env to skip the .env update.
 *   --dry-run              Print changes without writing the file
 *
 * Run from the repo root (paths above are relative to cwd).
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
  'ui/src/lib/config.ts'
);
const skipEnv = args.includes('--no-env');
const envPath = skipEnv ? null : resolve(argVal('--env-path') ?? '.env');
const TARGET_CONST = chainId === 1 ? 'MAINNET_ADDRESSES' : 'SEPOLIA_ADDRESSES';

// UI config field → .env variable name. Reconciled against the actual
// `ContractAddresses` interface in ui/src/lib/config.ts — every field below
// exists there. (weth/poolManager/stateView/quoter/universalRouter/permit2
// are external deployments, not produced by any CREATE in this repo's
// broadcast/ — listed here so the .env sync stays consistent if that ever
// changes, but MAPPINGS below has no entries that populate them.)
const FIELD_TO_ENV = {
  factory:         'FACTORY',
  hook:            'HOOK',
  locker:          'LOCKER',
  mevLinearFees:   'MEV_LINEAR',
  mevDescFees:     'MEV_DESC_FEES',
  mevTimeDelay:    'MEV_TIME_DELAY',
  vault:           'VAULT',
  airdrop:         'AIRDROP',
  devBuy:          'DEV_BUY',
  weth:            'WETH',
  poolManager:     'POOL_MANAGER',
  stateView:       'STATE_VIEW',
  quoter:          'QUOTER',
  universalRouter: 'UNIVERSAL_ROUTER',
  permit2:         'PERMIT2',
};

// ─── Contract name → config field mapping ───────────────────────────────────
//
// Each entry is { script, contracts: [{ name, field }] }.
// The first match for a given field wins (Deploy.s.sol is listed first so its
// output takes priority over standalone deploy scripts).
//
// Only fields present in ui/src/lib/config.ts's `ContractAddresses` are
// mapped here — script/Deploy.s.sol also deploys several contracts
// (ArtCoinsFeeLocker, ArtCoinsPoolExtensionAllowlist, BurnExtension,
// DefaultMetadataRenderer, the LiquidityLayer counter/renderer, ...) that
// this UI's config has no field for; they're intentionally left unmapped
// rather than invented as sibling-app-only fields nothing here reads.
// Likewise script/DeployNativeEthStack.s.sol (the separate "V3" native-ETH
// factory stack) is not mapped — this UI targets the V1 `deployToken(...)`
// stack from Deploy.s.sol only (see README.md "Deployed addresses").
//
// Contract names below are taken verbatim from `contractName` in this
// repo's broadcast/ artifacts, which can differ from the current src/
// file's contract name after a rename (e.g. the mainnet airdrop deploy
// recorded `ArtCoinsAirdropV2` even though src/extensions/ArtCoinsAirdrop.sol
// now declares `contract ArtCoinsAirdrop`) — verify against a fresh
// run-latest.json if a field stops matching after a contract rename.

const MAPPINGS = [
  {
    script: 'Deploy.s.sol',
    contracts: [
      { name: 'ArtCoinsFactory',             field: 'factory'          },
      // Hook can be deployed under a few names depending on salt iteration
      { name: 'ArtCoinsHookStaticFeeV2',     field: 'hook'             },
      { name: 'NewMaterialHookStaticFeeV2',  field: 'hook'             },
      { name: 'ArtCoinsLpLockerMultiple',    field: 'locker'           },
      { name: 'ArtCoinsVault',               field: 'vault'            },
      { name: 'ArtCoinsAirdropV2',           field: 'airdrop'          },
      { name: 'ArtCoinsAirdrop',             field: 'airdrop'          },
      { name: 'ArtCoinsUniv4EthDevBuy',      field: 'devBuy'           },
      { name: 'ArtCoinsMevLinearFees',       field: 'mevLinearFees'    },
      { name: 'ArtCoinsMevDescendingFees',   field: 'mevDescFees'      },
      { name: 'ArtCoinsMevTimeDelay',        field: 'mevTimeDelay'     },
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

// Looks up the `receipts[].blockNumber` (hex string) for a deployed address
// in a given script's run-latest.json, returned as a BigInt. Used to keep
// `factoryDeploymentBlocks` in sync whenever the factory address is patched
// — a stale/zero deployment block makes `getFactoryDeploymentBlock` scan
// getLogs from genesis (see ui/src/lib/events.ts), so this must never be
// left for a human to remember to do by hand.
function getBlockNumberForAddress(scriptName, address) {
  const path = join(broadcastDir, scriptName, String(chainId), 'run-latest.json');
  if (!existsSync(path)) return null;
  let data;
  try {
    data = JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
  const receipt = (data.receipts ?? []).find(
    (r) => r.contractAddress && r.contractAddress.toLowerCase() === address.toLowerCase()
  );
  if (!receipt || !receipt.blockNumber) return null;
  return BigInt(receipt.blockNumber);
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

let newSrc =
  src.slice(0, match.index) +
  match[1] +
  block +
  match[3] +
  src.slice(match.index + match[0].length);

// ─── Also patch factoryDeploymentBlocks whenever `factory` itself changed ───
//
// Keeps step "set the deployment block" from ever being forgotten again:
// any time this script writes a new factory address, it writes the matching
// block number in the same pass.

let blockPatch = null; // { chainId, blockNumber, source } | null
const factoryPatch = patches.find((p) => p.field === 'factory');
if (factoryPatch) {
  const blockNumber = getBlockNumberForAddress(factoryPatch.source, factoryPatch.address);
  if (blockNumber === null) {
    console.warn(
      `  warn: no receipt blockNumber found for the new factory address in ` +
      `${factoryPatch.source} — factoryDeploymentBlocks[${chainId}] NOT updated. ` +
      `Set it by hand or the UI will scan getLogs from genesis.`
    );
  } else {
    const blocksBlockRe =
      /(const factoryDeploymentBlocks: Record<number, bigint> = \{)([\s\S]*?)(\};)/;
    const blocksMatch = newSrc.match(blocksBlockRe);
    if (!blocksMatch) {
      console.warn(
        `  warn: could not locate "factoryDeploymentBlocks" block in ${configPath} — ` +
        `NOT updated. Set factoryDeploymentBlocks[${chainId}] = ${blockNumber}n by hand.`
      );
    } else {
      let blocksBlock = blocksMatch[2];
      const comment = ` // synced by sync-addresses.mjs from ${factoryPatch.source} (factory ${factoryPatch.address})`;
      const entryRe = new RegExp(`^(\\s*)${chainId}:\\s*[0-9_]+n.*$`, 'm');
      if (entryRe.test(blocksBlock)) {
        blocksBlock = blocksBlock.replace(entryRe, `$1${chainId}: ${blockNumber}n,${comment}`);
      } else {
        blocksBlock = blocksBlock.replace(/(\s*)$/, `\n  ${chainId}: ${blockNumber}n,${comment}$1`);
      }
      newSrc =
        newSrc.slice(0, blocksMatch.index) +
        blocksMatch[1] +
        blocksBlock +
        blocksMatch[3] +
        newSrc.slice(blocksMatch.index + blocksMatch[0].length);
      blockPatch = { chainId, blockNumber, source: factoryPatch.source };
    }
  }
}

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

if (blockPatch) {
  console.log(
    `\nAlso patched factoryDeploymentBlocks[${blockPatch.chainId}] = ${blockPatch.blockNumber}n ` +
    `(from ${blockPatch.source} receipt).`
  );
}

// ─── Write ────────────────────────────────────────────────────────────────────

if (dryRun) {
  console.log('\n--dry-run: config.ts not written.');
} else {
  writeFileSync(configPath, newSrc);
  console.log(`\nWrote ${patches.length} field(s)${blockPatch ? ' + factoryDeploymentBlocks' : ''} to:\n  ${configPath}`);
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
