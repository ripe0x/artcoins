/**
 * Generate compressed Mona Lisa candidates with size + gas-cost estimates
 * for ScriptyStorageV2 onchain storage. The "best looking under glyph
 * overlay" candidate becomes ll/mona.vN.
 *
 * Cost model (calibrated against the real on-chain mona.v1 upload at 5,788
 * bytes → 1,430,878 gas → ~247 gas/byte): we use 250 gas/byte for the chunk
 * payload, plus 55,000 gas per `addChunkToContent` call (one chunk fits up
 * to ~24 KB). The first-time `createContent` adds another 55,000 gas. We
 * report the totals at three plausible mainnet gas prices.
 *
 * Usage:  node script-js/compress-mona.mjs [--source path/to/source.png|.jpg]
 */

import sharp from "sharp";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "..");
const DEFAULT_SOURCE = "/Users/dd/Sites/liquidity-layer-node/web/monalisa.png";

const argv = process.argv.slice(2);
const sourceIdx = argv.indexOf("--source");
const SOURCE = sourceIdx >= 0 ? argv[sourceIdx + 1] : DEFAULT_SOURCE;

const OUT = path.resolve(ROOT, "script-js/data/ll/candidates");
fs.mkdirSync(OUT, { recursive: true });

// Real-on-chain calibration: 5788 bytes -> 1,430,878 gas → ~247 gas/byte.
const GAS_PER_BYTE = 250;
const GAS_PER_CALL = 55_000;
const CHUNK_LIMIT = 24 * 1024 - 64; // SSTORE2 ceiling

// Mainnet ETH prices to project against ($3500 was today-ish; show a range).
const ETH_USD = 3500;
const GAS_PRICES_GWEI = [1, 2, 5];

const candidates = [
  // (label, ext, width, sharp options)
  { label: "current (jpeg-q40-w256)", ext: "jpeg", width: 256, opts: { quality: 40, mozjpeg: true } },
  { label: "jpeg-q60-w384",            ext: "jpeg", width: 384, opts: { quality: 60, mozjpeg: true } },
  { label: "jpeg-q70-w384",            ext: "jpeg", width: 384, opts: { quality: 70, mozjpeg: true } },
  { label: "jpeg-q70-w512",            ext: "jpeg", width: 512, opts: { quality: 70, mozjpeg: true } },
  { label: "jpeg-q80-w512",            ext: "jpeg", width: 512, opts: { quality: 80, mozjpeg: true } },
  { label: "jpeg-q85-w508 (full size)",ext: "jpeg", width: 508, opts: { quality: 85, mozjpeg: true } },
  { label: "webp-q60-w384",            ext: "webp", width: 384, opts: { quality: 60 } },
  { label: "webp-q75-w512",            ext: "webp", width: 512, opts: { quality: 75 } },
  { label: "webp-q85-w508 (full size)",ext: "webp", width: 508, opts: { quality: 85 } },
  { label: "avif-q40-w384",            ext: "avif", width: 384, opts: { quality: 40 } },
  { label: "avif-q50-w512",            ext: "avif", width: 512, opts: { quality: 50 } },
  { label: "avif-q60-w508 (full size)",ext: "avif", width: 508, opts: { quality: 60 } },
  // ─── retina-native candidates (1016 wide = 508 logical × dpr=2) ───────
  { label: "jpeg-q75-w1016 (retina)",  ext: "jpeg", width: 1016, opts: { quality: 75, mozjpeg: true } },
  { label: "jpeg-q85-w1016 (retina)",  ext: "jpeg", width: 1016, opts: { quality: 85, mozjpeg: true } },
  { label: "webp-q75-w1016 (retina)",  ext: "webp", width: 1016, opts: { quality: 75 } },
  { label: "webp-q85-w1016 (retina)",  ext: "webp", width: 1016, opts: { quality: 85 } },
  { label: "avif-q50-w1016 (retina)",  ext: "avif", width: 1016, opts: { quality: 50 } },
  { label: "avif-q60-w1016 (retina)",  ext: "avif", width: 1016, opts: { quality: 60 } },
];

function gasFor(bytes) {
  const chunks = Math.ceil(bytes / CHUNK_LIMIT) || 1;
  // First time: createContent + N×addChunkToContent. (For a one-shot upload.)
  return GAS_PER_BYTE * bytes + GAS_PER_CALL * (chunks + 1);
}

function fmtUsd(n) { return "$" + n.toFixed(2); }
function fmtGas(g) { return (g / 1e6).toFixed(2) + "M"; }

async function main() {
  console.log(`source: ${SOURCE}`);
  const srcSize = fs.statSync(SOURCE).size;
  console.log(`        ${srcSize} bytes (${(srcSize/1024).toFixed(1)} KB)`);
  console.log();

  const rows = [];
  for (const c of candidates) {
    const buf = await sharp(SOURCE)
      .resize({ width: c.width })
      .toFormat(c.ext, c.opts)
      .toBuffer();

    const file = path.resolve(OUT, `${c.label.replace(/[^a-z0-9.-]+/gi, "_")}.${c.ext}`);
    fs.writeFileSync(file, buf);
    rows.push({ ...c, bytes: buf.length, file });
  }

  rows.sort((a, b) => a.bytes - b.bytes);

  // Render table
  const colLabel = Math.max(...rows.map(r => r.label.length), 8);
  const head = [
    "label".padEnd(colLabel),
    "bytes".padStart(7),
    "kb".padStart(7),
    "gas".padStart(8),
    ...GAS_PRICES_GWEI.map(p => `@${p}gwei`.padStart(11)),
    "chunks",
  ].join(" | ");
  console.log(head);
  console.log("-".repeat(head.length));

  for (const r of rows) {
    const gas = gasFor(r.bytes);
    const chunks = Math.ceil(r.bytes / CHUNK_LIMIT);
    const usdCells = GAS_PRICES_GWEI.map(p => {
      const usd = (gas * p * 1e-9 * ETH_USD);
      return fmtUsd(usd).padStart(11);
    });
    console.log([
      r.label.padEnd(colLabel),
      String(r.bytes).padStart(7),
      ((r.bytes / 1024).toFixed(1) + " KB").padStart(7),
      fmtGas(gas).padStart(8),
      ...usdCells,
      String(chunks).padStart(6),
    ].join(" | "));
  }
  console.log();
  console.log(`(USD = gas × gasPrice × ${ETH_USD} per ETH)`);
  console.log(`files: ${path.relative(ROOT, OUT)}/`);
}

main().catch((e) => { console.error(e); process.exit(1); });
