import { BaseError, ContractFunctionRevertedError } from 'viem';

/** Readable reason for a failed simulation or write: the decoded custom error when there is one. */
export function describeError(err: unknown): string {
  if (err instanceof BaseError) {
    const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName;
      if (name) {
        const args = reverted.data?.args?.length ? `(${reverted.data.args.map((a) => String(a)).join(', ')})` : '';
        return `reverted: ${name}${args}`;
      }
      if (reverted.reason) return `reverted: ${reverted.reason}`;
      return 'reverted without a reason';
    }
    return err.shortMessage || err.message.split('\n')[0];
  }
  return err instanceof Error ? err.message.split('\n')[0] : String(err);
}
