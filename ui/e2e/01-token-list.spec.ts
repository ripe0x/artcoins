// 1. the token list loads from the registry deploy block and shows coin 111
import { test, expect, isNoise } from './fixtures';
import { COIN_111, LAYER } from './constants';

test('token list discovers 111 (current factory) and LAYER (legacy factory) from the registry deploy blocks', async ({ page, consoleLog }) => {
  await page.goto('/tokens');
  await expect(page.getByRole('heading', { name: 'All Tokens' })).toBeVisible();
  const card = page.locator(`a[href="/tokens/${COIN_111}"]`);
  await expect(card).toBeVisible({ timeout: 120_000 });
  await expect(card).toContainText('permanent collection');
  await expect(card).toContainText('111');
  await expect(card).toContainText('artcoins factory v1');
  // launch block from the registry coin list
  await expect(card).toContainText('block 25275351');
  // LAYER comes from the legacy factory of the registry
  const layer = page.locator(`a[href="/tokens/${LAYER}"]`);
  await expect(layer).toBeVisible({ timeout: 120_000 });
  await expect(layer).toContainText('LAYER');
  await expect(layer).toContainText('artcoins factory v1 (legacy)');
  await expect(layer).toContainText('block 25045152');
  await expect(page.getByText(/^2 tokens total$/)).toBeVisible();
  // a card image, when present, obeys the image policy
  const img = card.locator('img');
  if (await img.count()) {
    const src = (await img.getAttribute('src')) ?? '';
    expect(src).toMatch(/^(https:\/\/|data:image\/)/);
    expect(await img.getAttribute('referrerpolicy')).toBe('no-referrer');
  }
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});
