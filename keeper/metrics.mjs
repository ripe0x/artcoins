// plain text counters and gauges for /metrics (prometheus text format, no client library)
export class Metrics {
  constructor() { this.counters = new Map(); this.gauges = new Map(); }
  static key(name, labels = {}) {
    const l = Object.entries(labels).map(([k, v]) => `${k}="${String(v).replace(/["\\\n]/g, '_')}"`).join(',');
    return l ? `${name}{${l}}` : name;
  }
  inc(name, labels, by = 1) { const k = Metrics.key(name, labels); this.counters.set(k, (this.counters.get(k) || 0) + by); }
  set(name, labels, v) { this.gauges.set(Metrics.key(name, labels), v); }
  get(name, labels) { const k = Metrics.key(name, labels); return this.counters.get(k) ?? this.gauges.get(k); }
  render() {
    const lines = [];
    const names = new Set();
    for (const [map, type] of [[this.counters, 'counter'], [this.gauges, 'gauge']]) {
      for (const [k, v] of [...map.entries()].sort()) {
        const n = k.split('{')[0];
        if (!names.has(n)) { lines.push(`# TYPE ${n} ${type}`); names.add(n); }
        lines.push(`${k} ${typeof v === 'bigint' ? v.toString() : v}`);
      }
    }
    return lines.join('\n') + '\n';
  }
}
