// Chain reads that drive the deploy page: who may launch, what it costs and how the lp reward
// split must look. Nothing here is hardcoded, the factory is the source of truth.
import { useReadContracts } from 'wagmi';
import { factoryV2Abi } from './abi/v2/factory';
import { factoryV1Abi } from './abi/v1/factory';
import type { Address } from 'viem';

export interface FactoryState {
  loading: boolean;
  /** true when the factory answered, false when a read failed (do not guess, block the page) */
  ok: boolean;
  deprecated: boolean;
  deployFee: bigint;
  /** the protocol slot `deployToken` appends, bps */
  defaultProtocolFeeBps: number;
  /** minimum protocol share of the skim, v2 only, caps the bounty share */
  minProtocolSkimShareBps: number;
  owner?: Address;
  refetch: () => void;
}

/** Reads the v2 factory. Poll slowly: `deployFee` can change under the user, the review step reads again before sending. */
export function useFactoryStateV2(factory: Address | undefined): FactoryState {
  const base = { address: factory, abi: factoryV2Abi } as const;
  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      { ...base, functionName: 'deprecated' },
      { ...base, functionName: 'deployFee' },
      { ...base, functionName: 'defaultProtocolFeeBps' },
      { ...base, functionName: 'minProtocolSkimShareBps' },
    ],
    allowFailure: true,
    query: { enabled: !!factory, refetchInterval: 30_000 },
  });
  return {
    loading: isLoading,
    ok: !!data && data.every((d) => d.status === 'success'),
    deprecated: (data?.[0]?.result as boolean | undefined) ?? true,
    deployFee: (data?.[1]?.result as bigint | undefined) ?? 0n,
    defaultProtocolFeeBps: Number((data?.[2]?.result as number | bigint | undefined) ?? 0),
    minProtocolSkimShareBps: Number((data?.[3]?.result as number | bigint | undefined) ?? 0),
    refetch: () => void refetch(),
  };
}

/** Reads the current (v1) factory only to tell the user why launching is closed there. */
export function useFactoryStateV1(factory: Address | undefined): Pick<FactoryState, 'loading' | 'ok' | 'deprecated' | 'deployFee' | 'defaultProtocolFeeBps' | 'owner'> {
  const base = { address: factory, abi: factoryV1Abi } as const;
  const { data, isLoading } = useReadContracts({
    contracts: [
      { ...base, functionName: 'deprecated' },
      { ...base, functionName: 'deployFee' },
      { ...base, functionName: 'defaultProtocolFeeBps' },
      { ...base, functionName: 'owner' },
    ],
    allowFailure: true,
    query: { enabled: !!factory, refetchInterval: 60_000 },
  });
  return {
    loading: isLoading,
    ok: !!data && data.every((d) => d.status === 'success'),
    deprecated: (data?.[0]?.result as boolean | undefined) ?? true,
    deployFee: (data?.[1]?.result as bigint | undefined) ?? 0n,
    defaultProtocolFeeBps: Number((data?.[2]?.result as number | bigint | undefined) ?? 0),
    owner: data?.[3]?.result as Address | undefined,
  };
}
