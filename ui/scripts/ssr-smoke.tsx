// Render smoke test: server renders every page with a disconnected wagmi config, no chain reads run
// (effects and queries do not execute in a server render). Catches hook order errors, bad imports and
// render time exceptions that tsc cannot. Run: npm run smoke
import { renderToString } from 'react-dom/server';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { WagmiProvider, createConfig, http } from 'wagmi';
import { mainnet } from 'wagmi/chains';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { RainbowKitProvider } from '@rainbow-me/rainbowkit';
import DeployPage from '../src/pages/DeployPage';
import TokensListPage from '../src/pages/TokensListPage';
import TokenDetailPage from '../src/pages/TokenDetailPage';
import ClaimPage from '../src/pages/ClaimPage';
import ReferralsPage from '../src/pages/ReferralsPage';
import Footer from '../src/components/Footer';

const config = createConfig({ chains: [mainnet], transports: { [mainnet.id]: http('http://127.0.0.1:1') }, ssr: true });
const coin = '0x61C9d89fe1212F6b55fF888816A151463287B8ae';

function render(path: string, element: React.ReactElement, route: string): string {
  const qc = new QueryClient();
  return renderToString(
    <WagmiProvider config={config}>
      <QueryClientProvider client={qc}>
        <RainbowKitProvider>
          <MemoryRouter initialEntries={[path]}>
            <Routes>
              <Route path={route} element={element} />
            </Routes>
          </MemoryRouter>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}

const cases: [string, React.ReactElement, string, string[]][] = [
  ['/', <DeployPage />, '/', ['Launching is closed', 'owner only on the current factory', 'Token']],
  ['/tokens', <TokensListPage />, '/tokens', ['All Tokens']],
  [`/tokens/${coin}`, <TokenDetailPage />, '/tokens/:address', []],
  ['/tokens/not-an-address', <TokenDetailPage />, '/tokens/:address', ['Not a token address']],
  [`/tokens/${coin}/claim`, <ClaimPage />, '/tokens/:address/claim', []],
  ['/tokens/../x/claim', <ClaimPage />, '/tokens/:address/claim', []],
  [`/tokens/${coin}/referrals`, <ReferralsPage />, '/tokens/:address/referrals', []],
  ['/', <Footer />, '/', ['artcoins token launcher']],
];

let failed = 0;
for (const [path, el, route, expect] of cases) {
  try {
    const html = render(path, el, route);
    const missing = expect.filter((t) => !html.includes(t));
    if (missing.length) {
      failed++;
      console.error(`FAIL ${path}: missing ${JSON.stringify(missing)}`);
    } else console.log(`ok   ${path} (${html.length} bytes)`);
  } catch (e) {
    failed++;
    console.error(`FAIL ${path}:`, e);
  }
}
process.exitCode = failed ? 1 : 0;
