import { test, expect, connectWallet } from './fixtures';
import { fund, rpc } from './fork';
import { COIN_111 } from './constants';

test('explore 111 widget', async ({ page, makeWallet }) => {
  await rpc('anvil_setBlockGasLimit', ['0x' + (250_000_000).toString(16)]);
  const wallet = await makeWallet({ label: 'explore' });
  await fund(wallet.address, '1');
  await page.setViewportSize({ width: 1280, height: 2400 });
  await page.goto(`/tokens/${COIN_111}`);
  await connectWallet(page, wallet.address);
  await page.getByPlaceholder('0.0').fill('0.01');
  await expect(page.getByText(/^Min received/)).toBeVisible({ timeout: 60_000 });
  await page.screenshot({ path: test.info().outputPath('111-buy.png'), fullPage: true });
  await page.getByPlaceholder('0.0').fill('0.5');
  await page.waitForTimeout(3000);
  await page.screenshot({ path: test.info().outputPath('111-buy-big.png'), fullPage: true });
  await page.getByRole('button', { name: 'Sell', exact: true }).click();
  await page.getByPlaceholder('0.0').fill('100000');
  await page.waitForTimeout(4000);
  await page.screenshot({ path: test.info().outputPath('111-sell.png'), fullPage: true });
  await rpc('anvil_setBlockGasLimit', ['0x' + (60_000_000).toString(16)]);
});
