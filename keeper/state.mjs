// Persistent runner state (fly volume): weekly timers, last run and last result per keeper, the tx in flight.
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

export function keeperState(state, id) {
  state.keepers[id] ??= { lastRunAt: null, lastAttemptAt: null, lastResult: null, lastTx: null, consecutiveReverts: 0, lastRevertAt: null };
  return state.keepers[id];
}
