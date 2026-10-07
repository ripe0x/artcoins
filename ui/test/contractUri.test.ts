import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { Address } from 'viem';
import { CONTRACT_URI_GAS, ReadTimeout, readContractUri, withTimeout } from '../src/lib/contractUri.ts';

const TOKEN = '0x61C9d89fe1212F6b55fF888816A151463287B8ae' as Address;

test('readContractUri: its own call with an explicit gas limit', async () => {
  const calls: (bigint | undefined)[] = [];
  const uri = await readContractUri({ readContract: async (a) => { calls.push(a.gas); return 'data:application/json,{}'; } }, TOKEN);
  assert.equal(uri, 'data:application/json,{}');
  assert.deepEqual(calls, [CONTRACT_URI_GAS]);
});

test('readContractUri: a node that refuses the explicit gas gets one retry without it', async () => {
  const calls: (bigint | undefined)[] = [];
  const uri = await readContractUri(
    { readContract: async (a) => { calls.push(a.gas); if (a.gas !== undefined) throw new Error('gas too high'); return '{"name":"x"}'; } },
    TOKEN
  );
  assert.equal(uri, '{"name":"x"}');
  assert.deepEqual(calls, [CONTRACT_URI_GAS, undefined]);
});

test('readContractUri: both calls failing throws, so the page shows a placeholder', async () => {
  await assert.rejects(readContractUri({ readContract: async () => { throw new Error('out of gas'); } }, TOKEN), /out of gas/);
});

test('readContractUri: a slow renderer times out and is not retried', async () => {
  let n = 0;
  await assert.rejects(
    readContractUri({ readContract: () => { n++; return new Promise(() => {}); } }, TOKEN, 30),
    (e: unknown) => e instanceof ReadTimeout
  );
  assert.equal(n, 1);
});

test('readContractUri: a non string answer is a failure', async () => {
  await assert.rejects(readContractUri({ readContract: async () => 5n }, TOKEN), /no string/);
});

test('withTimeout passes a fast result through', async () => {
  assert.equal(await withTimeout(Promise.resolve(7), 1000), 7);
});
