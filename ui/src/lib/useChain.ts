import { useAccount, useChainId, useSwitchChain } from 'wagmi';
import { getAddresses, isSupportedChain, type ContractAddresses } from './config';

/** The chain every write goes to. The registry and the v2 stack are mainnet only. */
export const WRITE_CHAIN_ID = 1;

/** Addresses for the configured chain, or null on an unsupported chain (never a fallback to another chain). */
export function useAddressesOrNull(): { chainId: number; addresses: ContractAddresses | null } {
  const chainId = useChainId();
  return { chainId, addresses: isSupportedChain(chainId) ? getAddresses(chainId) : null };
}

export interface WalletGate {
  /** connected to mainnet, writes allowed */
  ok: boolean;
  /** why not, shown on the disabled button */
  reason: string | null;
  needsSwitch: boolean;
  switchToMainnet: () => void;
  address: `0x${string}` | undefined;
}

/** Writes need a connected wallet on the chain the contracts live on. */
export function useWalletGate(): WalletGate {
  const { address, isConnected, chainId } = useAccount();
  const { switchChain } = useSwitchChain();
  const wrongChain = isConnected && chainId !== WRITE_CHAIN_ID;
  return {
    ok: isConnected && !wrongChain,
    reason: !isConnected ? 'Connect your wallet' : wrongChain ? 'Switch your wallet to Ethereum mainnet' : null,
    needsSwitch: wrongChain,
    switchToMainnet: () => switchChain({ chainId: WRITE_CHAIN_ID }),
    address,
  };
}
