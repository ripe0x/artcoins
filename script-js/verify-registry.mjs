#!/usr/bin/env node
// Verifies deployments/mainnet.json against the chain and the local foundry artifacts.
//   node script-js/verify-registry.mjs [--shape] [--fill] [--update-blocks] [--require-artifacts]
//        [--file deployments/mainnet.json] [--artifacts foundry-out,out/ci]
// --shape: schema check only, no rpc. A stack with status "planned" (not deployed yet, e.g. the v2 skeleton
// in deployments/v2.template.json) may hold null addresses and dates; it passes the schema and is skipped by
// every chain and bytecode check. --fill: write discovered values back (owner, state, bytecodeMatch,
// coin fields, commit). --update-blocks: re-derive deployBlock/deployedAt by bisecting eth_getCode (archive rpc).
// Exit 1 on drift, 2 on rpc/runtime errors. Missing artifacts are reported as UNCHECKED (never a silent pass); with
// --require-artifacts they fail. Env: MAINNET_RPC_URL (default: tenderly public gateway).
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { createPublicClient, http, getAddress, isAddress, parseAbi, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';

const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => (argv.includes(n) ? argv[argv.indexOf(n) + 1] : d);
const FILE = opt('--file', 'deployments/mainnet.json');
const DIRS = opt('--artifacts', 'foundry-out,out/ci').split(',').filter(Boolean);
const URL = process.env.MAINNET_RPC_URL || 'https://mainnet.gateway.tenderly.co';
const ZERO = '0x0000000000000000000000000000000000000000';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const eq = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const git = (c) => { try { return execSync('git ' + c, { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim(); } catch { return null; } };
process.on('uncaughtException', (e) => { console.error('rpc/runtime error (exit 2, not drift): ' + (e.shortMessage || e.message)); process.exit(2); });
const reg = JSON.parse(fs.readFileSync(FILE, 'utf8'));

// ---------- schema ----------
const ROLES = 'factory hook locker escrow mevModule extension renderer allowlist controller swapper router token other'.split(' ');
const addr = (v, nul) => (nul && v === null) || (typeof v === 'string' && isAddress(v, { strict: false }));
const hash = (v) => v === null || /^0x[0-9a-f]{64}$/.test(v);
const date = (v) => v === null || /^\d{4}-\d\d-\d\d$/.test(v);
const int = (v) => v === null || Number.isInteger(v);
function shape(r) {
  const e = [];
  const need = (ok, m) => { if (!ok) e.push(m); };
  const keys = (o, ks, w) => { need(o && typeof o === 'object' && Object.keys(o).sort().join() === [...ks].sort().join(), `${w}: keys must be exactly ${ks.join(',')}`); };
  keys(r, ['chainId', 'generatedAt', 'repoCommit', 'owner', 'stacks', 'contracts', 'coins'], 'root');
  need(r.chainId === 1, 'chainId must be 1'); need(addr(r.owner), 'owner address'); need(/^[0-9a-f]{40}$/.test(r.repoCommit), 'repoCommit sha');
  const planned = (id) => r.stacks?.[id]?.status === 'planned';
  for (const [id, s] of Object.entries(r.stacks || {})) {
    keys(s, ['label', 'status', 'factory', 'deployedAt', 'notes'], `stack ${id}`);
    need(['current', 'superseded', 'legacy', 'planned'].includes(s.status) && addr(s.factory, planned(id)) && date(s.deployedAt), `stack ${id} values`);
  }
  const seen = new Set();
  for (const c of r.contracts || []) {
    const w = `contract ${c.name}@${String(c.address).slice(0, 8)}`;
    keys(c, ['name', 'address', 'stack', 'role', 'deployBlock', 'deployTxHash', 'deployedAt', 'deployer', 'source', 'etherscanVerified', 'owner', 'state', 'status', 'provenance', 'chainVerified', 'notes'], w);
    keys(c.source, ['repoPath', 'commit', 'bytecodeMatch'], w + ' source');
    const pl = planned(c.stack); need(pl ? c.status === 'planned' : c.status !== 'planned', w + ' planned only in a planned stack');
    need(addr(c.address, pl) && (c.address === null || !seen.has(String(c.address).toLowerCase())), w + ' address unique'); if (c.address !== null) seen.add(String(c.address).toLowerCase());
    need(r.stacks?.[c.stack] && ROLES.includes(c.role), w + ' stack/role');
    need(int(c.deployBlock) && hash(c.deployTxHash) && date(c.deployedAt) && addr(c.deployer, true) && addr(c.owner, true), w + ' deploy fields');
    need(['yes', 'no', 'unknown'].includes(c.etherscanVerified) && ['enabled', 'deprecated', 'unknown'].includes(c.state), w + ' enums');
    need(['current', 'superseded', 'legacy', 'planned'].includes(c.status) && ['chain', 'broadcast', 'brief', 'planned'].includes(c.provenance) && typeof c.chainVerified === 'boolean', w + ' enums2');
    need(['verified', 'unverified', 'mismatch'].includes(c.source?.bytecodeMatch) && (c.source?.repoPath === null || /^src\//.test(c.source.repoPath)), w + ' source');
  }
  for (const [id, s] of Object.entries(r.stacks || {})) need(planned(id) || (r.contracts || []).some((c) => c.role === 'factory' && c.stack === id && eq(c.address, s.factory)), `stack ${id} factory is a contract entry`);
  const seenCoin = new Set();
  for (const k of r.coins || []) {
    const w = `coin ${k.symbol}`;
    keys(k, ['symbol', 'name', 'address', 'stack', 'factory', 'launchTxHash', 'launchBlock', 'pool', 'provenance', 'chainVerified'], w);
    keys(k.pool, ['hook', 'pairedToken', 'fee', 'tickSpacing'], w + ' pool');
    need(addr(k.address) && addr(k.factory) && addr(k.pool?.hook) && addr(k.pool?.pairedToken, true) && hash(k.launchTxHash) && int(k.launchBlock) && r.stacks?.[k.stack], w + ' values');
    need(!seenCoin.has(String(k.address).toLowerCase()), w + ' unique'); seenCoin.add(String(k.address).toLowerCase());
  }
  return e;
}
const shapeErrors = shape(reg);
if (shapeErrors.length) { console.error('SCHEMA ERRORS\n' + shapeErrors.map((x) => ' - ' + x).join('\n')); process.exit(1); }
if (flag('--shape')) { console.log(`schema ok: ${reg.contracts.length} contracts, ${reg.coins.length} coins, ${Object.keys(reg.stacks).length} stacks`); process.exit(0); }

// ---------- bytecode ----------
function* walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) yield* walk(p); else if (e.name.endsWith('.json') && !e.name.endsWith('.dbg.json')) yield p; } }
const index = {}; const missingDirs = [];
for (const d of DIRS) {
  if (!fs.existsSync(d)) { missingDirs.push(d); continue; }
  for (const p of walk(d)) {
    let j; try { j = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { continue; }
    const ct = j.metadata?.settings?.compilationTarget; const o = j.deployedBytecode?.object;
    if (!ct || !o || o === '0x') continue;
    const [src, name] = Object.entries(ct)[0];
    (index[src] ||= []).push({ name, d, runs: j.metadata.settings.optimizer?.runs, hex: o.slice(2).replace(/__\$[0-9a-f]{34}\$__/g, '0'.repeat(40)),
      masks: [...Object.values(j.deployedBytecode.immutableReferences || {}).flat(), ...Object.values(j.deployedBytecode.linkReferences || {}).flatMap((f) => Object.values(f).flat())] });
  }
}
function stripCbor(b) { // trailing solidity metadata: cbor map + 2 byte length
  if (b.length < 3) return b; const n = (b[b.length - 2] << 8) | b[b.length - 1]; const st = b.length - 2 - n;
  return n > 0 && n <= 120 && st >= 0 && b[st] >= 0xa1 && b[st] <= 0xa6 ? b.subarray(0, st) : b;
}
const MPRE = Buffer.from('a2646970667358221220', 'hex'); // cbor prefix of an ipfs metadata hash (32 bytes follow)
const metaAt = (b) => { const o = []; for (let i = b.indexOf(MPRE); i >= 0; i = b.indexOf(MPRE, i + 1)) o.push(i + MPRE.length); return o; };
// exact compare modulo: immutables, library link slots, and metadata hashes. an artifact built without metadata
// is compared against the chain code with its trailing metadata (and the 0xfe before it) removed.
function compare(chainHex, a) {
  let c = Buffer.from(chainHex.slice(2), 'hex'); const b = Buffer.from(a.hex, 'hex'); const bm = metaAt(b);
  if (!bm.length) { c = stripCbor(c); if (c.length === b.length + 1 && c[c.length - 1] === 0xfe) c = c.subarray(0, c.length - 1); }
  const mask = new Uint8Array(Math.max(c.length, b.length));
  for (const r of a.masks) mask.fill(1, r.start, r.start + r.length);
  for (const o of [...bm, ...metaAt(c)]) mask.fill(1, o, o + 32);
  const n = Math.min(c.length, b.length);
  for (let i = 0; i < n; i++) if (!mask[i] && c[i] !== b[i]) return { ok: false, at: i, lc: c.length, lb: b.length };
  return c.length === b.length ? { ok: true } : { ok: false, at: n, lc: c.length, lb: b.length };
}
function bytecode(c, code) {
  const rp = c.source.repoPath; if (!rp) return { m: 'unverified', d: 'no repoPath' };
  let cands = index[rp] || []; const base = path.basename(rp, '.sol');
  cands = cands.filter((x) => x.name === base).length ? cands.filter((x) => x.name === base) : cands.length === 1 ? cands : [];
  if (!cands.length) return { m: 'unchecked', d: 'artifact missing' };
  let best = null;
  for (const a of cands) { const r = compare(code, a); if (r.ok) return { m: 'verified', d: `${a.d} runs=${a.runs}` }; if (!best || r.at > best.r.at) best = { r, a }; }
  return { m: 'mismatch', d: `first diff @${best.r.at} (chain ${best.r.lc} vs artifact ${best.r.lb}, ${best.a.d} runs=${best.a.runs})` };
}

// ---------- chain reads ----------
const client = createPublicClient({ chain: mainnet, transport: http(URL, { batch: { wait: 20 }, retryCount: 6, retryDelay: 1500, timeout: 60000 }) });
const A = (s) => parseAbi(['function ' + s]);
const ABI = {
  owner: A('owner() view returns (address)'), deprecated: A('deprecated() view returns (bool)'), name: A('name() view returns (string)'), symbol: A('symbol() view returns (string)'),
  enabledHooks: A('enabledHooks(address) view returns (bool)'), enabledMevModules: A('enabledMevModules(address) view returns (bool)'), enabledExtensions: A('enabledExtensions(address) view returns (bool)'),
  enabledLockers: A('enabledLockers(address,address) view returns (bool)'), allowedDepositors: A('allowedDepositors(address) view returns (bool)'), isDepositor: A('isDepositor(address) view returns (bool)'),
  tokenRewards: A('tokenRewards(address) view returns ((address token,(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,uint256 positionId,uint256 numPositions,uint16[] rewardBps,address[] rewardAdmins,address[] rewardRecipients))'),
};
for (const g of ['factory', 'feeLocker', 'feeEscrow', 'hook', 'burnRouter', 'poolExtensionAllowlist']) ABI[g] = A(`${g}() view returns (address)`);
const getters = { hook: ['factory', 'feeEscrow', 'poolExtensionAllowlist'], locker: ['factory', 'feeLocker'], extension: ['factory', 'hook', 'feeLocker', 'burnRouter'], swapper: ['hook', 'feeLocker'], controller: ['burnRouter'] };
const calls = []; const keyOf = new Map();
function rd(fn, address, args = []) { const k = `${fn}|${address}|${args.join()}`; if (!keyOf.has(k)) { keyOf.set(k, calls.length); calls.push({ address, abi: ABI[fn], functionName: fn, args }); } return k; }
const isPlanned = (id) => reg.stacks[id]?.status === 'planned';
const C = reg.contracts.filter((c) => !isPlanned(c.stack)); const inStack = (s, role) => C.filter((c) => c.stack === s && c.role === role);
const stackFactory = (s) => reg.stacks[s].factory;
const plan = [];  // { c, kind, key, exp?, set? }
for (const c of C) {
  const a = c.address;
  plan.push({ c, kind: 'owner', key: rd('owner', a), exp: c.owner });
  if (c.role === 'factory') plan.push({ c, kind: 'state', key: rd('deprecated', a) });
  const sf = stackFactory(c.stack);
  if (c.role === 'hook') plan.push({ c, kind: 'state', key: rd('enabledHooks', sf, [a]) });
  if (c.role === 'mevModule') plan.push({ c, kind: 'state', key: rd('enabledMevModules', sf, [a]) });
  if (c.role === 'locker') plan.push({ c, kind: 'state', keys: inStack(c.stack, 'hook').map((h) => rd('enabledLockers', sf, [a, h.address])) });
  if (c.role === 'extension') plan.push({ c, kind: 'state', keys: [rd('enabledExtensions', sf, [a]), ...C.filter((x) => x.role === 'allowlist').map((al) => rd('enabledExtensions', al.address, [a]))] });
  const set = (g) => ({ factory: [sf], feeLocker: inStack(c.stack, 'escrow').map((x) => x.address), feeEscrow: inStack(c.stack, 'escrow').map((x) => x.address), hook: inStack(c.stack, 'hook').map((x) => x.address),
    burnRouter: inStack(c.stack, 'router').map((x) => x.address), poolExtensionAllowlist: C.filter((x) => x.role === 'allowlist').map((x) => x.address) }[g]);
  for (const g of getters[c.role] || []) plan.push({ c, kind: 'link:' + g, key: rd(g, a), set: set(g), optional: true });
  // v1 escrows answer allowedDepositors, v2 escrows isDepositor: either one true passes
  if (c.role === 'escrow') for (const x of [...inStack(c.stack, 'locker'), ...inStack(c.stack, 'hook')]) plan.push({ c, kind: 'depositor:' + x.name, key: rd('allowedDepositors', a, [x.address]), key2: rd('isDepositor', a, [x.address]), exp: true, hookOnlyIfLinked: x.role === 'hook' ? x.address : null });
}
for (const k of reg.coins) {
  plan.push({ c: k, kind: 'coin:name', key: rd('name', k.address), exp: k.name }, { c: k, kind: 'coin:symbol', key: rd('symbol', k.address), exp: k.symbol });
  for (const l of inStack(k.stack, 'locker')) rd('tokenRewards', l.address, [k.address]);
}

async function chunked(items, n, fn) { const out = []; for (let i = 0; i < items.length; i += n) { out.push(...(await fn(items.slice(i, i + n)))); await sleep(400); } return out; }
const chainId = await client.getChainId(); if (chainId !== 1) { console.error('rpc chain id ' + chainId); process.exit(1); }
const head = await client.getBlockNumber();
const codes = await chunked(C, 6, (cs) => Promise.all(cs.map((c) => client.getCode({ address: c.address }))));
const res = await chunked(calls, 40, (cs) => client.multicall({ contracts: cs, allowFailure: true, batchSize: 0 }));
const R = (k) => res[keyOf.get(k)];
const val = (k) => (R(k).status === 'success' ? R(k).result : undefined);
const fails = []; const rows = []; const warn = [];
const fail = (who, what, exp, got) => fails.push({ who, what, exp: String(exp), got: String(got) });
const drift = { owner: new Map(), state: new Map(), match: new Map() };

for (let i = 0; i < C.length; i++) {
  const c = C[i]; const who = `${c.name} ${c.address.slice(0, 8)}`; const code = codes[i]; const row = { c, code: 'ok', owner: 'n/a', state: 'n/a', bc: 'n/a', wiring: 'ok' };
  rows.push(row);
  if (!code || code === '0x') { row.code = 'NONE'; fail(who, 'code exists', 'yes', 'no code'); continue; }
  const bc = bytecode(c, code); row.bc = bc.m; row.bcDetail = bc.d;
  const reg_ = c.source.bytecodeMatch; let now = bc.m;
  if (now === 'unchecked') { warn.push(`${who}: UNCHECKED, ${bc.d} (registry says ${reg_})`); if (flag('--require-artifacts') && reg_ !== 'unverified') fail(who, 'artifact present', 'yes', 'missing'); now = reg_; }
  else if (now === 'mismatch' && reg_ === 'verified' && missingDirs.length) { warn.push(`${who}: UNCHECKED, artifact dir(s) missing: ${missingDirs.join(',')}`); now = reg_; }
  if (now !== reg_) fail(who, 'bytecodeMatch', reg_, `${now} (${bc.d})`);
  drift.match.set(c, { m: now, d: bc.d });
  for (const p of plan.filter((x) => x.c === c)) {
    const label = p.kind;
    if (p.kind === 'state') {
      const vs = p.keys ? p.keys.map(val) : [val(p.key)];
      let want = 'unknown';
      if (c.role === 'factory') want = vs[0] === undefined ? 'unknown' : vs[0] ? 'deprecated' : 'enabled';
      else if (vs.some((v) => v === true)) want = 'enabled'; else if (vs.every((v) => v === false)) want = 'deprecated';
      row.state = want; drift.state.set(c, want);
      if (want !== c.state) fail(who, 'state', c.state, want);
    } else if (p.kind === 'owner') {
      const v = val(p.key); drift.owner.set(c, v ?? null);
      row.owner = !v ? (p.exp ? 'DRIFT' : 'n/a') : p.exp && eq(v, p.exp) ? 'ok' : 'DRIFT';
      if (row.owner === 'DRIFT') fail(who, 'owner()', p.exp ?? 'none (no getter)', v ?? 'reverted');
    } else if (p.kind.startsWith('link:')) {
      const v = val(p.key); if (v === undefined) continue; // getter absent on this contract: not wiring
      if (!p.set.some((s) => eq(s, v))) { row.wiring = 'DRIFT'; fail(who, p.kind.slice(5) + '()', p.set.join('|') || 'none registered', v); }
    } else if (p.kind.startsWith('depositor:')) {
      const v = val(p.key) === true || val(p.key2) === true ? true : val(p.key);
      if (p.hookOnlyIfLinked && !plan.some((q) => q.c === C.find((x) => eq(x.address, p.hookOnlyIfLinked)) && q.kind === 'link:feeEscrow' && val(q.key) && eq(val(q.key), c.address))) continue;
      if (v !== true) { row.wiring = 'DRIFT'; fail(who, `allowedDepositors(${p.kind.slice(10)})`, true, v); }
    }
  }
}

// coins: name/symbol (plan), pool key from the stack locker, and completeness against the factory's TokenCreated logs
const ev = parseAbiItem('event TokenCreated(address msgSender, address indexed tokenAddress, address indexed tokenAdmin, string tokenImage, string tokenName, string tokenSymbol, string tokenMetadata, string tokenContext, int24 startingTick, address poolHook, bytes32 poolId, address pairedToken, address locker, address mevModule, uint256 extensionsSupply, address[] extensions)');
const coinRows = [];
for (const k of reg.coins) {
  const who = `coin ${k.symbol}`; const row = { k, ok: 'ok' }; coinRows.push(row);
  for (const p of plan.filter((x) => x.c === k)) { const v = val(p.key); if (v !== p.exp) { row.ok = 'DRIFT'; fail(who, p.kind, p.exp, v ?? 'reverted'); } }
  let tr; for (const l of inStack(k.stack, 'locker')) { const v = val(rd('tokenRewards', l.address, [k.address])); if (v && eq(v.token, k.address)) tr = v; }
  if (!tr) { row.ok = 'DRIFT'; fail(who, 'locker tokenRewards', 'found', 'none'); continue; }
  const pk = tr.poolKey; const paired = eq(pk.currency0, k.address) ? pk.currency1 : pk.currency0; const got = { hook: pk.hooks, pairedToken: eq(paired, ZERO) ? null : paired, fee: pk.fee, tickSpacing: pk.tickSpacing };
  for (const f of Object.keys(got)) { const w = k.pool[f]; if (!(w === null ? got[f] === null : eq(w, got[f]))) { row.ok = 'DRIFT'; fail(who, 'pool.' + f, w, got[f]); } }
  row.pool = got;
}
const fromBlock = (s) => BigInt(C.find((c) => c.role === 'factory' && c.stack === s).deployBlock);
for (const s of Object.keys(reg.stacks).filter((id) => !isPlanned(id))) {
  const logs = await client.getLogs({ address: stackFactory(s), event: ev, fromBlock: fromBlock(s), toBlock: head });
  const onchain = logs.map((l) => l.args.tokenAddress.toLowerCase()).sort(); const listed = reg.coins.filter((k) => k.stack === s).map((k) => k.address.toLowerCase()).sort();
  if (onchain.join() !== listed.join()) fail(`stack ${s}`, 'coins launched by factory', listed.join(',') || 'none', onchain.join(',') || 'none');
  for (const l of logs) { const k = reg.coins.find((x) => eq(x.address, l.args.tokenAddress)); if (k && (!eq(k.launchTxHash, l.transactionHash) || k.launchBlock !== Number(l.blockNumber))) fail(`coin ${k.symbol}`, 'launch tx/block', `${k.launchTxHash} ${k.launchBlock}`, `${l.transactionHash} ${l.blockNumber}`); }
  rows.stackCoins = { ...(rows.stackCoins || {}), [s]: onchain.length };
}

// commit staleness (warn only): src/ changed since the commit the registry was verified at
const paths = new Set(C.map((c) => c.source.repoPath).filter(Boolean));
const stale = (git(`diff --name-only --diff-filter=MD ${reg.repoCommit} HEAD -- src`) || '').split('\n').filter((f) => paths.has(f));
if (stale.length) warn.push(`registered sources modified since repoCommit ${reg.repoCommit.slice(0, 8)}: ${stale.join(', ')}; re-run with --fill after a rebuild`);

// ---------- optional: block bisect ----------
const blockTs = async (n) => new Date(Number((await client.getBlock({ blockNumber: BigInt(n) })).timestamp) * 1000).toISOString().slice(0, 10);
const hasCode = async (a, n) => { const x = await client.getCode({ address: a, blockNumber: BigInt(n) }); return !!x && x !== '0x'; };
async function firstBlock(a, lo) { let hi = Number(head); while (lo < hi) { const mid = Math.floor((lo + hi) / 2); await sleep(150); (await hasCode(a, mid)) ? (hi = mid) : (lo = mid + 1); } return lo; }
const blockFixes = [];
if (flag('--update-blocks')) {
  const known = C.map((c) => c.deployBlock).filter(Boolean); const lo0 = Math.min(...known, ...reg.coins.map((k) => k.launchBlock)) - 2_000_000;
  for (const e of [...C.map((c) => ({ c, a: c.address, f: 'deployBlock', t: 'deployedAt' })), ...reg.coins.map((k) => ({ c: k, a: k.address, f: 'launchBlock' }))]) {
    const cur = e.c[e.f]; const ok = cur && (await hasCode(e.a, cur)) && !(await hasCode(e.a, cur - 1));
    if (ok) continue;
    const found = await firstBlock(e.a, lo0); blockFixes.push({ e, found, cur });
    if (!flag('--fill')) fail(`${e.c.name || e.c.symbol} ${e.a.slice(0, 8)}`, e.f, cur, found);
  }
}

// ---------- fill ----------
if (flag('--fill')) {
  for (const [c, v] of drift.owner) c.owner = v ? getAddress(v) : null;
  for (const [c, s] of drift.state) c.state = s;
  for (const [c, m] of drift.match) { c.source.bytecodeMatch = m.m; c.source.commit = m.m === 'unverified' ? null : git('rev-parse HEAD'); if (m.m !== 'unverified') c.notes = (c.notes || '').replace(/\s*\|\s*bytecode: .*$/, '') + ` | bytecode: ${m.d}`; }
  for (const { e, found } of blockFixes) { e.c[e.f] = found; if (e.t) e.c[e.t] = await blockTs(found); }
  for (const r of coinRows) { if (r.pool) Object.assign(r.k.pool, r.pool); r.k.chainVerified = r.ok === 'ok'; }
  for (const r of rows) r.c.chainVerified = r.code === 'ok' && r.wiring === 'ok';
  reg.repoCommit = git('rev-parse HEAD') || reg.repoCommit; reg.generatedAt = new Date().toISOString();
  fs.writeFileSync(FILE, JSON.stringify(reg, null, 2) + '\n'); console.log(`filled ${FILE}`);
}

// ---------- report ----------
const pad = (s, n) => String(s).padEnd(n).slice(0, n);
console.log(`registry ${FILE} @ ${reg.repoCommit.slice(0, 8)}  rpc ${URL.replace(/\/\/.*@/, '//')}  head ${head}  artifacts ${DIRS.join(',')}${missingDirs.length ? ' (missing: ' + missingDirs.join(',') + ')' : ''}`);
console.log([pad('contract', 34), pad('address', 11), pad('stack', 8), pad('role', 10), pad('code', 5), pad('owner', 7), pad('state', 11), pad('bytecode', 11), pad('wiring', 6)].join(' '));
for (const r of rows) console.log([pad(r.c.name, 34), pad(r.c.address.slice(0, 10), 11), pad(r.c.stack, 8), pad(r.c.role, 10), pad(r.code, 5), pad(r.owner, 7), pad(r.state, 11), pad(r.bc, 11), pad(r.wiring, 6)].join(' '));
console.log('\n' + [pad('coin', 8), pad('address', 11), pad('stack', 8), pad('name/symbol/pool', 17), 'launched on chain by stack factory'].join(' '));
for (const r of coinRows) console.log([pad(r.k.symbol, 8), pad(r.k.address.slice(0, 10), 11), pad(r.k.stack, 8), pad(r.ok, 17), `${rows.stackCoins[r.k.stack]} coin(s) in ${r.k.stack} factory logs`].join(' '));
console.log('stack coin counts: ' + Object.entries(rows.stackCoins).map(([s, n]) => `${s}=${n}`).join(' '));
for (const w of warn) console.log('WARN ' + w);
const hard = flag('--fill') ? fails.filter((f) => !['bytecodeMatch', 'state', 'owner()', 'deployBlock', 'launchBlock', 'launch tx/block'].includes(f.what)) : fails;
if (hard.length) {
  console.log('\nDRIFT');
  console.log([pad('who', 36), pad('check', 28), pad('registry', 44), 'chain'].join(' '));
  for (const f of hard) console.log([pad(f.who, 36), pad(f.what, 28), pad(f.exp, 44), f.got].join(' '));
  console.log(`\n${hard.length} drift(s)`); process.exit(1);
}
console.log(`\nok: ${C.length} contracts, ${reg.coins.length} coins, 0 drift, ${warn.length} warning(s)`);
