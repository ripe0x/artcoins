#!/usr/bin/env node
/**
 * Prints the env vars the launch scripts read (FACTORY, HOOK, LOCKER, ...) for one stack of the
 * registry, deployments/mainnet.json. It reads only the registry: no broadcast files, no sibling
 * repo, and it never writes a file (the old version patched a config.ts in another checkout and
 * a local .env from broadcast records, which could only produce the legacy stack).
 *
 * Usage:
 *   node script-js/sync-addresses.mjs [--stack current|open|legacy] [--json]
 *   eval "$(node script-js/sync-addresses.mjs --stack legacy)"     # export into the shell
 *
 * The ui reads script-js/gen-addresses.mjs output instead (ui/src/lib/deployments.generated.ts).
 * Verify the registry itself with: node script-js/verify-registry.mjs
 */
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const argVal = (f) => { const i = args.indexOf(f); return i !== -1 ? args[i + 1] : undefined; };
const stack = argVal('--stack') ?? 'current';
const asJson = args.includes('--json');
const registryPath = resolve(dirname(fileURLToPath(import.meta.url)), '../deployments/mainnet.json');
const reg = JSON.parse(readFileSync(registryPath, 'utf8'));

if (!reg.stacks[stack]) {
  console.error(`unknown stack "${stack}", registry has: ${Object.keys(reg.stacks).join(', ')}`);
  process.exit(2);
}

// env var -> [contract name, nth among same named contracts of the stack]
const ENV_TO_CONTRACT = {
  FACTORY: ['ArtCoinsFactory'],
  FEE_LOCKER: ['ArtCoinsFeeLocker'],
  ESCROW: ['ArtCoinsFeeEscrow'],
  POOL_EXT_ALLOWLIST: ['ArtCoinsPoolExtensionAllowlist'],
  HOOK: ['ArtCoinsHookSkimFee', 'ArtCoinsHookStaticFee', 'ArtCoinsHookStaticFeeV2'],
  LOCKER: ['ArtCoinsLpLocker', 'ArtCoinsLpLockerMultiple'],
  VAULT: ['ArtCoinsVault'],
  AIRDROP: ['ArtCoinsAirdropV2'],
  DEV_BUY: ['ArtCoinsUniv4EthDevBuy'],
  MEV_SNIPER_STEPPED: ['ArtCoinsMevSniperSteppedFees'],
  MEV_LINEAR: ['ArtCoinsMevLinearFees'],
  MEV_LINEAR_SKIM: ['ArtCoinsMevLinearSkim'],
  MEV_DESC_FEES: ['ArtCoinsMevDescendingFees'],
  MEV_TIME_DELAY: ['ArtCoinsMevTimeDelay'],
  BURN_EXTENSION: ['BurnExtension'],
  DEFAULT_RENDERER: ['DefaultMetadataRenderer'],
  LL_COUNTER: ['LiquidityLayerCounterPoolExtension'],
  LL_RENDERER: ['LiquidityLayerOnchainRenderer'],
  BURN_ROUTER: ['BurnRouter'],
  PROTOCOL_FEE_CONTROLLER: ['ProtocolFeeController'],
  FEE_SWAPPER: ['FeeAutoSwapper'],
};

const inStack = reg.contracts.filter((c) => c.stack === stack);
const out = {};
for (const [envVar, names] of Object.entries(ENV_TO_CONTRACT)) {
  // a stack may hold several same named contracts (two LL renderers, two routers): the newest wins
  // (registry order is deployment order), the older ones are not exported.
  const hits = inStack.filter((c) => names.includes(c.name));
  if (hits.length) out[envVar] = hits[hits.length - 1].address;
}

// the current hook reads the allowlist created in the open stack (see registry notes)
if (stack === 'current' && !out.POOL_EXT_ALLOWLIST) {
  const a = reg.contracts.find((c) => c.stack === 'open' && c.name === 'ArtCoinsPoolExtensionAllowlist');
  if (a) out.POOL_EXT_ALLOWLIST = a.address;
}

if (asJson) {
  console.log(JSON.stringify({ stack, ...out }, null, 2));
} else {
  console.log(`# registry stack "${stack}" (${reg.stacks[stack].status}), from deployments/mainnet.json`);
  for (const [k, v] of Object.entries(out)) console.log(`export ${k}=${v}`);
}
