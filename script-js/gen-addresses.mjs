#!/usr/bin/env node
// Generates address constants from deployments/mainnet.json (the registry, verified on chain by
// verify-registry.mjs). Outputs, both committed:
//   script/Addresses.sol                  solidity library, imported by forge scripts
//   ui/src/lib/deployments.generated.ts   typescript constants, imported by ui/src/lib/config.ts
//   README.md                             the table between <!-- deployments:start --> and <!-- deployments:end -->
// Usage: node script-js/gen-addresses.mjs [--check]     (or: cd script-js && npm run gen:addresses)
// --check writes nothing, exits 1 if a generated file differs from disk or ui/public/config.json drifts.
// Output is a pure function of the registry (no timestamps), so reruns are byte identical.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getAddress } from 'viem';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const REGISTRY = path.join(ROOT, 'deployments/mainnet.json');
const OUT_SOL = path.join(ROOT, 'script/Addresses.sol');
const OUT_TS = path.join(ROOT, 'ui/src/lib/deployments.generated.ts');
const UI_CONFIG = path.join(ROOT, 'ui/public/config.json');
const README = path.join(ROOT, 'README.md');
const check = process.argv.includes('--check');

const reg = JSON.parse(fs.readFileSync(REGISTRY, 'utf8'));
const die = (m) => { console.error('gen-addresses: ' + m); process.exit(1); };
const cs = (a) => { try { return getAddress(a); } catch { return die('not an address: ' + a); } };

// ---- lookups (fail loud when the registry no longer has what a constant needs) ----
function contract(stack, name, nth = 0) {
  const hits = reg.contracts.filter((c) => c.stack === stack && c.name === name);
  if (!hits[nth]) die(`registry has no ${name} #${nth} in stack ${stack}`);
  return hits[nth];
}
const coin = (symbol) => reg.coins.find((c) => c.symbol === symbol) ?? die('registry has no coin ' + symbol);
// Stack ids are stable and name the constants (CURRENT_*, OPEN_*, LEGACY_*, V2_*); status is a field.
// A planned stack (null factory) is skipped: no constants until it is deployed.
const deployed = (id) => reg.stacks[id] && reg.stacks[id].status !== 'planned' && reg.stacks[id].factory !== null;
const CURRENT_ID = (() => {
  const ids = Object.entries(reg.stacks).filter(([, s]) => s.status === 'current').map(([id]) => id);
  return ids.length === 1 ? ids[0] : die(`expected exactly one stack with status current, got ${ids}`);
})();
const factoryOf = (id) => reg.contracts.find((c) => c.stack === id && c.role === 'factory' && c.address?.toLowerCase() === reg.stacks[id].factory.toLowerCase()) ?? die('registry has no factory entry in stack ' + id);

