import { useCallback, useEffect, useRef } from 'react';
import { useWaitForTransactionReceipt, useWriteContract } from 'wagmi';
import type { TransactionReceipt } from 'viem';

/**
 * `confirming` = waiting on the user's wallet to sign/submit.
 * `pending`    = signed and broadcast; waiting for the transaction to be mined.
 * `confirmed`  = the receipt landed with a success status.
 * `error`      = either the wallet rejected/failed the write, or the mined
 *                transaction reverted (see `writeError` / `receiptError`).
 */
export type TxFlowStatus = 'idle' | 'confirming' | 'pending' | 'confirmed' | 'error';

export interface UseTxFlowOptions {
  /**
   * Fired exactly once per transaction hash, from an effect (never during
   * render), after the receipt for that hash lands successfully. Safe to
   * pass a new function identity on every render — only the hash-guard ref
   * decides whether it fires again.
   */
  onConfirmed?: (receipt: TransactionReceipt) => void;
}

export interface UseTxFlowResult {
  /**
   * Same function as wagmi's `useWriteContract().writeContract` — generic
   * per call site, so pass `{ address, abi, functionName, args, value? }`
   * exactly as you would to `writeContract` directly.
   */
  submit: ReturnType<typeof useWriteContract>['writeContract'];
  status: TxFlowStatus;
  hash: `0x${string}` | undefined;
  receipt: TransactionReceipt | undefined;
  /** Error from the write step itself — e.g. the wallet rejected signing. */
  writeError: Error | null;
  /** Error from waiting on the receipt — e.g. the transaction reverted on chain. */
  receiptError: Error | null;
  /** `writeError ?? receiptError`, for callers that don't need to distinguish. */
  error: Error | null;
  /** Clears write/receipt state and the onConfirmed hash guard, back to idle. */
  reset: () => void;
}

/**
 * Wraps `useWriteContract` + `useWaitForTransactionReceipt` into a single
 * status machine so callers never have to hand-roll a "confirmed" state or
 * fake it with a timer. Modeled on ClaimPage's original (correct) pattern.
 */
export function useTxFlow(options: UseTxFlowOptions = {}): UseTxFlowResult {
  const { onConfirmed } = options;

  const {
    writeContract,
    data: hash,
    isPending: isSigning,
    error: writeError,
    reset: resetWrite,
  } = useWriteContract();

  const {
    data: receipt,
    isLoading: isMining,
    isSuccess: isConfirmed,
    error: receiptError,
  } = useWaitForTransactionReceipt({ hash });

  // Guards onConfirmed against double-firing across re-renders for the same
  // hash (e.g. a parent re-render after the callback triggers a refetch).
  const notifiedHashRef = useRef<`0x${string}` | undefined>(undefined);

  useEffect(() => {
    if (isConfirmed && receipt && hash && notifiedHashRef.current !== hash) {
      notifiedHashRef.current = hash;
      onConfirmed?.(receipt);
    }
  }, [isConfirmed, receipt, hash, onConfirmed]);

  const reset = useCallback(() => {
    notifiedHashRef.current = undefined;
    resetWrite();
  }, [resetWrite]);

  let status: TxFlowStatus = 'idle';
  if (writeError || receiptError) {
    status = 'error';
  } else if (isConfirmed) {
    status = 'confirmed';
  } else if (isMining) {
    status = 'pending';
  } else if (isSigning) {
    status = 'confirming';
  }

  return {
    submit: writeContract,
    status,
    hash,
    receipt,
    writeError: (writeError as Error | null) ?? null,
    receiptError: (receiptError as Error | null) ?? null,
    error: (writeError as Error | null) ?? (receiptError as Error | null) ?? null,
    reset,
  };
}
