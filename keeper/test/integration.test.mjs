// Integration: anvil fork of mainnet at block 26130269 (the repo's pinned fork block), both helper keepers
// deployed with cast from the foundry artifacts, then one runner tick against the fork: it reads preview(),
// decides (weekly timer, fresh state), quotes by simulation and sends `run` txs that succeed. A second tick and
// a restart on the same state send nothing. Skipped when MAINNET_RPC_URL is unset, anvil or cast is missing,
// or the artifacts are not built (forge build --skip "test/**" --skip script).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPublicClient, encodeDeployData, getAddress, http, parseEther } from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { createRuntime, preflight } from '../app.mjs';
import { tick } from '../runner.mjs';
import { readRegistry } from '../config.mjs';
import { setLogSink } from '../log.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const FORK_BLOCK = 26130269;
const ANVIL_KEY0 = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'; // anvil default deployer
const ART = (f) => path.join(ROOT, 'foundry-out', f);
const ARTIFACTS = { '111': ART('CollectFlushKeeperV1.sol/CollectFlushKeeperV1.json'), layer: ART('CollectFlushKeeperLayer.sol/CollectFlushKeeperLayer.json') };

const has = (bin) => { try { execFileSync(bin, ['--version'], { stdio: 'ignore' }); return true; } catch { return false; } };
const skip = !process.env.MAINNET_RPC_URL ? 'MAINNET_RPC_URL unset'
  : !has('anvil') || !has('cast') ? 'anvil or cast not on PATH'
  : !Object.values(ARTIFACTS).every((f) => fs.existsSync(f)) ? 'foundry artifacts missing (forge build --skip "test/**" --skip script)'
  : false;

const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, () => { const p = s.address().port; s.close(() => res(p)); }); });

async function startAnvil(port) {
  const proc = spawn('anvil', ['--fork-url', process.env.MAINNET_RPC_URL, '--fork-block-number', String(FORK_BLOCK), '--port', String(port),
    '--retries', '12', '--fork-retry-backoff', '3000', '--timeout', '60000', '--silent'], { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  proc.stderr.on('data', (d) => { stderr += d; });
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 120; i++) {
    if (proc.exitCode !== null) throw new Error('anvil exited: ' + stderr);
    try {
      const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }) });
      if ((await r.json()).result) return { proc, url };
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  proc.kill('SIGKILL');
  throw new Error('anvil did not start: ' + stderr);
}

function deploy(url, artifact, args) {
  const { abi, bytecode } = JSON.parse(fs.readFileSync(artifact, 'utf8'));
  const data = encodeDeployData({ abi, bytecode: bytecode.object, args });
  const out = execFileSync('cast', ['send', '--rpc-url', url, '--private-key', ANVIL_KEY0, '--json', '--create', data], { encoding: 'utf8', maxBuffer: 1 << 26 });
  const r = JSON.parse(out);
  assert.equal(r.status, '0x1', 'deploy failed');
  return getAddress(r.contractAddress);
}

const rpc = async (url, method, params) => {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(method + ': ' + j.error.message);
  return j.result;
};

