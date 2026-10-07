#!/usr/bin/env node
// Writes the keeper runner abis from the foundry artifacts. Run after
//   /tmp/claude-0/forge.sh build --skip "test/**" --skip script     (or: forge build --skip "test/**" --skip script)
// Usage: node scripts/gen-abi.mjs [--out-dir ../foundry-out] [--check]
// Outputs (committed): abi/CollectFlushKeeperV1.json, abi/CollectFlushKeeperLayer.json, abi/ArtCoinsKeeperV2.json
// (full contract abi minus the constructor) and abi/reasons.json (custom errors of every contract a keeper
// calls, used to decode the `reason` bytes of FlushSkipped, ConvertSkipped and StepSkipped). --check exits 1
// when a committed file differs from what the artifacts give.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { toFunctionSelector, toEventSelector, formatAbiItem, parseAbiItem } from 'viem/utils';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const argv = process.argv.slice(2);
const outDir = argv.includes('--out-dir') ? path.resolve(argv[argv.indexOf('--out-dir') + 1]) : path.join(ROOT, 'foundry-out');
const check = argv.includes('--check');
const ABI_DIR = path.resolve(HERE, '..', 'abi');

const KEEPERS = [
  ['CollectFlushKeeperV1', 'CollectFlushKeeperV1.sol/CollectFlushKeeperV1.json'],
  ['CollectFlushKeeperLayer', 'CollectFlushKeeperLayer.sol/CollectFlushKeeperLayer.json'],
  ['ArtCoinsKeeperV2', 'ArtCoinsKeeperV2.sol/ArtCoinsKeeperV2.json'],
];
// contracts whose reverts a keeper reports as reason bytes (swappers, routers, fee lockers, lockers, escrows)
const REASON_SOURCES = [
  'FeeAutoSwapper.sol/FeeAutoSwapper.json',
  'FeeAutoSwapperV2.sol/FeeAutoSwapperV2.json',
  'legacy/BurnRouter.sol/BurnRouter.json',
  'BurnRouter.sol/BurnRouter.json',
  'ArtCoinsFeeLocker.sol/ArtCoinsFeeLocker.json',
  'legacy/ProtocolFeeController.sol/ProtocolFeeController.json',
  'ProtocolFeeController.sol/ProtocolFeeController.json',
];

// reverts that come from outside this repo's artifacts (universal router v4 swaps inside the burn routers)
const EXTRA = ['error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived)'];

const read = (rel) => {
  const p = path.join(outDir, rel);
  if (!fs.existsSync(p)) throw new Error(`missing artifact ${p}: build first (forge build --skip "test/**" --skip script)`);
  return JSON.parse(fs.readFileSync(p, 'utf8')).abi;
};
const sig = (item) => formatAbiItem(item);
const files = {};
for (const [name, rel] of KEEPERS) {
  const abi = read(rel).filter((i) => i.type !== 'constructor');
  files[`${name}.json`] = abi;
}
const seen = new Map();
for (const rel of REASON_SOURCES) {
  let abi;
  try { abi = read(rel); } catch (e) { console.error('gen-abi: skip ' + rel + ' (' + e.message + ')'); continue; }
  for (const i of abi.filter((x) => x.type === 'error')) {
    const s = toFunctionSelector(sig(i));
    if (!seen.has(s)) seen.set(s, i);
  }
}
for (const e of EXTRA.map((x) => parseAbiItem(x))) {
  const s = toFunctionSelector(sig(e));
  if (!seen.has(s)) seen.set(s, e);
}
files['reasons.json'] = [...seen.values()].sort((a, b) => sig(a).localeCompare(sig(b)));

let drift = 0;
fs.mkdirSync(ABI_DIR, { recursive: true });
for (const [f, abi] of Object.entries(files)) {
  const text = JSON.stringify(abi, null, 2) + '\n';
  const p = path.join(ABI_DIR, f);
  if (check) {
    if (!fs.existsSync(p) || fs.readFileSync(p, 'utf8') !== text) { console.error('gen-abi: drift in abi/' + f); drift++; }
    continue;
  }
  fs.writeFileSync(p, text);
  const ev = abi.filter((i) => i.type === 'event').map((i) => `${i.name} ${toEventSelector(sig(i)).slice(0, 10)}`);
  console.log(`abi/${f}: ${abi.length} items${ev.length ? ', events ' + ev.join(', ') : ''}`);
}
process.exit(drift ? 1 : 0);
