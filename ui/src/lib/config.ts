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

// Mainnet deployment (2026-05-07, script/Deploy.s.sol run-latest.json,
// broadcast/Deploy.s.sol/1/run-1778121239784.json) — EIP-55 strict casing
// for viem ≥2.47. This is the "V1"-ABI stack (factory.deployToken(...),
// legacy MEV modules + vault/airdrop/devBuy extensions) that this UI's
// deploy flow (ReviewAndDeploy.tsx, factoryAbi.deployToken) targets. LAYER
// (the first token) was launched against this exact factory instance —
// see broadcast/LaunchLayer.s.sol/1/run-1778180525856.json. There is a
// separate, newer "V3" native-ETH-pair factory stack
// (script/DeployNativeEthStack.s.sol, mainnet 2026-05-18) with its own
// deployTokenWithProtocolBps(...) entrypoint and no MEV modules or
// vault/airdrop/devBuy extensions — this UI does not target it, so its
// addresses are intentionally NOT used here.
const MAINNET_ADDRESSES: ContractAddresses = {
  factory: '0xD1595A2742C392d1c109b616b4F08918D02292f9',
  hook: '0xA5eA9904F2cD572c638a1eF81463BDAbEa9D28cc',
  locker: '0x75BE7E95745915fD0C1761B74F3f9650ad2d1118',
  mevLinearFees: '0xAe19E402420359062eE422a03589e04a52cD8C6F',
  mevDescFees: '0x7958DE7d8C857CdD37465FB920A961B1f8F74301',
  mevTimeDelay: '0xf080D741D069B107D728B68F781843d83A0EA8Fb',
  vault: '0x84732a79e4Ec8F03063a138c7ef866a9d222C661',
  airdrop: '0xF937dFf16a45E417951794758E77CbEd0A7F27eC',
  devBuy: '0xfCB6a929dB98A1D69b5F33A2f7E073cB7449cF30',
  weth: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
  poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
  // Uniswap V4 StateView / Quoter mainnet deployments are NOT present
  // anywhere in this repo (not in broadcast/, script/, or .env.example) —
  // left as ZERO rather than guessed. Fill from Uniswap's official V4
  // deployment docs (https://docs.uniswap.org/contracts/v4/deployments)
  // before enabling any UI feature that reads slot0 or quotes on mainnet.
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
  1: 25_040_120n, // Mainnet factory deployment block (2026-05-07, broadcast/Deploy.s.sol/1/run-1778121239784.json receipt for ArtCoinsFactory 0xD1595A27...)
  11155111: 10_665_708n, // Sepolia deployment block (2026-04-15)
};

export function getFactoryDeploymentBlock(chainId: number): bigint {
  const block = factoryDeploymentBlocks[chainId] ?? 0n;
  const factoryAddress = addressMap[chainId]?.factory;
  if (factoryAddress && factoryAddress !== ZERO && block === 0n) {
    console.warn(
      `[config] Chain ${chainId} has a non-zero factory address but factoryDeploymentBlocks[${chainId}] is 0. ` +
        'This will cause getLogs to scan from genesis in 2000-block batches on every page load. ' +
        'Set the real deployment block in factoryDeploymentBlocks.'
    );
  }
  return block;
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
