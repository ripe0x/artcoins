// 7. the airdrop claim page renders for 111 (no allowlist published, no airdrop extension on the current stack)
import { test, expect, connectWallet, isNoise } from './fixtures';
import { COIN_111 } from './constants';

test('claim page renders without a wallet and with one', async ({ page, makeWallet, consoleLog }) => {
  const wallet = await makeWallet({ label: 'claim-viewer' });
  await page.goto(`/tokens/${COIN_111}/claim`);
  const main = page.locator('main, #root > div').first();
  await expect(main).toBeVisible();
  await expect(page.getByText('Page not found.')).toHaveCount(0);
  // the page must settle on a readable state, not a spinner or a crash
  await expect(page.getByText(/allowlist|airdrop|claim/i).first()).toBeVisible({ timeout: 60_000 });
  const before = await page.locator('body').innerText();
  await connectWallet(page, wallet.address);
  await page.waitForTimeout(2_000);
  const after = await page.locator('body').innerText();
  test.info().annotations.push({ type: 'claim page text (no wallet)', description: before.replace(/\s+/g, ' ').slice(0, 600) });
  test.info().annotations.push({ type: 'claim page text (wallet)', description: after.replace(/\s+/g, ' ').slice(0, 600) });
  await page.screenshot({ path: test.info().outputPath('claim.png'), fullPage: true });
  // a malformed address never reaches a read
  await page.goto('/tokens/0xnotanaddress/claim');
  await expect(page.getByText('Not a token address.')).toBeVisible();
  expect(wallet.sent).toHaveLength(0);
  expect(consoleLog.filter((e) => e.type === 'pageerror')).toEqual([]);
  test.info().annotations.push({ type: 'console', description: JSON.stringify(consoleLog.filter((e) => !isNoise(e) && e.type !== 'warning')).slice(0, 800) });
});
