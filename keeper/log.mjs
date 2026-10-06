// one json line per event on stdout (fly logs). bigints print as decimal strings.
const big = (_k, v) => (typeof v === 'bigint' ? v.toString() : v);
let sink = (line) => process.stdout.write(line + '\n');
export function setLogSink(fn) { sink = fn; }
export function log(level, msg, fields = {}) {
  sink(JSON.stringify({ ts: new Date().toISOString(), level, msg, ...fields }, big));
}
export const info = (m, f) => log('info', m, f);
export const warn = (m, f) => log('warn', m, f);
export const error = (m, f) => log('error', m, f);