// ---- constant table: [constName, contract, note] ----
// nth picks among same named contracts of a stack in registry order (e.g. two LL renderers, two open routers).
const C = (stack, name, nth = 0) => contract(stack, name, nth);
const STACK_CONSTS = [
  ['CURRENT', [
    ['FACTORY', C('current', 'ArtCoinsFactory')],
    ['HOOK', C('current', 'ArtCoinsHookSkimFee')],
    ['LOCKER', C('current', 'ArtCoinsLpLocker')],
    ['ESCROW', C('current', 'ArtCoinsFeeEscrow')],
    ['MEV_LINEAR_SKIM', C('current', 'ArtCoinsMevLinearSkim')],
    ['DEPLOYER_LIB', C('current', 'ArtCoinsDeployer')],
    ['SKIM_INIT_LIB', C('current', 'SkimFeeInitLib')],
    ['PROTOCOL_FEE_CONTROLLER', C('current', 'ProtocolFeeController')],
    ['BURN_ROUTER', C('current', 'BurnRouter')],
    ['FEE_SWAPPER', C('current', 'FeeAutoSwapper')],
    ['LIVE_BID_ADAPTER', C('current', 'LiveBidAdapter')],
    ['PROTOCOL_FEE_PHASE_ADAPTER', C('current', 'ProtocolFeePhaseAdapter')],
    ['TOKEN_ADMIN_POKER', C('current', 'TokenAdminPoker')],
    ['PAYOUT', C('current', 'PassThroughWallet')],
    // the current hook reads this allowlist; it was created in the open stack
    ['POOL_EXTENSION_ALLOWLIST', C('open', 'ArtCoinsPoolExtensionAllowlist')],
  ]],
  ['OPEN', [
    ['FACTORY', C('open', 'ArtCoinsFactory')],
    ['HOOK', C('open', 'ArtCoinsHookStaticFee')],
    ['LOCKER', C('open', 'ArtCoinsLpLocker')],
    ['ESCROW', C('open', 'ArtCoinsFeeEscrow')],
    ['ALLOWLIST', C('open', 'ArtCoinsPoolExtensionAllowlist')],
    ['BURN_ROUTER', C('open', 'BurnRouter', 1)],
    ['BURN_ROUTER_V0', C('open', 'BurnRouter', 0)],
  ]],
  ...(deployed('v2') ? [['V2', [
    ['FACTORY', C('v2', 'ArtCoinsFactoryV2')],
    ['HOOK', C('v2', 'ArtCoinsHookV2')],
    ['LOCKER', C('v2', 'ArtCoinsLpLockerV2')],
    ['ESCROW', C('v2', 'ArtCoinsFeeEscrowV2')],
    ['ALLOWLIST', C('v2', 'ArtCoinsPoolExtensionAllowlist')],
    ['MEV_MODULE', C('v2', 'ArtCoinsMevLinearSkimV2')],
    ['DEPLOYER', C('v2', 'ArtCoinsDeployerV2')],
    ['BURN_ROUTER', C('v2', 'BurnRouterV2')],
    ['PROTOCOL_FEE_CONTROLLER', C('v2', 'ProtocolFeeControllerV2')],
    ['KEEPER', C('v2', 'ArtCoinsKeeperV2')],
  ]]] : []),
  ['LEGACY', [
    ['FACTORY', C('legacy', 'ArtCoinsFactory')],
    ['HOOK', C('legacy', 'ArtCoinsHookStaticFeeV2')],
    ['LOCKER', C('legacy', 'ArtCoinsLpLockerMultiple')],
    ['FEE_LOCKER', C('legacy', 'ArtCoinsFeeLocker')],
    ['ALLOWLIST', C('legacy', 'ArtCoinsPoolExtensionAllowlist')],
    ['DEPLOYER_LIB', C('legacy', 'ArtCoinsDeployer')],
    ['MEV_TIME_DELAY', C('legacy', 'ArtCoinsMevTimeDelay')],
    ['MEV_DESCENDING_FEES', C('legacy', 'ArtCoinsMevDescendingFees')],
    ['MEV_LINEAR_FEES', C('legacy', 'ArtCoinsMevLinearFees')],
    ['MEV_SNIPER_STEPPED_FEES', C('legacy', 'ArtCoinsMevSniperSteppedFees')],
    ['VAULT', C('legacy', 'ArtCoinsVault')],
    ['AIRDROP', C('legacy', 'ArtCoinsAirdropV2')],
    ['BURN_EXTENSION', C('legacy', 'BurnExtension')],
    ['DEV_BUY', C('legacy', 'ArtCoinsUniv4EthDevBuy')],
    ['DEFAULT_RENDERER', C('legacy', 'DefaultMetadataRenderer')],
    ['LL_COUNTER_EXTENSION', C('legacy', 'LiquidityLayerCounterPoolExtension')],
    ['LL_RENDERER', C('legacy', 'LiquidityLayerOnchainRenderer', 1)],
    ['LL_RENDERER_V0', C('legacy', 'LiquidityLayerOnchainRenderer', 0)],
    ['AUTOFORWARD_EXTENSION', C('legacy', 'LiquidityLayerAutoForwardExtension')],
    ['BURN_ROUTER', C('legacy', 'BurnRouter')],
    ['PROTOCOL_FEE_CONTROLLER', C('legacy', 'ProtocolFeeController')],
  ]],
];

