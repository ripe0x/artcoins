// 5a. deploy page with no v2 stack configured: closed, send disabled, even with a wallet connected
import { test, expect, connectWallet, isNoise } from './fixtures';

test('deploy page without a v2 stack says launches are owner only and disables send', async ({ page, makeWallet, consoleLog }) => {
  const wallet = await makeWallet({ label: 'deploy-stranger' });
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Launch a coin' })).toBeVisible();
  const status = page.getByRole('status');
  await expect(status).toContainText('Launching is closed');
  await expect(status).toContainText(/launches are owner only on the current factory/i, { timeout: 60_000 });
  // factory numbers come from the current factory
  await expect(page.getByText(/Deploy fee: 0\.069 ETH/)).toBeVisible();
  await expect(page.getByText(/Public launches: closed/)).toBeVisible();

  await connectWallet(page, wallet.address);
  // fill a valid looking form, the page must still refuse
  await page.getByPlaceholder('My Token').fill('E2E Closed');
  await page.getByPlaceholder('MTK').fill('SHUT');
  await page.getByRole('button', { name: /Review and launch/ }).click();
  const send = page.getByRole('button', { name: /owner only on the current factory|Deploy token/ }).last();
  await expect(send).toBeVisible();
  await expect(send).toBeDisabled();
  await expect(send).toContainText(/owner only on the current factory/i);
  await page.screenshot({ path: test.info().outputPath('deploy-closed.png'), fullPage: true });
  expect(wallet.sent).toHaveLength(0);
  expect(consoleLog.filter((e) => e.type !== 'warning' && !isNoise(e))).toEqual([]);
});
