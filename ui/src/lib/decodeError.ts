import { BaseError, ContractFunctionRevertedError } from 'viem';

/**
 * Walks a thrown error looking for a decoded contract revert (the viem
 * `BaseError` -> `ContractFunctionRevertedError` chain produced by
 * `useWriteContract`/`useWaitForTransactionReceipt`), and maps the revert's
 * error name to a human-readable message via the caller-supplied `messages`
 * map. Falls back to `Reverted: <name>` for an unmapped revert name (the
 * shared default both original call sites used), then to the error's
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
  fallback: (name: string) => string = name => `Reverted: ${name}`
): string {
  if (err instanceof BaseError) {
    const reverted = err.walk(e => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? reverted.reason ?? 'Reverted';
      return messages[name] ?? fallback(name);
    }
    return err.shortMessage ?? err.message;
  }
  return err instanceof Error ? err.message : String(err);
}
