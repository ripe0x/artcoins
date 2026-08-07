import React from 'react';
import ReactDOM from 'react-dom/client';
import { http } from 'wagmi';
import { WagmiProvider } from 'wagmi';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { RainbowKitProvider, getDefaultConfig, darkTheme } from '@rainbow-me/rainbowkit';
import { mainnet, sepolia } from 'wagmi/chains';
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

const alchemyKey = import.meta.env.VITE_ALCHEMY_API_KEY;

// Pass explicit transports so that ALL RPC calls (including RainbowKit's
// internal balance fetch for the ConnectButton) go through Alchemy.
// Overriding chain.rpcUrls alone is not enough — getDefaultConfig builds its
// own transports and may fall back to unreliable public RPCs, producing NaN.
const config = getDefaultConfig({
  appName: 'artcoins',
  projectId,
  chains: [mainnet, sepolia],
  ...(alchemyKey
    ? {
        transports: {
          [mainnet.id]: http(`https://eth-mainnet.g.alchemy.com/v2/${alchemyKey}`),
          [sepolia.id]: http(`https://eth-sepolia.g.alchemy.com/v2/${alchemyKey}`),
        },
      }
    : {}),
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
