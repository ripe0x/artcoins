// 2. token page for 111: contract reads decode, image policy, no self asserted verified badge
import { test, expect, isNoise, infoRow } from './fixtures';
import { rpc } from './fork';
import { COIN_111 } from './constants';
import type { Page } from '@playwright/test';

const row = infoRow;

async function checkReads(page: Page) {
  await expect(page.getByRole('heading', { level: 1 })).toContainText('111', { timeout: 120_000 });
  // token card
  await expect(row(page, 'Symbol')).toContainText('111');
  await expect(row(page, 'Supply')).toContainText('1,110,000,000 111');
  await expect(row(page, 'Admin')).toContainText(/0xA96a.*6258/i);
  await expect(row(page, 'Factory')).toContainText(/0x4959.*4e0e/i);
  await expect(row(page, 'Renderer')).toContainText(/0x7604.*eEc7/i);
  // pool card: native pair, tick spacing from the locker pool key, fees from the hook skimConfig
  await expect(row(page, 'Pair')).toContainText('native ETH');
  await expect(row(page, 'Tick spacing')).toContainText('200');
  await expect(row(page, 'Fees')).toContainText('0.50% lp + 6.00% skim');
  await expect(row(page, 'Price')).toContainText(/\d.*ETH/);
  // fee distribution
  await expect(page.getByText('83.33%')).toBeVisible();
  await expect(page.getByText('16.67%')).toBeVisible();
  await expect(page.getByText(/0\.25% of volume, paid from the protocol share/)).toBeVisible();
  // lp rewards: one recipient, 100%
  await expect(row(page, 'Recipient 1')).toContainText(/0xeBD9.*A961.*\(100%\)/i);
  // the swap widget is offered (locker pool id equals the announced pool id)
  await expect(page.getByRole('heading', { name: 'Swap' })).toBeVisible();
}

async function checkNoVerifiedBadge(page: Page) {
  const header = page.locator('h1').locator('..');
  const badges = header.locator('span.rounded, span.rounded-full');
  const texts = (await badges.allInnerTexts()).map((t) => t.trim());
  expect(texts).toContain('artcoins factory v1');
  for (const t of texts) expect(t.toLowerCase()).not.toContain('verified');
  // nowhere on the page is there a badge like element claiming verification
  await expect(page.locator('span.rounded-full, span.rounded', { hasText: /verified/i })).toHaveCount(0);
}

test('111 token page, rpc with a 60M eth_call gas cap (anvil default)', async ({ page, consoleLog }) => {
  await page.goto(`/tokens/${COIN_111}`);
  await checkReads(page);
  await checkNoVerifiedBadge(page);
  // contractURI needs ~180M gas: on a capped rpc it fails, imageUrl() is empty, so the placeholder shows
  const imgBtn = page.getByRole('button', { name: 'View full metadata' });
  const img = imgBtn.locator('img');
  test.info().annotations.push({ type: 'image', description: `img count at 60M cap: ${await img.count()}` });
  if (await img.count()) {
    expect(await img.getAttribute('src')).toMatch(/^(https:\/\/|data:image\/)/);
  } else {
    await expect(imgBtn).toContainText('111');
  }
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});

test('111 token page, rpc that allows the renderer (block gas 250M)', async ({ page, consoleLog }) => {
  await rpc('anvil_setBlockGasLimit', ['0x' + (250_000_000).toString(16)]);
  try {
    await page.goto(`/tokens/${COIN_111}`);
    await checkReads(page);
    await checkNoVerifiedBadge(page);
    const img = page.getByRole('button', { name: 'View full metadata' }).locator('img');
    await expect(img).toHaveCount(1, { timeout: 120_000 });
    const src = (await img.getAttribute('src')) ?? '';
    // image policy: only https, ipfs/ar via a https gateway, or data:image, loaded without a referrer
    expect(src).toMatch(/^(https:\/\/|data:image\/)/);
    expect(await img.getAttribute('referrerpolicy')).toBe('no-referrer');
    test.info().annotations.push({ type: 'image', description: src.slice(0, 80) });
    // description comes from the on chain json
    await expect(page.getByText(/PERMANENT COLLECTION is an ERC20 artwork/i).first()).toBeVisible();
    await page.getByRole('button', { name: 'View full metadata' }).click();
    await expect(page.getByRole('dialog').or(page.locator('[role="dialog"], .fixed.inset-0')).first()).toBeVisible();
  } finally {
    await rpc('anvil_setBlockGasLimit', ['0x' + (60_000_000).toString(16)]);
  }
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});
