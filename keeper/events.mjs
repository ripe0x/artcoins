// Decodes keeper receipts and revert data: the skip events (FlushSkipped, ConvertSkipped, StepSkipped), the run
// summaries (KeeperRun, SwapperServiced) and errors (InsufficientGas, and the reason bytes inside skip events).
import { decodeErrorResult, isAddressEqual, parseEventLogs } from 'viem';
import { abiFor, reasonsAbi } from './abi.mjs';

const SKIP_EVENTS = new Set(['FlushSkipped', 'ConvertSkipped', 'StepSkipped']);
export const STEP_NAMES = Object.freeze({
  '111': { 1: 'collect', 2: 'flush', 3: 'convert' },
  layer: { 1: 'collect', 2: 'claim', 3: 'processFees', 4: 'processBurnLayer', 5: 'processBurnWeth' },
  v2: { 1: 'collect', 2: 'flush', 3: 'convert', 4: 'erc165 probe' },
});

/// revert or reason bytes to { name, args } using the keeper abi plus every known downstream error.
/// Error(string) and Panic(uint256) are built in. Unknown selectors come back as { name: null, raw }.
export function decodeReason(data, kind) {
  if (!data || data === '0x') return { name: null, raw: '0x', note: 'empty revert (out of gas or bare revert)' };
  try {
    const r = decodeErrorResult({ abi: [...(abiFor(kind) || []), ...reasonsAbi], data });
    return { name: r.errorName, args: r.args ?? [] };
  } catch {
    return { name: null, raw: data };
  }
}

export function describeError(decoded, kind) {
  if (decoded.name === 'InsufficientGas') {
    const step = Number(decoded.args[0]);
    return `InsufficientGas(${step}: ${STEP_NAMES[kind]?.[step] ?? 'unknown'})`;
  }
  if (decoded.name) return `${decoded.name}(${(decoded.args || []).map(String).join(', ')})`;
  return decoded.note ? decoded.note : `unknown revert ${String(decoded.raw).slice(0, 10)}`;
}

/// every keeper event in `logs` emitted by `address`, with skip reasons decoded
export function decodeKeeperLogs(logs, kind, address) {
  const mine = logs.filter((l) => l.address && isAddressEqual(l.address, address));
  const parsed = parseEventLogs({ abi: abiFor(kind), logs: mine, strict: false });
  return parsed.map((e) => {
    const out = { event: e.eventName, args: e.args };
    if (SKIP_EVENTS.has(e.eventName)) {
      const d = decodeReason(e.args.reason, kind);
      out.skipped = true;
      out.reason = describeError(d, kind);
      if (e.eventName === 'StepSkipped') out.step = `${Number(e.args.step)}: ${STEP_NAMES.layer[Number(e.args.step)] ?? '?'}`;
    }
    return out;
  });
}

/// `SwapperServiced` events of a v2 run as { swapper, flushed, converted }
export function servicedFrom(decoded) {
  return decoded.filter((e) => e.event === 'SwapperServiced').map((e) => ({ swapper: e.args.swapper, flushed: e.args.flushed, converted: e.args.converted }));
}

/// walks a viem error chain for revert bytes
export function revertDataOf(err) {
  for (let e = err; e; e = e.cause) {
    if (typeof e.data === 'string' && e.data.startsWith('0x')) return e.data;
    if (e.data && typeof e.data.data === 'string') return e.data.data;
    if (e.raw && typeof e.raw === 'string') return e.raw;
  }
  return null;
}
