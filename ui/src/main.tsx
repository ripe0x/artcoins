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
import ErrorBoundary from './components/ErrorBoundary';

/**
 * Renders a minimal, dependency-free "this deployment is misconfigured"
 * screen directly into `#root`. Used when a required env var is missing —
 * deliberately plain inline-styled markup (no Tailwind, no providers) so it
 * still renders even if the rest of the app's setup (wagmi/RainbowKit
 * config, which needs that env var) can't run.
 */
function renderConfigError(rootEl: HTMLElement, missingVar: string) {
  ReactDOM.createRoot(rootEl).render(
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: '1.5rem',
        background: '#09090b',
        color: '#e4e4e7',
        fontFamily: 'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
      }}
    >
      <div
        style={{
          maxWidth: '28rem',
          width: '100%',
          border: '1px solid #27272a',
          borderRadius: '0.75rem',
          background: '#18181b',
          padding: '1.5rem',
          textAlign: 'center',
        }}
      >
        <h1 style={{ fontSize: '1.125rem', fontWeight: 600, margin: 0 }}>
          Deployment misconfigured
        </h1>
        <p style={{ fontSize: '0.875rem', color: '#a1a1aa', marginTop: '0.75rem', lineHeight: 1.5 }}>
          This deployment is missing the{' '}
          <code style={{ fontFamily: 'monospace', color: '#e4e4e7' }}>{missingVar}</code>{' '}
          environment variable, which is required to start the app.
        </p>
        <p style={{ fontSize: '0.875rem', color: '#a1a1aa', marginTop: '0.5rem', lineHeight: 1.5 }}>
          See{' '}
          <code style={{ fontFamily: 'monospace', color: '#e4e4e7' }}>ui/README.md</code> for
          setup instructions.
        </p>
      </div>
    </div>
  );
}

function main() {
  const rootEl = document.getElementById('root')!;

  const projectId = import.meta.env.VITE_WALLETCONNECT_PROJECT_ID;
  if (!projectId) {
    console.error(
      'Missing VITE_WALLETCONNECT_PROJECT_ID. Copy ui/.env.example to ui/.env and fill in values.'
    );
    renderConfigError(rootEl, 'VITE_WALLETCONNECT_PROJECT_ID');
    return;
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

  ReactDOM.createRoot(rootEl).render(
    <React.StrictMode>
      <WagmiProvider config={config}>
        <QueryClientProvider client={queryClient}>
          <RainbowKitProvider theme={darkTheme({ accentColor: '#7c3aed' })}>
            <BrowserRouter>
              <ErrorBoundary>
                <App />
              </ErrorBoundary>
            </BrowserRouter>
          </RainbowKitProvider>
        </QueryClientProvider>
      </WagmiProvider>
    </React.StrictMode>
  );
}

main();
