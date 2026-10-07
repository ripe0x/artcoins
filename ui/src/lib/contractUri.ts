// contractURI() of an artcoin can be an on chain renderer: ~180M gas and hundreds of kB (coin 111). It never goes
// into the batched multicall that feeds the token card. It is read alone, with its own gas limit and a timeout,
// and a failure is an ordinary answer: the page shows a placeholder.
import type { Address } from 'viem';
import { tokenV1Abi } from './abi/v1/token';

/** gas given to the call. Above what the heaviest known renderer needs, below a block */
export const CONTRACT_URI_GAS = 300_000_000n;
/** how long the page waits for the renderer before it gives up and shows the placeholder */
export const CONTRACT_URI_TIMEOUT_MS = 60_000;

export class ReadTimeout extends Error {
  constructor(ms: number) {
    super(`timed out after ${Math.round(ms / 1000)}s`);
    this.name = 'ReadTimeout';
  }
}

export async function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new ReadTimeout(ms)), ms);
  });
  try {
    return await Promise.race([work, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

export interface ContractUriClient {
  readContract: (args: {
    address: Address;
    abi: typeof tokenV1Abi;
    functionName: 'contractURI';
    gas?: bigint;
  }) => Promise<unknown>;
}

/**
 * Reads contractURI() on its own. First with an explicit gas limit, so a node that would otherwise run the call
 * under a smaller default does not cut the renderer off. A node that refuses the explicit limit gets one more
 * try without it. A timeout is final. Throws on failure, the caller shows the placeholder.
 */
export async function readContractUri(client: ContractUriClient, token: Address, timeoutMs = CONTRACT_URI_TIMEOUT_MS): Promise<string> {
  const call = (gas?: bigint) => client.readContract({ address: token, abi: tokenV1Abi, functionName: 'contractURI', gas });
  let value: unknown;
  try {
    value = await withTimeout(call(CONTRACT_URI_GAS), timeoutMs);
  } catch (e) {
    if (e instanceof ReadTimeout) throw e;
    value = await withTimeout(call(), timeoutMs);
  }
  if (typeof value !== 'string') throw new Error('contractURI returned no string');
  return value;
}
