import { createPublicClient, http, parseAbiItem, formatUnits } from 'viem';
import { base } from 'viem/chains';

const client = createPublicClient({ chain: base, transport: http('https://mainnet.base.org') });
const TOKEN = '0x5a34646B860485f012435e2486eDB375615D1c7B';
const ZERO  = '0x0000000000000000000000000000000000000000';
const USER_BURN_BLOCK = 45405633n;
// First transfer-to-dead was at 37568624, so token was deployed before that.
// Use a conservative lower bound to skip the long binary search; we only care
// about Transfer events (which must come at or after deploy).
const FROM = 37000000n;

const transferEvent = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)');
const CHUNK = 9500n;
let toZero = [];
for (let from = FROM; from < USER_BURN_BLOCK; from += CHUNK + 1n) {
  const to = from + CHUNK >= USER_BURN_BLOCK ? USER_BURN_BLOCK - 1n : from + CHUNK;
  let tries = 0;
  while (true) {
    try {
      const chunk = await client.getLogs({
        address: TOKEN, event: transferEvent,
        args: { to: ZERO },
        fromBlock: from, toBlock: to,
      });
      toZero = toZero.concat(chunk);
      break;
    } catch (e) {
      tries++;
      if (tries > 4) throw e;
      await new Promise(r => setTimeout(r, 500 * tries));
    }
  }
}
console.log('count to 0x0:', toZero.length);
let sum = 0n;
for (const log of toZero) {
  console.log(`  block ${log.blockNumber}  from ${log.args.from}  amount ${formatUnits(log.args.value, 18)}  tx ${log.transactionHash}`);
  sum += log.args.value;
}
console.log('SUM to 0x0 (whole tokens):', formatUnits(sum, 18));