test('runner on an anvil fork: reads, decides, quotes and runs both keepers once', { skip, timeout: 900_000 }, async () => {
  const reg = readRegistry();
  const c = (stack, name, nth = 0) => getAddress(reg.contracts.filter((x) => x.stack === stack && x.name === name)[nth].address);
  const coin = (sym) => reg.coins.find((x) => x.symbol === sym);
  const port = await freePort();
  const { proc, url } = await startAnvil(port);
  const lines = [];
  setLogSink((l) => lines.push(JSON.parse(l)));
  try {
    // same constructor args as script/v2/RunKeeper111.s.sol and RunKeeperLayer.s.sol, from the registry
    const k111 = deploy(url, ARTIFACTS['111'], [c('current', 'ArtCoinsLpLocker'), getAddress(coin('111').address), c('current', 'FeeAutoSwapper'), c('current', 'ArtCoinsFeeEscrow')]);
    const kLayer = deploy(url, ARTIFACTS.layer, [
      c('legacy', 'ArtCoinsLpLockerMultiple'), getAddress(coin('LAYER').address), getAddress(coin('LAYER').pool.pairedToken), c('legacy', 'ArtCoinsFeeLocker'),
      c('legacy', 'ProtocolFeeController'), [c('legacy', 'BurnRouter'), c('open', 'BurnRouter', 1), c('current', 'BurnRouter')],
    ]);

    // a fresh hot key, funded under the 0.05 eth limit (never a real key)
    const key = generatePrivateKey();
    const addr = privateKeyToAccount(key).address;
    await rpc(url, 'anvil_setBalance', [addr, '0x' + parseEther('0.04').toString(16)]);

    const dir = fs.mkdtempSync(path.join(fs.realpathSync('/tmp'), 'keeper-it-'));
    const env = { KEEPER_PRIVATE_KEY: key, MAINNET_RPC_URL: url, KEEPER_111: k111, KEEPER_LAYER: kLayer, STATE_PATH: path.join(dir, 'state.json'), RECEIPT_TIMEOUT_SECONDS: '60' };
    const ctx = await createRuntime(env);
    await preflight(ctx);
    const s = await tick(ctx);
    const pub = createPublicClient({ transport: http(url) });

    // 111: the fork has 13k+ coin uncollected and no state, so it runs (weekly timer at least)
    const r111 = s.keepers['111'];
    assert.ok(r111.reasons.includes('weekly'), JSON.stringify(r111.reasons));
    assert.equal(r111.result, 'ok', JSON.stringify(r111, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
    assert.ok(r111.gasUsed > 500_000n && r111.gasUsed < 1_200_000n, `111 gas ${r111.gasUsed}`);
    const run111 = r111.events.find((e) => e.event === 'KeeperRun');
    assert.ok(run111, 'KeeperRun decoded');
    const tx111 = await pub.getTransaction({ hash: r111.hash });
    assert.equal(tx111.gas, 1_200_000n);
    // quoted: a convert in the simulation means doConvert true with minOut = simulated minus 100 bps
    if (r111.args[0]) assert.ok(r111.args[1] > 0n);

    const rl = s.keepers.layer;
    assert.equal(rl.result, 'ok', JSON.stringify(rl, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
    assert.equal((await pub.getTransaction({ hash: rl.hash })).gas, 3_500_000n);
    assert.ok(rl.events.some((e) => e.event === 'KeeperRun'));

    // the keepers hold nothing after a run
    assert.equal(await pub.getBalance({ address: k111 }), 0n);
    assert.equal(await pub.getBalance({ address: kLayer }), 0n);

    // same process, next tick: nothing due
    const s2 = await tick(ctx);
    assert.equal(s2.keepers['111'].result, 'idle', JSON.stringify(s2.keepers['111'].reasons));
    assert.equal(s2.keepers.layer.result, 'idle', JSON.stringify(s2.keepers.layer.reasons));

    // restart on the persisted state: nothing re runs
    const nonce = await pub.getTransactionCount({ address: addr });
    const ctx2 = await createRuntime(env);
    assert.equal(ctx2.state.keepers['111'].lastRunAt, ctx.state.keepers['111'].lastRunAt);
    await tick(ctx2);
    assert.equal(await pub.getTransactionCount({ address: addr }), nonce);
    assert.equal(nonce, 2);
  } finally {
    setLogSink((l) => process.stdout.write(l + '\n'));
    proc.kill('SIGTERM');
    await new Promise((r) => (proc.exitCode !== null ? r() : proc.once('exit', r)));
    if (process.env.KEEPER_IT_LOG) fs.writeFileSync(process.env.KEEPER_IT_LOG, lines.map((l) => JSON.stringify(l)).join('\n'));
  }
});
