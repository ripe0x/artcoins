// Live check of token discovery against the mainnet rpc (default: the tenderly public gateway).
//   cd ui && npx tsx scripts/check-discovery.ts
import { createPublicClient, http } from 'viem';
import { mainnet } from 'viem/chains';
import { fetchAllTokens } from '../src/lib/discovery';

const rpc = process.env.MAINNET_RPC_URL ?? 'https://mainnet.gateway.tenderly.co';
const client = createPublicClient({ chain: mainnet, transport: http(rpc) });
const t0 = Date.now();
const tokens = await fetchAllTokens(client, 1);
console.log(`found ${tokens.length} tokens in ${Date.now() - t0}ms`);
for (const t of tokens) console.log(t.version, t.token, JSON.stringify(t.name), t.symbol, t.blockNumber, t.tickSpacing, t.startingTick);
const has111 = tokens.some((t) => t.token.toLowerCase() === '0x61c9d89fe1212f6b55ff888816a151463287b8ae');
if (!has111) {
  console.error('coin 111 not found');
  process.exit(1);
}