// external infra, not in the registry on purpose (it is not ours). each has code on mainnet.
const INFRA = [
  ['POOL_MANAGER', '0x000000000004444c5dc75cB358380D2e3dE08A90'],
  ['POSITION_MANAGER', '0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e'],
  ['PERMIT2', '0x000000000022D473030F116dDEE9F6B43aC78BA3'],
  ['WETH', '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'],
  ['UNIVERSAL_ROUTER', '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af'],
  ['STATE_VIEW', '0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227'],
  ['CREATE2_DEPLOYER', '0x4e59b44847b379578588920cA78FbF26c0B4956C'],
  ['SCRIPTY_BUILDER', '0xD7587F110E08F4D120A231bA97d3B577A81Df022'],
  ['SCRIPTY_STORAGE', '0xbD11994aABB55Da86DC246EBB17C1Be0af5b7699'],
].map(([n, a]) => [n, cs(a)]);

for (const id of Object.keys(reg.stacks)) {
  if (!deployed(id)) console.log(`skip  stack ${id} (${reg.stacks[id].status}, no deployed factory): no constants generated`);
  else if (!STACK_CONSTS.some(([n]) => n.toLowerCase() === id)) die(`stack ${id} is deployed but has no constant table in STACK_CONSTS`);
}
if (!['current', 'v2'].includes(CURRENT_ID)) die('the stack with status current must have id current or v2, got ' + CURRENT_ID);
const ACTIVE_ALIASES = ['FACTORY', 'HOOK', 'LOCKER', 'ESCROW'];

const COIN_CONSTS = reg.coins.map((k) => ['COIN_' + k.symbol.toUpperCase().replace(/[^A-Z0-9]/g, '_'), cs(k.address), k]);

// ---- solidity ----
// forge fmt (line_length 100) wraps long constant declarations after the `=`
const decl = (n, a) => {
  const one = `    address internal constant ${n} = ${a};`;
  return one.length <= 100 ? one : `    address internal constant ${n} =\n        ${a};`;
};
function solidity() {
  const L = [];
  L.push('// SPDX-License-Identifier: MIT');
  L.push('pragma solidity ^0.8.26;');
  L.push('');
  L.push('// generated from deployments/mainnet.json, do not edit.');
  L.push('// regenerate: cd script-js && npm run gen:addresses   (check: node script-js/verify-registry.mjs)');
  L.push('');
  L.push('/// @title Addresses');
  L.push('/// @notice Ethereum mainnet addresses of the artcoins stacks, copied from the registry.');
  L.push('///         Constants are prefixed with the stack id (CURRENT_*, OPEN_*, LEGACY_*, V2_*). ACTIVE_* repeats');
  L.push('///         the stack whose registry status is current. Scripts that target a superseded stack must say');
  L.push('///         so and be gated behind ALLOW_SUPERSEDED=1.');
  L.push('library Addresses {');
  L.push(`    uint256 internal constant CHAIN_ID = ${reg.chainId};`);
  L.push('');
  L.push('    /// @dev owner of nearly every contract below (single eoa).');
  L.push(`    address internal constant OWNER = ${cs(reg.owner)};`);
  L.push('');
  L.push(`    string internal constant CURRENT_STACK_ID = "${CURRENT_ID}";`);
  for (const n of ACTIVE_ALIASES) L.push(`    address internal constant ACTIVE_${n} = ${CURRENT_ID.toUpperCase()}_${n};`);
  L.push('');
  for (const [id, entries] of STACK_CONSTS) {
    const sid = id.toLowerCase();
    const st = reg.stacks[sid];
    L.push(`    // ${id} stack (${st.status}): ${st.label}, factory deployed ${st.deployedAt}`);
    for (const [n, c] of entries) L.push(decl(`${id}_${n}`, cs(c.address)));
    L.push(`    uint256 internal constant ${id}_FACTORY_DEPLOY_BLOCK = ${String(factoryOf(sid).deployBlock).replace(/\B(?=(\d{3})+(?!\d))/g, '_')};`);
    L.push('');
  }
  L.push('    // coins');
  for (const [n, a, k] of COIN_CONSTS) {
    L.push(`    /// @dev ${k.name}, ${k.stack} stack`);
    L.push(decl(n, a));
  }
  L.push('');
  L.push('    // external infra (not in the registry)');
  for (const [n, a] of INFRA) L.push(decl(n, a));
  L.push('}');
  return L.join('\n') + '\n';
}

