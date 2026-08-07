/**
 * Etherscan-family block explorer URL helpers, chain-aware.
 *
 * Mirrors the ternary that used to be copy-pasted at every call site:
 * chain 1 (mainnet) -> etherscan.io, anything else (including 11155111 /
 * Sepolia) -> sepolia.etherscan.io. Kept as an explicit map rather than a
 * bare ternary so a third chain can be added without touching call sites.
 */

const EXPLORER_BASES: Record<number, string> = {
  1: 'https://etherscan.io',
  11155111: 'https://sepolia.etherscan.io',
};

const DEFAULT_BASE = EXPLORER_BASES[11155111];

function explorerBase(chainId: number): string {
  return EXPLORER_BASES[chainId] ?? DEFAULT_BASE;
}

export function explorerAddressUrl(chainId: number, address: string): string {
  return `${explorerBase(chainId)}/address/${address}`;
}

export function explorerTxUrl(chainId: number, hash: string): string {
  return `${explorerBase(chainId)}/tx/${hash}`;
}
