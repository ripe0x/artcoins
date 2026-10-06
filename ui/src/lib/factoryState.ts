// Chain reads that drive the deploy page: who may launch, what it costs and how the lp reward
// split must look. Nothing here is hardcoded, the factory is the source of truth.
import { useReadContracts } from 'wagmi';
import { factoryV2Abi } from './abi/v2/factory';
import { factoryV1Abi } from './abi/v1/factory';
import { isAddress, type Address } from 'viem';
import { classifyExempt, type ExemptStatusMap } from './launchRules';

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
  /** lowest lp fee a launch may use, pips (D53), v2 only */
  minLpFee: number;
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
      { ...base, functionName: 'minLpFee' },
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
    minLpFee: Number((data?.[4]?.result as number | bigint | undefined) ?? 0),
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

/**
 * Asks the factory about every tax exempt entry (D47): `exemptAllowed`, `enabledEscrows` and
 * `enabledExtensions`, the three ways `_validateTax` lets an entry through (the launch's own locker and
 * hook are known client side). Keyed by lowercase address. null without a factory.
 */
export function useExemptStatus(factory: Address | undefined, entries: string[], locker: Address, hook: Address): ExemptStatusMap | null {
  const valid = [...new Set(entries.filter((e) => isAddress(e, { strict: false })).map((e) => e.toLowerCase() as Address))];
  const base = { address: factory, abi: factoryV2Abi } as const;
  const { data } = useReadContracts({
    contracts: valid.flatMap((a) => [
      { ...base, functionName: 'exemptAllowed' as const, args: [a] as const },
      { ...base, functionName: 'enabledEscrows' as const, args: [a] as const },
      { ...base, functionName: 'enabledExtensions' as const, args: [a] as const },
    ]),
    allowFailure: true,
    query: { enabled: !!factory && valid.length > 0, staleTime: 15_000 },
  });
  if (!factory) return null;
  const out: ExemptStatusMap = {};
  valid.forEach((a, i) => {
    const r = (n: number) => (data?.[i * 3 + n]?.status === 'success' ? (data[i * 3 + n].result as boolean) : undefined);
    out[a] = classifyExempt({ exemptAllowed: r(0), enabledEscrow: r(1), enabledExtension: r(2) }, a, locker, hook);
  });
  return out;
}
