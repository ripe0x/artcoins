// The v2 stack (factory, hook, locker, ...). Not in deployments/mainnet.json until the v2 deploy lands.
//
// Resolution order:
//   1. a `V2` export of deployments.generated.ts, once script-js/gen-addresses.mjs emits one
//      (shape: V2Stack below, `deployBlock` as bigint)
//   2. build time env, VITE_V2_FACTORY, VITE_V2_HOOK, VITE_V2_LOCKER (required), and optionally
//      VITE_V2_ESCROW, VITE_V2_MEV_MODULE, VITE_V2_DEV_BUY, VITE_V2_VAULT, VITE_V2_AIRDROP,
//      VITE_V2_POOL_EXTENSION, VITE_V2_DEPLOY_BLOCK
// With neither, `getV2Stack` returns null and the deploy page stays gated, token discovery reads
// only the current (v1) factory. Mainnet only: v2 is never offered on another chain.
import { getAddress, isAddress, type Address } from 'viem';
import * as generated from './deployments.generated';
import { ZERO_ADDRESS } from './constants';

export interface V2Stack {
  factory: Address;
  hook: Address;
  locker: Address;
  escrow: Address;
  /** ArtCoinsMevLinearSkimV2, zero when the stack has no module */
  mevModule: Address;
  devBuy: Address;
  vault: Address;
  airdrop: Address;
  poolExtension: Address;
  /** first block to scan for TokenCreatedV2 */
  deployBlock: bigint;
  source: 'registry' | 'env';
}

const env = (import.meta.env ?? {}) as Record<string, string | undefined>;

function addr(raw: unknown): Address | null {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  if (!isAddress(s, { strict: false })) return null;
  const a = getAddress(s);
  return a === ZERO_ADDRESS ? null : a;
}

function fromRegistry(): V2Stack | null {
  // looked up dynamically: the registry generator has no V2 export until the v2 deploy lands
  const g = Reflect.get(generated, 'V2') as Partial<Record<keyof V2Stack, unknown>> | undefined;
  if (!g) return null;
  const factory = addr(g.factory);
  const hook = addr(g.hook);
  const locker = addr(g.locker);
  if (!factory || !hook || !locker) return null;
  return {
    factory,
    hook,
    locker,
    escrow: addr(g.escrow) ?? ZERO_ADDRESS,
    mevModule: addr(g.mevModule) ?? ZERO_ADDRESS,
    devBuy: addr(g.devBuy) ?? ZERO_ADDRESS,
    vault: addr(g.vault) ?? ZERO_ADDRESS,
    airdrop: addr(g.airdrop) ?? ZERO_ADDRESS,
    poolExtension: addr(g.poolExtension) ?? ZERO_ADDRESS,
    deployBlock: typeof g.deployBlock === 'bigint' ? g.deployBlock : 0n,
    source: 'registry',
  };
}

function fromEnv(): V2Stack | null {
  const factory = addr(env.VITE_V2_FACTORY);
  const hook = addr(env.VITE_V2_HOOK);
  const locker = addr(env.VITE_V2_LOCKER);
  if (!factory || !hook || !locker) return null;
  let deployBlock = 0n;
  try {
    if (env.VITE_V2_DEPLOY_BLOCK) deployBlock = BigInt(env.VITE_V2_DEPLOY_BLOCK);
  } catch {
    deployBlock = 0n;
  }
  return {
    factory,
    hook,
    locker,
    escrow: addr(env.VITE_V2_ESCROW) ?? ZERO_ADDRESS,
    mevModule: addr(env.VITE_V2_MEV_MODULE) ?? ZERO_ADDRESS,
    devBuy: addr(env.VITE_V2_DEV_BUY) ?? ZERO_ADDRESS,
    vault: addr(env.VITE_V2_VAULT) ?? ZERO_ADDRESS,
    airdrop: addr(env.VITE_V2_AIRDROP) ?? ZERO_ADDRESS,
    poolExtension: addr(env.VITE_V2_POOL_EXTENSION) ?? ZERO_ADDRESS,
    deployBlock,
    source: 'env',
  };
}

const V2_STACK: V2Stack | null = fromRegistry() ?? fromEnv();

/** The v2 stack for a chain, or null when none is configured (always null off mainnet). */
export function getV2Stack(chainId: number): V2Stack | null {
  return chainId === 1 ? V2_STACK : null;
}
