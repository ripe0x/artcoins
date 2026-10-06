import { test } from 'node:test';
import assert from 'node:assert/strict';
import { factorySources } from '../src/lib/discovery.ts';
import { STACKS } from '../src/lib/deployments.generated.ts';

test('factorySources: mainnet scans the current and the legacy factory (LAYER) from their registry deploy blocks', () => {
  const s = factorySources(1);
  const cur = s.find((x) => x.factory === STACKS.current.factory);
  const leg = s.find((x) => x.factory === STACKS.legacy.factory);
  assert.ok(cur && !cur.legacy);
  assert.ok(leg && leg.legacy);
  assert.equal(cur.fromBlock, STACKS.current.deployBlock);
  assert.equal(leg.fromBlock, STACKS.legacy.deployBlock);
  assert.equal(leg.version, 1);
});

test('factorySources: the open stack launched nothing and is not scanned, other chains scan nothing', () => {
  assert.ok(!factorySources(1).some((x) => x.factory === STACKS.open.factory));
  assert.deepEqual(factorySources(11155111), []);
});
