// Persistent runner state (fly volume): weekly timers, last run and last result per keeper, the tx in flight with
// every hash signed for its nonce and its fees (replacements and cancels resume from here after a restart).
// Written atomically (temp file plus rename) after every change, so a restart never re runs a finished run.
import fs from 'node:fs';
import path from 'node:path';

export const STATE_VERSION = 1;
export const emptyState = () => ({ version: STATE_VERSION, keepers: {}, inFlight: null, lastTickAt: null });

const replacer = (_k, v) => (typeof v === 'bigint' ? { $big: v.toString() } : v);
const reviver = (_k, v) => (v && typeof v === 'object' && typeof v.$big === 'string' && Object.keys(v).length === 1 ? BigInt(v.$big) : v);

/// reads the state file. missing file: empty state. unreadable or wrong version: throws, because starting
/// from empty would re run every keeper (the weekly timers restart) and hide a broken volume.
export function loadState(file) {
  if (!fs.existsSync(file)) return emptyState();
  const s = JSON.parse(fs.readFileSync(file, 'utf8'), reviver);
  if (s.version !== STATE_VERSION) throw new Error(`state ${file}: version ${s.version}, expected ${STATE_VERSION}`);
  return { ...emptyState(), ...s, keepers: s.keepers || {} };
}

/// KR-10: the state directory must exist (the fly volume mount point). a missing mount would otherwise start from
/// empty state on the root fs, re run every keeper and forget the tx in flight. EPHEMERAL_STATE=1 allows it.
export function checkStateDir(file, ephemeral) {
  const dir = path.dirname(path.resolve(file));
  if (fs.existsSync(dir)) return dir;
  if (ephemeral) {
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  }
  throw new Error(`state directory ${dir} does not exist (volume not mounted?). set EPHEMERAL_STATE=1 to run without one`);
}

export function saveState(file, state) {
  fs.mkdirSync(path.dirname(path.resolve(file)), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  const fd = fs.openSync(tmp, 'w');
  try {
    fs.writeSync(fd, JSON.stringify(state, replacer, 2) + '\n');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(tmp, file);
}

/// per keeper record. `lastTx` is only ever a mined tx. `outcomes` counts every send and receipt outcome (KR-11),
/// `nextCheckAt` is the cadence (KR-14), `backoffUntil` / `noProgress` the no progress backoff (KR-01)
export function keeperState(state, id) {
  const s = (state.keepers[id] ??= {});
  s.lastRunAt ??= null;
  s.lastAttemptAt ??= null;
  s.lastResult ??= null;
  s.lastTx ??= null;
  s.consecutiveReverts ??= 0;
  s.lastRevertAt ??= null;
  s.nextCheckAt ??= null;
  s.backoffUntil ??= null;
  s.backoffSeconds ??= 0;
  s.noProgress ??= null;
  s.outcomes ??= {};
  s.lastOutcome ??= null;
  return s;
}
