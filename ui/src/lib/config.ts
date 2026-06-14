import type { Address } from 'viem';

export interface ContractAddresses {
  factory: Address;
  hook: Address;
  locker: Address;
  mevLinearFees: Address;
  mevDescFees: Address;
  mevTimeDelay: Address;
  vault: Address;
  airdrop: Address;
  devBuy: Address;
  weth: Address;
  /** Uniswap V4 PoolManager (official) */
  poolManager: Address;
  /** Uniswap V4 StateView — used to read slot0 (sqrtPriceX96, tick). Zero if unavailable. */
  stateView: Address;
  /** Uniswap V4 Quoter — quoteExactInputSingle. Zero if unavailable. */
  quoter: Address;
  /** Uniswap Universal Router — the entry point for V4 swaps. */
  universalRouter: Address;
  /** Permit2 — allowance manager used by Universal Router (same address on every chain). */
  permit2: Address;
}

const ZERO: Address = '0x0000000000000000000000000000000000000000';

const MAINNET_ADDRESSES: ContractAddresses = {
  factory: ZERO,
  hook: ZERO,
  locker: ZERO,
  mevLinearFees: ZERO,
  mevDescFees: ZERO,
  mevTimeDelay: ZERO,
  vault: ZERO,
  airdrop: ZERO,
  devBuy: ZERO,
  weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
  stateView: ZERO,
  quoter: ZERO,
  universalRouter: '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
};

// Sepolia deployment (2026-04-15) — EIP-55 strict casing for viem ≥2.47.
const SEPOLIA_ADDRESSES: ContractAddresses = {
  factory: '0x3c3aEfC8Fa374589D179D43cb03e29a6B350DF7A',
  hook: '0x36EF2eC4c1DF5e0A07567306D721F2Bb5d4E68cc',
  locker: '0x6e511f2321F82559E559ce1Da0EcFDBf0E4ace62',
  mevLinearFees: '0x7f0AC1a505614CF21a78ed276710864C8b256b4e',
  mevDescFees: '0xb42d19d3C4fCa696e59Ed2C6eEdD4a56752EDe12',
  mevTimeDelay: '0x562E8BEb37064b2A5A3f9D0Ab3AB9263ab1295ac',
  vault: '0xaF57B58c208D0D846646350fAdBba3537861F19B',
  airdrop: '0x9ad33BB054577d2b3a6B549Bf08D32814e0fBbF9',
  devBuy: '0x7Be49a9cB09E2FE7Dd5484ec94Fc8F70d226649B',
  weth: '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
  poolManager: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
  stateView: '0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C',
  quoter: '0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227',
  universalRouter: '0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
};

const addressMap: Record<number, ContractAddresses> = {
  1: MAINNET_ADDRESSES,
  11155111: SEPOLIA_ADDRESSES,
};

export function getAddresses(chainId: number): ContractAddresses {
  return addressMap[chainId] ?? SEPOLIA_ADDRESSES;
}

/**
 * Block number of the factory deployment for each chain.
 * Used as the `fromBlock` for getLogs so we don't scan from genesis.
 */
const factoryDeploymentBlocks: Record<number, bigint> = {
  1: 0n,
  11155111: 10_665_708n, // Sepolia deployment block (2026-04-15)
};

export function getFactoryDeploymentBlock(chainId: number): bigint {
  return factoryDeploymentBlocks[chainId] ?? 0n;
}

/**
 * Chain name slug as used by app.uniswap.org URLs.
 * Mainnet: "ethereum". Sepolia: "ethereum_sepolia".
 */
export function uniswapChainSlug(chainId: number): string {
  if (chainId === 1) return 'ethereum';
  if (chainId === 11155111) return 'ethereum_sepolia';
  return 'ethereum';
}

/**
 * URL for the Uniswap Explore page for a given token.
 * This page shows token info, pools, and a swap widget that respects the chain param.
 */
export function uniswapTokenUrl(chainId: number, tokenAddress: string): string {
  return `https://app.uniswap.org/explore/tokens/${uniswapChainSlug(chainId)}/${tokenAddress}`;
}

/**
 * Direct swap URL. Uniswap's router may not route through custom V4 hook pools,
 * but this at least opens the swap widget with the token preselected.
 */
export function uniswapSwapUrl(chainId: number, tokenAddress: string): string {
  const slug = uniswapChainSlug(chainId);
  return `https://app.uniswap.org/swap?chain=${slug}&inputCurrency=ETH&outputCurrency=${tokenAddress}`;
}