// ---- typescript ----
function typescript() {
  const q = (a) => `'${a}'`;
  const L = [];
  L.push('// generated from deployments/mainnet.json, do not edit.');
  L.push('// regenerate: cd script-js && npm run gen:addresses   (check: node script-js/verify-registry.mjs)');
  L.push("import type { Address } from 'viem';");
  L.push('');
  L.push(`export const REGISTRY_CHAIN_ID = ${reg.chainId};`);
  L.push(`export const REGISTRY_OWNER: Address = ${q(cs(reg.owner))};`);
  L.push('');
  const ids = Object.keys(reg.stacks).filter(deployed);
  L.push("export type StackId = " + ids.map(q).join(' | ') + ';');
  L.push(`export const CURRENT_STACK_ID: StackId = ${q(CURRENT_ID)};`);
  L.push('');
  L.push('export interface RegistryStack {');
  L.push('  label: string;');
  L.push("  status: 'current' | 'deployed' | 'superseded' | 'legacy';");
  L.push('  factory: Address;');
  L.push('  deployedAt: string;');
  L.push('  /** block of the factory deployment, the fromBlock for TokenCreated scans */');
  L.push('  deployBlock: bigint;');
  L.push('}');
  L.push('');
  L.push('export const STACKS: Record<StackId, RegistryStack> = {');
  for (const id of ids) {
    const s = reg.stacks[id];
    L.push(`  ${id}: {`);
    L.push(`    label: ${JSON.stringify(s.label).replace(/"/g, "'")},`);
    L.push(`    status: ${q(s.status)},`);
    L.push(`    factory: ${q(cs(s.factory))},`);
    L.push(`    deployedAt: ${q(s.deployedAt)},`);
    L.push(`    deployBlock: ${factoryOf(id).deployBlock}n,`);
    L.push('  },');
  }
  L.push('};');
  L.push('');
  const camel = (n) => n.toLowerCase().replace(/_([a-z])/g, (_, x) => x.toUpperCase());
  const stackObj = (name, id, entries, doc, withBlock) => {
    L.push(`/** ${doc} */`);
    L.push(`export const ${name} = {`);
    for (const [n, c] of entries) L.push(`  ${camel(n)}: ${q(cs(c.address))},`);
    if (withBlock) L.push(`  deployBlock: ${factoryOf(id).deployBlock}n,`);
    L.push(withBlock ? '} as const;' : '} as const satisfies Record<string, Address>;');
    L.push('');
  };
  stackObj('CURRENT', 'current', STACK_CONSTS.find(([n]) => n === 'CURRENT')[1], 'addresses of the stack with id current', false);
  const v2 = STACK_CONSTS.find(([n]) => n === 'V2');
  if (v2) stackObj('V2', 'v2', v2[1], 'addresses of the stack with id v2', true);
  L.push('/** addresses by stack id, for the stacks with a table here */');
  L.push(`export const STACK_ADDRESSES = { current: CURRENT${v2 ? ', v2: V2' : ''} } as const;`);
  L.push('');
  L.push('/** addresses of the stack whose registry status is current */');
  L.push(`export const ACTIVE = STACK_ADDRESSES.${CURRENT_ID};`);
  L.push('');
  L.push('/** external infra (not in the registry) */');
  L.push('export const INFRA = {');
  for (const [n, a] of INFRA) L.push(`  ${n.toLowerCase().replace(/_([a-z])/g, (_, x) => x.toUpperCase())}: ${q(a)},`);
  L.push('} as const satisfies Record<string, Address>;');
  L.push('');
  L.push('export interface RegistryCoin {');
  L.push('  symbol: string;');
  L.push('  name: string;');
  L.push('  address: Address;');
  L.push('  stack: StackId;');
  L.push('  factory: Address;');
  L.push('  launchBlock: bigint;');
  L.push('}');
  L.push('');
  L.push('export const COINS: RegistryCoin[] = [');
  for (const k of reg.coins) {
    L.push('  {');
    L.push(`    symbol: ${q(k.symbol)},`);
    L.push(`    name: ${q(k.name)},`);
    L.push(`    address: ${q(cs(k.address))},`);
    L.push(`    stack: ${q(k.stack)},`);
    L.push(`    factory: ${q(cs(k.factory))},`);
    L.push(`    launchBlock: ${k.launchBlock}n,`);
    L.push('  },');
  }
  L.push('];');
  return L.join('\n') + '\n';
}

