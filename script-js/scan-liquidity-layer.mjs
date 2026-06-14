/**
 * Scan the LiquidityLayerMigrationDeposit contract on Base for Deposited events
 * and aggregate per-recipient totals.
 *
 * Usage (must resolve `viem` — run from ui/ or any node_modules scope that has it):
 *   cd ui && node ../script-js/scan-liquidity-layer.mjs [--rpc <url>]
 *
 * Outputs:
 *   script-js/data/liquidity-layer-depositors.csv   — address,amountInWholeTokens
 *   script-js/data/liquidity-layer-depositors.json  — address + wei-accurate amount
 *
 * The CSV is directly consumable by `build-allowlist.ts`.
 */
import { createPublicClient, http, parseAbiItem, getAddress, formatUnits } from 'viem';
import { base } from 'viem/chains';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
let rpc = process.env.BASE_RPC || 'https://mainnet.base.org';
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--rpc') rpc = args[i + 1];
}

const ADDR = '0x6B19a430281b5ACbcBC925E3c1A50802968A4daC';
const EVENT = parseAbiItem(
  'event Deposited(address indexed depositor, address indexed recipient, uint256 amount)'
);

const client = createPublicClient({ chain: base, transport: http(rpc) });

async function findDeployBlock() {
  let lo = 1n;
  let hi = await client.getBlockNumber();
  const headCode = await client.getCode({ address: ADDR, blockNumber: hi });
  if (!headCode || headCode === '0x') throw new Error('No code at head');
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const code = await client.getCode({ address: ADDR, blockNumber: mid });
    if (!code || code === '0x') lo = mid + 1n;
    else hi = mid;
  }
  return lo;
}

const deployBlock = await findDeployBlock();
const head = await client.getBlockNumber();
process.stderr.write(`deploy block ${deployBlock}, head ${head}\n`);

const CHUNK = 9500n;
let all = [];
for (let from = deployBlock; from <= head; from += CHUNK + 1n) {
  const to = from + CHUNK > head ? head : from + CHUNK;
  let tries = 0;
  while (true) {
    try {
      const logs = await client.getLogs({
        address: ADDR,
        event: EVENT,
        fromBlock: from,
        toBlock: to,
      });
      all = all.concat(logs);
      break;
    } catch (e) {
      tries++;
      if (tries > 4) throw e;
      await new Promise(r => setTimeout(r, 500 * tries));
    }
  }
}

const totals = new Map();
for (const log of all) {
  const recipient = getAddress(log.args.recipient);
  totals.set(recipient, (totals.get(recipient) ?? 0n) + log.args.amount);
}

const entries = [...totals.entries()].sort((a, b) =>
  b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0
);
const totalWei = entries.reduce((acc, [, v]) => acc + v, 0n);

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, 'data');
mkdirSync(outDir, { recursive: true });

const csvPath = resolve(outDir, 'liquidity-layer-depositors.csv');
writeFileSync(
  csvPath,
  entries.map(([a, w]) => `${a},${formatUnits(w, 18)}`).join('\n') + '\n'
);

const jsonPath = resolve(outDir, 'liquidity-layer-depositors.json');
writeFileSync(
  jsonPath,
  JSON.stringify(
    entries.map(([address, wei]) => ({ address, amountWei: wei.toString() })),
    null,
    2
  )
);

process.stderr.write(
  `events: ${all.length}\nunique recipients: ${entries.length}\ntotal: ${formatUnits(totalWei, 18)}\nwrote ${csvPath}\nwrote ${jsonPath}\n`
);
