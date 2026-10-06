import React from 'react';
import ReactDOM from 'react-dom/client';
import { http } from 'wagmi';
import { WagmiProvider } from 'wagmi';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { RainbowKitProvider, getDefaultConfig, darkTheme } from '@rainbow-me/rainbowkit';
import { mainnet } from 'wagmi/chains';
import { BrowserRouter } from 'react-router-dom';
import '@rainbow-me/rainbowkit/styles.css';
import './index.css';
import App from './App';

const projectId = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID;
if (!projectId) {
  throw new Error(
    'Missing VITE_WALLETCONNECT_PROJECT_ID. Copy ui/.env.example to ui/.env and fill in values.'
  );
}

// RPC for reads. Nothing secret goes into the bundle (UI-19): everything prefixed VITE_ is public.
//   VITE_MAINNET_RPC_URL           a public or proxied endpoint without a key in the url (preferred)
//   VITE_ALCHEMY_API_KEY           used ONLY when VITE_ALCHEMY_KEY_RESTRICTED=1, which asserts that the key is
//                                  restricted to this site's domains in the Alchemy dashboard. An unrestricted
//                                  key in a public bundle can be copied and spent by anyone, so it is ignored.
//   neither                        the tenderly public gateway the rest of the repo defaults to (rate limited)
const alchemyKey = import.meta.env.VITE_ALCHEMY_API_KEY;
const alchemyRestricted = import.meta.env.VITE_ALCHEMY_KEY_RESTRICTED === '1';
if (alchemyKey && !alchemyRestricted) {
  console.warn(
    'VITE_ALCHEMY_API_KEY is set but VITE_ALCHEMY_KEY_RESTRICTED is not 1: the key is ignored. Restrict it to your domains in the Alchemy dashboard, then set VITE_ALCHEMY_KEY_RESTRICTED=1.'
  );
}
const mainnetRpc =
  import.meta.env.VITE_MAINNET_RPC_URL ||
  (alchemyKey && alchemyRestricted ? `https://eth-mainnet.g.alchemy.com/v2/${alchemyKey}` : 'https://mainnet.gateway.tenderly.co');

// Mainnet only: the registry, the v2 stack and every contract abi in this ui are mainnet. Explicit
// transports so that all reads (including RainbowKit's balance fetch) use the same endpoint.
const config = getDefaultConfig({
  appName: 'artcoins token launcher',
  projectId,
  chains: [mainnet],
  transports: { [mainnet.id]: http(mainnetRpc) },
});

const queryClient = new QueryClient();

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={darkTheme({ accentColor: '#7c3aed' })}>
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </React.StrictMode>
);
