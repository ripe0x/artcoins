/**
 * Build a merkle allowlist for a NewMaterialAirdropV2.
 *
 * Usage:
 *   npx tsx script-js/build-allowlist.ts <input.csv> <token-address> [--out <path>]
 *
 * Input CSV: two columns, no header — `address,amount`.
 *   - `address`: 0x-prefixed checksum or lowercase address
 *   - `amount`: whole token units (decimal string or number). Converted to wei at 18 decimals.
 *
 * Output: JSON file with the merkle root and per-entry proofs. Defaults to
 *   ui/public/allowlists/<token-address-lowercase>.json
 * so the claim page can fetch it directly.
 *
 * Also prints the merkle root to stdout — paste it into the airdrop form in the UI.
 */
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { parseUnits, getAddress, isAddress } from 'viem';
import type { Address } from 'viem';
import {
  buildAllowlistFile,
  type AllowlistEntry,
} from '../ui/src/lib/merkle.ts';

function usage(): never {
  process.stderr.write(
    'Usage: tsx script-js/build-allowlist.ts <input.csv> <token-address> [--out <path>]\n'
  );
  process.exit(1);
}

function parseCsv(text: string): AllowlistEntry[] {
  const entries: AllowlistEntry[] = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i].trim();
    if (!raw || raw.startsWith('#')) continue;
    const parts = raw.split(',').map(s => s.trim());
    if (parts.length < 2) {
      throw new Error(`CSV line ${i + 1}: expected "address,amount"; got "${raw}"`);
    }
    const [addrStr, amountStr] = parts;
    if (!isAddress(addrStr)) {
      throw new Error(`CSV line ${i + 1}: invalid address "${addrStr}"`);
    }
    const address = getAddress(addrStr);
    const amount = parseUnits(amountStr, 18).toString();
    entries.push({ address, amount });
  }
  if (entries.length === 0) throw new Error('No entries found in CSV');
  return entries;
}

function main() {
  const args = process.argv.slice(2);
  if (args.length < 2) usage();

  const [csvPath, tokenArg, ...rest] = args;
  if (!isAddress(tokenArg)) {
    process.stderr.write(`Invalid token address: ${tokenArg}\n`);
    process.exit(1);
  }
  const token = getAddress(tokenArg) as Address;

  let outPath: string | undefined;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--out') outPath = rest[i + 1];
  }
  if (!outPath) {
    outPath = resolve(
      import.meta.dirname,
      '..',
      'ui',
      'public',
      'allowlists',
      `${token.toLowerCase()}.json`
    );
  }

  const csvText = readFileSync(resolve(csvPath), 'utf8');
  const entries = parseCsv(csvText);
  const file = buildAllowlistFile(token, entries);

  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(file, null, 2) + '\n');

  process.stdout.write(
    `wrote ${file.entries.length} entries to ${outPath}\nroot: ${file.root}\n`
  );
}

main();