// ---- readme deployments table ----
const link = (a) => `[${a.slice(0, 6)}…${a.slice(-4)}](https://etherscan.io/address/${a})`;
function readmeBlock() {
  const rows = ['| stack | status | factory | hook | locker | escrow | module | coins |', '|---|---|---|---|---|---|---|---|'];
  // oldest first, by factory deploy date
  const ids = Object.keys(reg.stacks).filter(deployed).sort((a, b) => reg.stacks[a].deployedAt.localeCompare(reg.stacks[b].deployedAt));
  for (const id of ids) {
    const st = reg.stacks[id];
    const inStack = reg.contracts.filter((c) => c.stack === id);
    const role = (r) => inStack.filter((c) => c.role === r);
    const one = (r) => { const h = role(r); return h.length ? link(cs(h[h.length - 1].address)) : 'none'; };
    const fac = factoryOf(id);
    const mods = role('mevModule');
    const mod = mods.length > 1 ? `${mods.length} modules, see registry` : one('mevModule');
    const coins = reg.coins.filter((k) => k.stack === id).map((k) => `\`${k.symbol}\``).join(', ') || 'none';
    const access = fac.state === 'deprecated' ? 'owner only' : 'public';
    rows.push(`| ${id} (${st.deployedAt}) | ${st.status}, ${access} | ${one('factory')} | ${one('hook')} | ${one('locker')} | ${one('escrow')} | ${mod} | ${coins} |`);
  }
  return rows.join('\n');
}
const START = '<!-- deployments:start -->';
const END = '<!-- deployments:end -->';
function readme() {
  const cur = fs.readFileSync(README, 'utf8');
  const i = cur.indexOf(START), j = cur.indexOf(END);
  if (i < 0 || j < i) die(`README.md needs ${START} and ${END} markers`);
  return cur.slice(0, i + START.length) + '\n' + readmeBlock() + '\n' + cur.slice(j);
}

const outputs = [[OUT_SOL, solidity()], [OUT_TS, typescript()], [README, readme()]];
let bad = 0;
for (const [file, text] of outputs) {
  const rel = path.relative(ROOT, file);
  const cur = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if (check) {
    if (cur !== text) { console.error(`DRIFT ${rel} differs from the registry, run: cd script-js && npm run gen:addresses`); bad++; }
    else console.log(`ok    ${rel}`);
  } else if (cur === text) {
    console.log(`same  ${rel}`);
  } else {
    fs.writeFileSync(file, text);
    console.log(`wrote ${rel}`);
  }
}

// the ui runtime config carries one address, the default referrer. it must be the registry payout wallet.
const payout = cs(contract('current', 'PassThroughWallet').address);
const ui = JSON.parse(fs.readFileSync(UI_CONFIG, 'utf8'));
if (ui.defaultReferrer !== payout) { console.error(`DRIFT ui/public/config.json defaultReferrer ${ui.defaultReferrer} != registry payout ${payout}`); bad++; }
else console.log('ok    ui/public/config.json defaultReferrer = registry payout');
process.exit(bad ? 1 : 0);
