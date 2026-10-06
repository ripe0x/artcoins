import { test } from 'node:test';
import assert from 'node:assert/strict';
import { getSqrtPriceAtTick, impliedFdvEth, quoteBuyFromFreshPool, Q96, tickToPrice } from '../src/lib/curve';

const rel = (a: number, b: number) => Math.abs(a - b) / Math.abs(b);

test('getSqrtPriceAtTick matches v4 TickMath anchors', () => {
  assert.equal(getSqrtPriceAtTick(0), Q96);
  assert.equal(getSqrtPriceAtTick(-887272), 4295128739n); // TickMath.MIN_SQRT_PRICE
  assert.equal(getSqrtPriceAtTick(887272), 1461446703485210103287273052203988822378723970342n); // MAX_SQRT_PRICE
  for (const t of [-230400, -120000, -1, 1, 60, 230400, 500000]) {
    const got = Number(getSqrtPriceAtTick(t)) / 2 ** 96;
    assert.ok(rel(got, Math.sqrt(tickToPrice(t))) < 1e-9, `tick ${t}`);
  }
});

test('implied fdv of the default tick at 1B supply is about 0.1 eth', () => {
  const fdv = impliedFdvEth(-230400, 1_000_000_000);
  assert.ok(fdv > 0.09 && fdv < 0.11, String(fdv));
});

test('buy from a one position pool matches the closed form', () => {
  // one position [start, start + 60000], 1e27 coins. Closed form for eth in x on a single range:
  // out = L * (sqrtP - sqrtP') with sqrtP' = L*sqrtP/(L + x*sqrtP)  (all in real units)
  const start = -230_400;
  const coin = 10n ** 27n;
  const { coinOut, ethUsed, exhausted } = quoteBuyFromFreshPool(start, [{ tickLower: start, tickUpper: start + 60_000, coinAmount: coin }], 10n ** 17n);
  assert.equal(exhausted, false);
  assert.equal(ethUsed, 10n ** 17n);
  const sqrtP = Math.sqrt(tickToPrice(-start)); // pool frame: price = 1.0001^-start (coin per eth)... token1/token0
  const sqrtU = Math.sqrt(tickToPrice(-start));
  const sqrtL = Math.sqrt(tickToPrice(-(start + 60_000)));
  const L = Number(coin) / (sqrtU - sqrtL);
  const x = 1e17;
  const next = (L * sqrtP) / (L + x * sqrtP);
  const expected = L * (sqrtP - next);
  assert.ok(rel(Number(coinOut), expected) < 1e-9, `${coinOut} vs ${expected}`);
  // price check: 0.1 eth at about 1e-10 eth per coin buys about 1e9 coins
  assert.ok(Number(coinOut) / 1e18 > 5e8 && Number(coinOut) / 1e18 < 1.1e9);
});

test('a buy larger than the pool exhausts it and never returns more than the seeded coin', () => {
  const start = -230_400;
  const coin = 10n ** 27n;
  const r = quoteBuyFromFreshPool(start, [{ tickLower: start, tickUpper: start + 200, coinAmount: coin }], 10n ** 30n);
  assert.equal(r.exhausted, true);
  assert.ok(r.coinOut <= coin);
});
