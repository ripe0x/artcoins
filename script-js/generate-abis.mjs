#!/usr/bin/env node
// Compiles a fixed list of contracts (this repo's src/ plus a couple of
// Uniswap v4-periphery "lens" contracts that compile cleanly standalone)
// with solc, and writes their ABIs to ui/src/lib/abi.generated.ts.
//
// Why solc-js directly instead of `forge build`: this environment can't
// install Foundry (the proxy blocks foundry.paradigm.xyz), but the pure-JS
// `solc` package pinned to the same version as `foundry.toml`'s
// `solc = "0.8.26"` compiles fine and is all we need for ABI output.
//
// Foundry resolves imports via `remappings.txt` PLUS an implicit rule: every
// directory directly under `lib/` (and, recursively, under any nested
// `lib/`) is itself importable by name, trying both `<name>/<rest>` and
// `<name>/src/<rest>`. We reproduce both pieces below (`REMAPPINGS`,
// `indexLibRoots`/`resolveImport`) — without the implicit-lib-root piece,
// imports like `permit2/src/...` (used internally by v4-core) fail with
// "Source not found" even though `forge build` handles them transparently.
//
// Run: `node generate-abis.mjs` from `script-js/`, or `npm run gen:abi`.
// Drift guard: `npm run check:abi` (see script-js/README.md).

import solc from 'solc';
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SCRIPT_DIR, '..');
const OUT_FILE = resolve(ROOT, 'ui/src/lib/abi.generated.ts');

// ─── Contracts to compile ──────────────────────────────────────────────
// `export`  — the TS identifier this contract's ABI is written under, as
//              `export const <export>Abi = [...] as const;`
// `file`    — path relative to repo root.
// `contract` — the Solidity contract name inside that file (files can
//              declare more than one contract/interface/library).
//
// Kept in alphabetical-by-`export` order so re-ordering this list can't
// change the generated file's byte content by accident.
const CONTRACTS = [
  { export: 'ArtCoinsAirdrop', file: 'src/extensions/ArtCoinsAirdrop.sol', contract: 'ArtCoinsAirdrop' },
  { export: 'ArtCoinsFactory', file: 'src/ArtCoinsFactory.sol', contract: 'ArtCoinsFactory' },
  { export: 'ArtCoinsHook', file: 'src/hooks/ArtCoinsHook.sol', contract: 'ArtCoinsHook' },
  { export: 'ArtCoinsHookSkimFee', file: 'src/hooks/ArtCoinsHookSkimFee.sol', contract: 'ArtCoinsHookSkimFee' },
  { export: 'ArtCoinsHookStaticFee', file: 'src/hooks/ArtCoinsHookStaticFee.sol', contract: 'ArtCoinsHookStaticFee' },
  { export: 'ArtCoinsLpLocker', file: 'src/lp-lockers/ArtCoinsLpLocker.sol', contract: 'ArtCoinsLpLocker' },
  { export: 'ArtCoinsMevDescendingFees', file: 'src/mev-modules/ArtCoinsMevDescendingFees.sol', contract: 'ArtCoinsMevDescendingFees' },
  { export: 'ArtCoinsMevLinearFees', file: 'src/mev-modules/ArtCoinsMevLinearFees.sol', contract: 'ArtCoinsMevLinearFees' },
  { export: 'ArtCoinsMevTimeDelay', file: 'src/mev-modules/ArtCoinsMevTimeDelay.sol', contract: 'ArtCoinsMevTimeDelay' },
  { export: 'ArtCoinsToken', file: 'src/ArtCoinsToken.sol', contract: 'ArtCoinsToken' },
  // Uniswap v4-periphery lens contracts. These are NOT part of this repo's
  // src/, but compile cleanly and quickly standalone against this repo's
  // remappings, so we generate them rather than hand-write them. Contrast
  // with UniversalRouter/Permit2, which do NOT compile standalone here
  // (see ui/src/lib/abi.vendor.ts for why) and stay hand-written.
  { export: 'StateView', file: 'lib/v4-periphery/src/lens/StateView.sol', contract: 'StateView' },
  { export: 'V4Quoter', file: 'lib/v4-periphery/src/lens/V4Quoter.sol', contract: 'V4Quoter' },
];

// ─── Import resolution (remappings.txt + Foundry's implicit lib roots) ──
const remappings = readFileSync(join(ROOT, 'remappings.txt'), 'utf8')
  .trim()
  .split('\n')
  .filter(Boolean)
  .map((line) => {
    const eq = line.indexOf('=');
    return [line.slice(0, eq), line.slice(eq + 1)];
  });

const libRoots = new Map();
function indexLibRoots(dir, depth) {
  if (depth > 3 || !existsSync(dir)) return;
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (!statSync(full).isDirectory()) continue;
    if (!libRoots.has(entry)) libRoots.set(entry, full);
    indexLibRoots(join(full, 'lib'), depth + 1);
  }
}
indexLibRoots(join(ROOT, 'lib'), 0);

