// Live check that the generated abis decode what the token detail page reads, for coin 111 on mainnet.
//   cd ui && NODE_USE_ENV_PROXY=1 npx tsx scripts/check-token-reads.ts   (proxy flag only inside a proxied sandbox)
import { createPublicClient, http } from 'viem';
import { mainnet } from 'viem/chains';
import { fetchAllTokens } from '../src/lib/discovery';
import { lockerV1Abi } from '../src/lib/abi/v1/locker';
import { hookV1Abi } from '../src/lib/abi/v1/hook';
import { mevLinearSkimV1Abi } from '../src/lib/abi/v1/mevLinearSkim';
import { tokenV1Abi } from '../src/lib/abi/v1/token';
import { factoryV1Abi } from '../src/lib/abi/v1/factory';
import { computePoolId } from '../src/lib/pool';
import { normalizeSkim } from '../src/lib/poolReads';

const client = createPublicClient({ chain: mainnet, transport: http(process.env.MAINNET_RPC_URL ?? 'https://mainnet.gateway.tenderly.co') });
const [t] = (await fetchAllTokens(client, 1)).filter((x) => x.symbol === '111');
if (!t) throw new Error('coin 111 not found');

const rewards = await client.readContract({ address: t.locker, abi: lockerV1Abi, functionName: 'tokenRewards', args: [t.token] });
const id = computePoolId(rewards.poolKey);
console.log('poolKey', rewards.poolKey, 'matches event pool id:', id.toLowerCase() === t.poolId.toLowerCase());
if (id.toLowerCase() !== t.poolId.toLowerCase()) throw new Error('pool id mismatch');

const skim = normalizeSkim(await client.readContract({ address: t.hook, abi: hookV1Abi, functionName: 'skimConfig', args: [t.poolId] }));
console.log('skim', skim);
if (!skim || skim.baselineSkimBps !== 6000 || skim.bountyBps !== 8333 || skim.maxReferralBpsOfVolume !== 250 || skim.lpFeePips !== 5000) throw new Error('unexpected skim config');

console.log('mev currentSkimBps', await client.readContract({ address: t.mevModule, abi: mevLinearSkimV1Abi, functionName: 'currentSkimBps', args: [t.poolId] }));
console.log('mev operational', await client.readContract({ address: t.mevModule, abi: mevLinearSkimV1Abi, functionName: 'operational', args: [t.poolId] }));
console.log('mev skimConfigs', await client.readContract({ address: t.mevModule, abi: mevLinearSkimV1Abi, functionName: 'skimConfigs', args: [t.poolId] }));
for (const fn of ['name', 'symbol', 'totalSupply', 'admin', 'imageUrl', 'isVerified', 'metadataRenderer'] as const) {
  console.log(fn, await client.readContract({ address: t.token, abi: tokenV1Abi, functionName: fn }));
}
console.log('factory deprecated', await client.readContract({ address: t.factory, abi: factoryV1Abi, functionName: 'deprecated' }));
console.log('factory deployFee', await client.readContract({ address: t.factory, abi: factoryV1Abi, functionName: 'deployFee' }));
console.log('factory defaultProtocolFeeBps', await client.readContract({ address: t.factory, abi: factoryV1Abi, functionName: 'defaultProtocolFeeBps' }));
console.log('OK');
