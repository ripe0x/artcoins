// 1. the token list loads from the registry deploy block and shows coin 111
import { test, expect, isNoise } from './fixtures';
import { COIN_111 } from './constants';

test('token list discovers 111 from the current factory logs', async ({ page, consoleLog }) => {
  await page.goto('/tokens');
  await expect(page.getByRole('heading', { name: 'All Tokens' })).toBeVisible();
  const card = page.locator(`a[href="/tokens/${COIN_111}"]`);
  await expect(card).toBeVisible({ timeout: 120_000 });
  await expect(card).toContainText('permanent collection');
  await expect(card).toContainText('111');
  await expect(card).toContainText('artcoins factory v1');
  // launch block from the registry coin list
  await expect(card).toContainText('block 25275351');
  await expect(page.getByText(/^1 token total$/)).toBeVisible();
  // a card image, when present, obeys the image policy
  const img = card.locator('img');
  if (await img.count()) {
    const src = (await img.getAttribute('src')) ?? '';
    expect(src).toMatch(/^(https:\/\/|data:image\/)/);
    expect(await img.getAttribute('referrerpolicy')).toBe('no-referrer');
  }
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});
