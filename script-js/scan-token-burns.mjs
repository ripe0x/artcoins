import { createPublicClient, http, parseAbiItem, formatUnits } from 'viem';
import { base } from 'viem/chains';

const client = createPublicClient({ chain: base, transport: http('https://mainnet.base.org') });
const TOKEN = '0x5a34646B860485f012435e2486eDB375615D1c7B';
const DEAD = '0x000000000000000000000000000000000000dEaD';
const ZERO = '0x0000000000000000000000000000000000000000';
const USER_BURN_BLOCK = 45405633n;

const transferEvent = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)');

// Find token deploy block (cheap: walk back from current head with binary search on getCode)
async function findDeploy() {
  let lo = 1n, hi = await client.getBlockNumber();
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const code = await client.getCode({ address: TOKEN, blockNumber: mid });
    if (!code || code === '0x') lo = mid + 1n;
    else hi = mid;
  }
  return lo;
}
const deploy = await findDeploy();
console.log('LL token deploy block:', deploy);

// Pull Transfer events to dead, before user-burn block
const CHUNK = 9500n;
let toDead = [];
for (let from = deploy; from < USER_BURN_BLOCK; from += CHUNK + 1n) {
  const to = from + CHUNK >= USER_BURN_BLOCK ? USER_BURN_BLOCK - 1n : from + CHUNK;
  const chunk = await client.getLogs({
    address: TOKEN,
    event: transferEvent,
    args: { to: DEAD },
    fromBlock: from,
    toBlock: to,
  });
  toDead = toDead.concat(chunk);
}

console.log('\n=== Transfers to 0xdead BEFORE block ' + USER_BURN_BLOCK + ' ===');
console.log('count:', toDead.length);
let sum = 0n;
for (const log of toDead) {
  console.log(`  block ${log.blockNumber}  from ${log.args.from}  amount ${formatUnits(log.args.value, 18)}  tx ${log.transactionHash}`);
  sum += log.args.value;
}
console.log('SUM (whole tokens):', formatUnits(sum, 18));

// Also check zero-address (true ERC20 _burn) — only useful if token is burnable
let toZero = [];
for (let from = deploy; from < USER_BURN_BLOCK; from += CHUNK + 1n) {
  const to = from + CHUNK >= USER_BURN_BLOCK ? USER_BURN_BLOCK - 1n : from + CHUNK;
  const chunk = await client.getLogs({
    address: TOKEN,
    event: transferEvent,
    args: { to: ZERO },
    fromBlock: from,
    toBlock: to,
  });
  toZero = toZero.concat(chunk);
}
console.log('\n=== Transfers to 0x0 (ERC20 _burn) BEFORE block ' + USER_BURN_BLOCK + ' ===');
console.log('count:', toZero.length);
let sumZ = 0n;
for (const log of toZero) sumZ += log.args.value;
console.log('SUM (whole tokens):', formatUnits(sumZ, 18));

const grand = sum + sumZ;
console.log('\n=== TOTAL BURNED (dead + zero) before user burn ===');
console.log('whole tokens:', formatUnits(grand, 18));
