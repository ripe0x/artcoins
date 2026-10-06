// Node side helpers for the mainnet fork (anvil). Everything here talks to the local anvil only.
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toHex,
  parseEther,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { mainnet } from 'viem/chains';
import fs from 'node:fs';

export const FORK_RPC = process.env.E2E_FORK_RPC ?? 'http://127.0.0.1:8545';
export const FORK_BLOCK = 26_130_269n;

export const pub = createPublicClient({ chain: mainnet, transport: http(FORK_RPC, { timeout: 120_000 }) });

/** anvil's second default account. Unlocked on anvil, used only to fund test wallets (a plain transfer). */
export const FUNDER: Address = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';

/**
 * A deterministic, non public test key per label. Not anvil's default keys: on mainnet those carry an
 * eip-7702 sweeper delegation that forwards any eth they receive, which breaks balance assertions.
 */
export function testKey(label: string): Hex {
  return keccak256(toHex(`artcoins-ui-e2e:${label}`));
}

export function testAccount(label: string) {
  return privateKeyToAccount(testKey(label));
}

export async function rpc<T = unknown>(method: string, params: unknown[] = []): Promise<T> {
  return (await pub.request({ method: method as never, params: params as never })) as T;
}

/** Fund `to` with `eth` from the anvil funder through a real transfer, then wait for it. */
export async function fund(to: Address, eth = '1'): Promise<Hex> {
  const hash = await rpc<Hex>('eth_sendTransaction', [
    { from: FUNDER, to, value: toHex(parseEther(eth)) },
  ]);
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== 'success') throw new Error(`funding ${to} reverted`);
  return hash;
}

export function walletClientFor(label: string) {
  return createWalletClient({ account: testAccount(label), chain: mainnet, transport: http(FORK_RPC, { timeout: 120_000 }) });
}

/** Confirms the rpc is the expected fork (chain 1, at or past the pinned block). */
export async function assertFork(): Promise<void> {
  const [chainId, head] = await Promise.all([pub.getChainId(), pub.getBlockNumber()]);
  if (chainId !== 1) throw new Error(`fork rpc ${FORK_RPC} reports chain ${chainId}, want 1`);
  if (head < FORK_BLOCK) throw new Error(`fork head ${head} is below the pinned block ${FORK_BLOCK}`);
}

export interface V2Env {
  factory: Address;
  hook: Address;
  locker: Address;
  escrow: Address;
  mevModule: Address;
  deployBlock: bigint;
  owner: Address;
}

/** The locally deployed v2 stack, from E2E_V2_JSON (see e2e/README section in ui/README.md), or null. */
export function v2Env(): V2Env | null {
  const p = process.env.E2E_V2_JSON;
  if (!p || !fs.existsSync(p)) return null;
  const j = JSON.parse(fs.readFileSync(p, 'utf8')) as Record<string, string>;
  return {
    factory: j.VITE_V2_FACTORY as Address,
    hook: j.VITE_V2_HOOK as Address,
    locker: j.VITE_V2_LOCKER as Address,
    escrow: j.VITE_V2_ESCROW as Address,
    mevModule: j.VITE_V2_MEV_MODULE as Address,
    deployBlock: BigInt(j.VITE_V2_DEPLOY_BLOCK ?? '0'),
    owner: j.E2E_V2_OWNER as Address,
  };
}
