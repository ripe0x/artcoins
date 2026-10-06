import { useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import { isAddress } from 'viem';
import { fetchAllTokens, factorySources, type TokenRecord } from './discovery';
import { useAddressesOrNull } from './useChain';

/** Every token launched through a configured factory (current stack and v2), newest first. */
export function useTokens() {
  const client = usePublicClient();
  const { chainId, addresses } = useAddressesOrNull();
  const sources = factorySources(chainId);
  const query = useQuery({
    queryKey: ['tokens', chainId, sources.map((s) => `${s.version}:${s.factory}`).join(',')],
    queryFn: () => {
      if (!client) throw new Error('No rpc client');
      return fetchAllTokens(client, chainId);
    },
    enabled: !!client && !!addresses && sources.length > 0,
    staleTime: 60_000,
    gcTime: 5 * 60_000,
  });
  return { ...query, chainId, supported: !!addresses && sources.length > 0 };
}

/** One token by address. A malformed route parameter never reaches a chain read. */
export function useToken(param: string | undefined): {
  token: TokenRecord | undefined;
  validAddress: boolean;
  isLoading: boolean;
  error: Error | null;
  supported: boolean;
} {
  const all = useTokens();
  const validAddress = !!param && isAddress(param, { strict: false });
  const token = useMemo(
    () => (validAddress ? all.data?.find((t) => t.token.toLowerCase() === param!.toLowerCase()) : undefined),
    [all.data, param, validAddress]
  );
  return { token, validAddress, isLoading: all.isLoading, error: all.error, supported: all.supported };
}
