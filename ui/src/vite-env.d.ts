/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** WalletConnect Cloud project ID. Public by design (it identifies the app, it is not a secret). Required. */
  readonly VITE_WALLETCONNECT_PROJECT_ID: string;
  /** Mainnet rpc for reads, no secrets in the url. Optional. */
  readonly VITE_MAINNET_RPC_URL?: string;
  /** Alchemy key. Ignored unless VITE_ALCHEMY_KEY_RESTRICTED=1 (key restricted to this site's domains). */
  readonly VITE_ALCHEMY_API_KEY?: string;
  readonly VITE_ALCHEMY_KEY_RESTRICTED?: string;
  /** v2 stack, used until deployments.generated.ts exposes it. Factory, hook and locker are required together. */
  readonly VITE_V2_FACTORY?: string;
  readonly VITE_V2_HOOK?: string;
  readonly VITE_V2_LOCKER?: string;
  readonly VITE_V2_ESCROW?: string;
  readonly VITE_V2_MEV_MODULE?: string;
  readonly VITE_V2_DEV_BUY?: string;
  readonly VITE_V2_VAULT?: string;
  readonly VITE_V2_AIRDROP?: string;
  readonly VITE_V2_POOL_EXTENSION?: string;
  readonly VITE_V2_DEPLOY_BLOCK?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
