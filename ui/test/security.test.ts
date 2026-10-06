import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cleanText, lookalikeKey, safeImageUrl, safeLinkUrl } from '../src/lib/security';
import { checkReferrer } from '../src/lib/referrerCheck';

test('images: only https, ipfs, ar and data:image schemes survive', () => {
  assert.equal(safeImageUrl('https://example.com/a.png'), 'https://example.com/a.png');
  assert.equal(safeImageUrl('ipfs://bafybeigdyrzt5/token.png'), 'https://ipfs.io/ipfs/bafybeigdyrzt5/token.png');
  assert.equal(safeImageUrl('ipfs://ipfs/bafybeigdyrzt5'), 'https://ipfs.io/ipfs/bafybeigdyrzt5');
  assert.equal(safeImageUrl('ar://AbC_123-x'), 'https://arweave.net/AbC_123-x');
  assert.ok(safeImageUrl('data:image/png;base64,iVBORw0KGgo='));
  for (const bad of [
    'http://example.com/a.png',
    'javascript:alert(1)',
    'data:text/html;base64,PHNjcmlwdD4=',
    'data:application/json,{}',
    'file:///etc/passwd',
    'blob:https://x/abc',
    '//example.com/a.png',
    'example.com/a.png',
    'https://user:pw@example.com/a.png',
    'ipfs://../../etc',
    'ftp://example.com/a.png',
    '',
  ]) {
    assert.equal(safeImageUrl(bad), null, bad);
  }
  assert.equal(safeImageUrl('data:image/png;base64,' + 'A'.repeat(300_000)), null);
  assert.equal(safeImageUrl(null), null);
});

test('links: https only', () => {
  assert.ok(safeLinkUrl('https://example.com/x'));
  assert.equal(safeLinkUrl('http://example.com'), null);
  assert.equal(safeLinkUrl('data:text/html,hi'), null);
  assert.equal(safeLinkUrl('javascript:alert(1)'), null);
});

test('text: bidi and control characters are stripped and length clamped', () => {
  assert.equal(cleanText('ab‮cd​\u0007ef', 20), 'abcdef');
  assert.equal(cleanText('x'.repeat(100), 10), 'xxxxxxxxxx…');
  assert.equal(lookalikeKey('ЅCAM'.normalize('NFKD')), lookalikeKey('ЅCAM'));
  assert.equal(lookalikeKey('Perma-nent Collection!'), lookalikeKey('permanent collection'));
});

test('referrer: checksum, zero and self are rejected', () => {
  const ok = '0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A4';
  assert.deepEqual(checkReferrer(ok), { ok: true, address: ok });
  assert.equal(checkReferrer(ok.toLowerCase()).ok, true); // all lowercase carries no checksum
  assert.equal(checkReferrer('0x41c3BD8A36f8fE9Bb77900ca02400b32BB35A6A5').ok, false); // wrong checksum
  assert.equal(checkReferrer('0x0000000000000000000000000000000000000000').ok, false);
  assert.equal(checkReferrer(ok, ok.toLowerCase()).ok, false); // self
  assert.equal(checkReferrer('nonsense').ok, false);
  assert.equal(checkReferrer(null).ok, false);
});
