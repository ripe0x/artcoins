/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** WalletConnect Cloud project ID (https://cloud.walletconnect.com). Required. */
  readonly VITE_WALLETCONNECT_PROJECT_ID: string;
  /** Alchemy API key — used for Sepolia and Mainnet RPC. Optional but recommended. */
  readonly VITE_ALCHEMY_API_KEY?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
