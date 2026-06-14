import { createPublicClient, http, parseAbiItem, formatUnits } from 'viem';
import { base } from 'viem/chains';

const client = createPublicClient({ chain: base, transport: http('https://mainnet.base.org') });
const ADDR = '0x6B19a430281b5ACbcBC925E3c1A50802968A4daC';

// baseToken() is the immutable ERC20 the contract escrows
const baseToken = await client.readContract({
  address: ADDR,
  abi: [{ inputs: [], name: 'baseToken', outputs: [{ type: 'address' }], stateMutability: 'view', type: 'function' }],
  functionName: 'baseToken',
});
const totalDeposited = await client.readContract({
  address: ADDR,
  abi: [{ inputs: [], name: 'totalDeposited', outputs: [{ type: 'uint256' }], stateMutability: 'view', type: 'function' }],
  functionName: 'totalDeposited',
});
const currentBal = await client.readContract({
  address: baseToken,
  abi: [{ inputs: [{ type:'address' }], name: 'balanceOf', outputs:[{type:'uint256'}], stateMutability:'view', type:'function' }],
  functionName: 'balanceOf',
  args: [ADDR],
});
const tokenSymbol = await client.readContract({
  address: baseToken,
  abi: [{ inputs: [], name: 'symbol', outputs: [{ type: 'string' }], stateMutability: 'view', type: 'function' }],
  functionName: 'symbol',
}).catch(() => '?');

console.log('baseToken:', baseToken, '(' + tokenSymbol + ')');
console.log('totalDeposited:', formatUnits(totalDeposited, 18));
console.log('currentBalance:', formatUnits(currentBal, 18));

// Enumerate Burned events from deploy block
const deployBlock = 44534024n;
const head = await client.getBlockNumber();
const CHUNK = 9500n;
const burnEvent = parseAbiItem('event Burned(uint256 amount)');
let logs = [];
for (let from = deployBlock; from <= head; from += CHUNK + 1n) {
  const to = from + CHUNK > head ? head : from + CHUNK;
  const chunk = await client.getLogs({ address: ADDR, event: burnEvent, fromBlock: from, toBlock: to });
  logs = logs.concat(chunk);
}
console.log('\n=== Burned events ===');
console.log('count:', logs.length);
let cumPrior = 0n;
for (let i = 0; i < logs.length; i++) {
  const b = logs[i];
  const block = await client.getBlock({ blockNumber: b.blockNumber });
  const ts = new Date(Number(block.timestamp) * 1000).toISOString();
  console.log(`#${i+1}  block ${b.blockNumber}  ${ts}  tx ${b.transactionHash}`);
  console.log(`     amount: ${formatUnits(b.args.amount, 18)}`);
  if (i < logs.length - 1) cumPrior += b.args.amount;
}
if (logs.length > 0) {
  const last = logs[logs.length - 1];
  console.log('\nLast burn (assumed user burn):', formatUnits(last.args.amount, 18));
  console.log('Sum of all burns BEFORE the last burn:', formatUnits(cumPrior, 18));
  const sumAll = logs.reduce((a, l) => a + l.args.amount, 0n);
  console.log('Sum of ALL burns:', formatUnits(sumAll, 18));
}
