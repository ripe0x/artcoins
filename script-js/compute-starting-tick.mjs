#!/usr/bin/env node
/**
 * Compute the starting tick for an art-coin launch from a target FDV.
 *
 * Background
 * ----------
 * Uniswap v4 prices are token1/token0 in raw units. Both ArtCoinsToken and
 * WETH have 18 decimals, so the raw price ratio equals the human-readable
 * price ratio. The factory accepts `tickIfToken0IsArtCoins` — i.e. "the
 * tick you would use if your token were token0". The hook/locker handles
 * the negation when WETH actually sorts into slot 0, so this calculator
 * only needs to *report* the actual sort order; the on-chain code adapts.
 *
 * Math
 * ----
 *   priceArtCoinInETH = targetFdvUsd / (totalSupply * ethUsd)
 *   tickIfToken0IsArtCoin = floor( log(priceArtCoinInETH) / log(1.0001) )
 *
 * Then we round to the nearest multiple of tickSpacing, recompute the
 * implied FDV, and emit the four absolute LP ranges using the offsets
 * from `script/LaunchDefaults.sol`.
 *
 * Usage
 * -----
 *   node script-js/compute-starting-tick.mjs \
 *     --token 0xCoin... \
 *     --weth  0xWeth... \
 *     --fdv-usd 10000 \
 *     --supply 1000000000 \
 *     --eth-usd 3000 \
 *     [--tick-spacing 200]
 *
 * All flags are required except --tick-spacing (defaults to 200).
 */

const args = parseArgs(process.argv.slice(2));

const tokenAddress  = req(args, 'token');
const wethAddress   = req(args, 'weth');
const targetFdvUsd  = num(req(args, 'fdv-usd'),  'fdv-usd');
const totalSupply   = num(req(args, 'supply'),   'supply');
const ethUsd        = num(req(args, 'eth-usd'),  'eth-usd');
const tickSpacing   = num(args['tick-spacing'] ?? '200', 'tick-spacing');

if (tickSpacing <= 0 || !Number.isInteger(tickSpacing)) {
  fail(`tick-spacing must be a positive integer (got ${tickSpacing})`);
}
if (targetFdvUsd <= 0) fail('fdv-usd must be > 0');
if (totalSupply <= 0)  fail('supply must be > 0');
if (ethUsd <= 0)       fail('eth-usd must be > 0');

const a = tokenAddress.toLowerCase();
const w = wethAddress.toLowerCase();
if (!/^0x[0-9a-f]{40}$/.test(a)) fail(`invalid token address: ${tokenAddress}`);
if (!/^0x[0-9a-f]{40}$/.test(w)) fail(`invalid weth address:  ${wethAddress}`);
if (a === w) fail('token and weth addresses are equal');

// Sort order: currency0 = lower address.
const tokenIsToken0 = a < w;
const token0 = tokenIsToken0 ? tokenAddress : wethAddress;
const token1 = tokenIsToken0 ? wethAddress : tokenAddress;

// Price of one ArtCoin denominated in WETH. Both 18 decimals, so the human
// ratio matches the raw token ratio.
const priceArtCoinInWeth = targetFdvUsd / (totalSupply * ethUsd);

// "tick if token0 is artCoin" — the value the factory accepts.
const rawTick = Math.log(priceArtCoinInWeth) / Math.log(1.0001);
const startingTick = roundToMultiple(rawTick, tickSpacing);

if (startingTick % tickSpacing !== 0) {
  fail(`internal error: startingTick ${startingTick} not aligned to ${tickSpacing}`);
}

// Recompute the implied FDV from the rounded tick.
const roundedPrice = Math.pow(1.0001, startingTick);
const computedFdvUsd = roundedPrice * totalSupply * ethUsd;

// 4-position preset (mirrors script/LaunchDefaults.sol).
const PRESET = [
  { role: 'launch zone', lower: 0,     upper: 16400,  bps: 1000 },
  { role: 'main growth', lower: 16400, upper: 75400,  bps: 6000 },
  { role: 'maturity',    lower: 75400, upper: 89400,  bps: 2000 },
  { role: 'moon tail',   lower: 89400, upper: 110400, bps: 1000 },
];

const positions = PRESET.map(p => {
  const tickLower = startingTick + p.lower;
  const tickUpper = startingTick + p.upper;
  return {
    role: p.role,
    tickLower,
    tickUpper,
    bps: p.bps,
    // FDV at each band's lower / upper edge (artCoin gets more expensive
    // as tick rises, since price = WETH/artCoin).
    fdvAtLowerUsd: Math.pow(1.0001, tickLower) * totalSupply * ethUsd,
    fdvAtUpperUsd: Math.pow(1.0001, tickUpper) * totalSupply * ethUsd,
  };
});

console.log('=== Starting tick calculation ===');
console.log(`token:           ${tokenAddress}`);
console.log(`weth:            ${wethAddress}`);
console.log(`token0:          ${token0} ${tokenIsToken0 ? '(token)' : '(weth)'}`);
console.log(`token1:          ${token1} ${tokenIsToken0 ? '(weth)' : '(token)'}`);
console.log(`target FDV:      $${fmtUsd(targetFdvUsd)}`);
console.log(`supply:          ${totalSupply.toLocaleString()} tokens (18 decimals)`);
console.log(`eth/usd:         $${fmtUsd(ethUsd)}`);
console.log(`tickSpacing:     ${tickSpacing}`);
console.log('');
console.log(`raw tick:        ${rawTick.toFixed(4)}`);
console.log(`rounded tick:    ${startingTick}  (= tickIfToken0IsArtCoins)`);
console.log(`implied FDV:     $${fmtUsd(computedFdvUsd)}  (drift: ${fmtPct((computedFdvUsd - targetFdvUsd) / targetFdvUsd)})`);
console.log('');
console.log('LP ranges (absolute ticks if artCoin is token0):');
console.log('  role         tickLower    tickUpper    bps    FDV band');
for (const p of positions) {
  const range = `$${fmtUsd(p.fdvAtLowerUsd)} → $${fmtUsd(p.fdvAtUpperUsd)}`;
  console.log(
    `  ${p.role.padEnd(13)}` +
    `${String(p.tickLower).padStart(8)}     ` +
    `${String(p.tickUpper).padStart(8)}    ` +
    `${String(p.bps).padStart(5)}  ` +
    range
  );
}
if (!tokenIsToken0) {
  console.log('');
  console.log('Note: WETH is token0 in this pool. The on-chain hook/locker');
  console.log('      negates ticks automatically — pass the "if token0 is');
  console.log(`      artCoin" tick (${startingTick}) to the factory unchanged.`);
}

// ───────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const k = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[k] = 'true';
    } else {
      out[k] = next;
      i++;
    }
  }
  return out;
}

function req(args, key) {
  if (args[key] === undefined) fail(`missing --${key}`);
  return args[key];
}

function num(s, name) {
  const n = Number(s);
  if (!Number.isFinite(n)) fail(`--${name} must be a number (got ${s})`);
  return n;
}

function roundToMultiple(value, multiple) {
  // Banker's-style: round to nearest, ties go down (negative-friendly).
  return Math.round(value / multiple) * multiple;
}

function fmtUsd(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(2) + 'k';
  if (n >= 1)   return n.toFixed(2);
  return n.toExponential(3);
}

function fmtPct(x) {
  return (x * 100).toFixed(3) + '%';
}

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}
