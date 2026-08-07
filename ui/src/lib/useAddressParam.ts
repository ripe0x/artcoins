import { useParams } from 'react-router-dom';
import { isAddress, type Address } from 'viem';

export interface UseAddressParamResult {
  /**
   * Lowercased, validated address — `undefined` when the route param is
   * missing or not a syntactically valid address. Callers should treat
   * `undefined` the same way they treat "not found": short-circuit before
   * kicking off any event fetch / RPC read / allowlist request.
   */
  address: Address | undefined;
  /** Whether the raw route param is a syntactically valid address. */
  isValid: boolean;
  /** The raw, un-lowercased route param (possibly `''`), for display in error states. */
  raw: string;
}

/**
 * Reads an address-shaped route param (default `:address`, matching every
 * route that uses one — `/tokens/:address`, `/tokens/:address/claim`,
 * `/tokens/:address/referrals`) and validates it with viem's `isAddress`
 * before any consumer uses it to drive a network request.
 *
 * Visiting e.g. `/tokens/foo` previously ran a full on-chain event fetch
 * (and, on ClaimPage, an additional `fetch('/allowlists/foo.json')`) before
 * concluding "not found". Feeding `address: undefined` into hooks like
 * `useTokenEvent` — which already guard their queries on the address being
 * present/well-formed — short-circuits that immediately, with zero network
 * calls, for any malformed param.
 */
export function useAddressParam(paramName = 'address'): UseAddressParamResult {
  const params = useParams<Record<string, string | undefined>>();
  const raw = params[paramName] ?? '';
  const isValid = raw !== '' && isAddress(raw, { strict: false });
  return {
    address: isValid ? (raw.toLowerCase() as Address) : undefined,
    isValid,
    raw,
  };
}