function resolveImport(importPath, parentFile) {
  for (const [prefix, target] of remappings) {
    if (importPath.startsWith(prefix)) return join(ROOT, target + importPath.slice(prefix.length));
  }
  if (importPath.startsWith('.') && parentFile) {
    return resolve(dirname(parentFile), importPath);
  }
  const firstSegment = importPath.split('/')[0];
  const rest = importPath.slice(firstSegment.length + 1);
  const root = libRoots.get(firstSegment);
  if (root) {
    for (const candidate of [join(root, rest), join(root, 'src', rest)]) {
      if (existsSync(candidate)) return candidate;
    }
  }
  return join(ROOT, importPath);
}

function findImports(importPath) {
  const resolved = resolveImport(importPath, null);
  if (!existsSync(resolved)) {
    return { error: `Source not found: ${importPath} -> ${resolved}` };
  }
  return { contents: readFileSync(resolved, 'utf8') };
}

// ─── Compile ────────────────────────────────────────────────────────────
const sources = {};
for (const { file } of CONTRACTS) {
  sources[file] = { content: readFileSync(join(ROOT, file), 'utf8') };
}

const input = {
  language: 'Solidity',
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: 'cancun',
    viaIR: false, // ABI output doesn't need it, and it's much slower.
    outputSelection: { '*': { '*': ['abi'] } },
  },
};

console.error(`Compiling ${CONTRACTS.length} contract(s) with solc ${solc.version()}...`);
const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));

const errors = (output.errors ?? []).filter((e) => e.severity === 'error');
if (errors.length > 0) {
  console.error(`\nsolc reported ${errors.length} error(s):\n`);
  for (const e of errors) console.error(e.formattedMessage ?? e.message);
  process.exit(1);
}
// Non-fatal warnings still get surfaced so they aren't silently swallowed.
const warnings = (output.errors ?? []).filter((e) => e.severity !== 'error');
for (const w of warnings) console.error(`warning: ${w.formattedMessage ?? w.message}`);

// ─── Extract ABIs ───────────────────────────────────────────────────────
const results = [];
for (const entry of CONTRACTS) {
  const compiled = output.contracts?.[entry.file]?.[entry.contract];
  if (!compiled) {
    console.error(
      `\nContract "${entry.contract}" not found in ${entry.file}. ` +
        `Available: ${Object.keys(output.contracts?.[entry.file] ?? {}).join(', ') || '(none)'}`
    );
    process.exit(1);
  }
  results.push({ ...entry, abi: compiled.abi });
}

// ─── Deterministic serialization ─────────────────────────────────────────
// solc's own key order is already stable for a given input, but we pin it
// explicitly (and drop `internalType`, which is Solidity-internal noise not
// needed by viem) so the output is stable across solc versions too.
const PARAM_KEYS = ['name', 'type', 'indexed', 'components'];
const ITEM_KEYS = ['type', 'name', 'inputs', 'outputs', 'stateMutability', 'anonymous'];

function cleanParam(p) {
  const out = {};
  for (const k of PARAM_KEYS) {
    if (k === 'components' && Array.isArray(p.components)) {
      out.components = p.components.map(cleanParam);
    } else if (k in p) {
      out[k] = p[k];
    }
  }
  return out;
}

function cleanItem(item) {
  const out = {};
  for (const k of ITEM_KEYS) {
    if (!(k in item)) continue;
    if ((k === 'inputs' || k === 'outputs') && Array.isArray(item[k])) {
      out[k] = item[k].map(cleanParam);
    } else {
      out[k] = item[k];
    }
  }
  return out;
}

function serialize(value, indent) {
  const pad = '  '.repeat(indent);
  const padIn = '  '.repeat(indent + 1);
  if (Array.isArray(value)) {
    if (value.length === 0) return '[]';
    const items = value.map((v) => padIn + serialize(v, indent + 1)).join(',\n');
    return `[\n${items},\n${pad}]`;
  }
  if (value !== null && typeof value === 'object') {
    const keys = Object.keys(value);
    if (keys.length === 0) return '{}';
    const items = keys
      .map((k) => `${padIn}${JSON.stringify(k)}: ${serialize(value[k], indent + 1)}`)
      .join(',\n');
    return `{\n${items},\n${pad}}`;
  }
  return JSON.stringify(value);
}

// ─── Emit ui/src/lib/abi.generated.ts ────────────────────────────────────
const header = `// AUTO-GENERATED by script-js/generate-abis.mjs — DO NOT EDIT BY HAND.
//
// Regenerate: \`cd script-js && node generate-abis.mjs\` (or \`npm run gen:abi\`).
// Drift check: \`cd script-js && npm run check:abi\`.
//
// Source of truth: the Solidity contracts in src/ (compiled with solc
// 0.8.26, matching foundry.toml), plus a couple of Uniswap v4-periphery
// lens contracts pulled from lib/ that compile cleanly standalone. See
// ui/src/lib/abi.vendor.ts for the periphery ABIs that stay hand-written
// because they do NOT compile standalone in this repo.
`;

const body = results
  .map(({ export: name, abi }) => `export const ${name}Abi = ${serialize(abi.map(cleanItem), 0)} as const;`)
  .join('\n\n');

writeFileSync(OUT_FILE, `${header}\n${body}\n`);
console.error(`\nWrote ${results.length} ABI(s) to ${OUT_FILE}`);
