import { BaseError, ContractFunctionRevertedError } from 'viem';

/**
 * Walks a thrown error looking for a decoded contract revert (the viem
 * `BaseError` -> `ContractFunctionRevertedError` chain produced by
 * `useWriteContract`/`useWaitForTransactionReceipt`), and maps the revert's
 * error name to a human-readable message via the caller-supplied `messages`
 * map. If no contract revert is found, also walks the error's `cause` chain
 * for any `BaseError` whose `name` matches a key in `messages` — this covers
 * non-revert failures a caller wants to special-case, like a wallet
 * rejection (`UserRejectedRequestError`) or an underfunded account
 * (`InsufficientFundsError`), which surface as a named error somewhere in
 * the chain rather than as a decoded contract revert.
 *
 * Falls back to a plain, non-technical sentence for an unmapped revert name
 * (deliberately generic — callers that want the raw Solidity error name in
 * their fallback can pass their own `fallback`), then to the error's
 * `shortMessage`/`message`, then to a plain string coercion for non-Error
 * throws.
 *
 * Ported from `ClaimPage.tsx`'s original `decodeClaimError` (the more
 * complete of the two near-identical copies) — each caller now just passes
 * its own error-name -> message map instead of forking the whole walk.
 */
export function decodeContractError(
  err: unknown,
  messages: Record<string, string>,
  fallback: (name: string) => string = () =>
    'The transaction could not be completed. Please try again.'
): string {
  if (err instanceof BaseError) {
    const reverted = err.walk(e => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? reverted.reason ?? 'Reverted';
      return messages[name] ?? fallback(name);
    }
    const named = err.walk(e => e instanceof BaseError && e.name in messages);
    if (named instanceof BaseError) {
      return messages[named.name];
    }
    return err.shortMessage ?? err.message;
  }
  return err instanceof Error ? err.message : String(err);
}
