// An EIP-1193 wallet for the browser, backed by a node side signer.
//
// The page gets a tiny `window.ethereum` shim (and an EIP-6963 announcement) through addInitScript. Every
// `request` crosses to node through page.exposeFunction, where:
//   eth_requestAccounts, eth_accounts       the test account
//   eth_chainId, net_version                1 (the fork)
//   wallet_switchEthereumChain etc.          accepted (one chain)
//   personal_sign, eth_signTypedData_v4      signed with the local key (viem)
//   eth_sendTransaction                      key mode: signed locally with viem and sent raw to anvil
//                                            impersonate mode: anvil_impersonateAccount, forwarded unsigned
//   anything else                            forwarded to anvil
// Every sent transaction is recorded so a test can decode exactly what the ui asked the wallet to send.
import type { Page } from '@playwright/test';
import { hexToBigInt, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { FORK_RPC, pub, rpc, walletClientFor, testKey } from './fork';

export interface SentTx {
  hash: Hex;
  from: Address;
  to: Address | undefined;
  data: Hex | undefined;
  value: bigint;
}

export interface RpcLogEntry {
  method: string;
  ok: boolean;
  error?: string;
}

export class TestWallet {
  readonly address: Address;
  readonly sent: SentTx[] = [];
  readonly log: RpcLogEntry[] = [];
  private readonly label: string | null;

  private constructor(address: Address, label: string | null) {
    this.address = address;
    this.label = label;
  }

  /** a wallet that signs with a deterministic local key */
  static fromLabel(label: string): TestWallet {
    return new TestWallet(privateKeyToAccount(testKey(label)).address, label);
  }

  /** a wallet that sends as `address` through anvil impersonation (for live addresses, e.g. a referrer) */
  static impersonate(address: Address): TestWallet {
    return new TestWallet(address, null);
  }

  async handle(method: string, params: unknown[]): Promise<unknown> {
    switch (method) {
      case 'eth_requestAccounts':
      case 'eth_accounts':
        return [this.address];
      case 'eth_chainId':
        return '0x1';
      case 'net_version':
        return '1';
      case 'wallet_switchEthereumChain':
      case 'wallet_addEthereumChain':
      case 'wallet_watchAsset':
        return null;
      case 'wallet_requestPermissions':
      case 'wallet_getPermissions':
        return [{ parentCapability: 'eth_accounts' }];
      case 'wallet_revokePermissions':
        return null;
      case 'personal_sign': {
        const [msg] = params as [Hex];
        return this.signer().signMessage({ message: { raw: msg } });
      }
      case 'eth_signTypedData_v4': {
        const [, json] = params as [Address, string];
        const td = JSON.parse(json);
        const types = { ...td.types };
        delete types.EIP712Domain;
        return this.signer().signTypedData({ domain: td.domain, types, primaryType: td.primaryType, message: td.message });
      }
      case 'eth_sendTransaction':
        return this.send(params[0] as Record<string, Hex | undefined>);
      default:
        return rpc(method, params);
    }
  }

  private signer() {
    if (!this.label) throw new Error('impersonated wallet cannot sign messages');
    return privateKeyToAccount(testKey(this.label));
  }

  private async send(tx: Record<string, Hex | undefined>): Promise<Hex> {
    const value = tx.value ? hexToBigInt(tx.value) : 0n;
    let hash: Hex;
    if (this.label) {
      const wc = walletClientFor(this.label);
      hash = await wc.sendTransaction({
        to: tx.to as Address | undefined,
        data: tx.data,
        value,
        gas: tx.gas ? hexToBigInt(tx.gas) : undefined,
      });
    } else {
      await rpc('anvil_impersonateAccount', [this.address]);
      hash = await rpc<Hex>('eth_sendTransaction', [{ ...tx, from: this.address }]);
    }
    this.sent.push({ hash, from: this.address, to: tx.to as Address | undefined, data: tx.data, value });
    return hash;
  }

  /** Inject the provider into `page`. Call before the first navigation. */
  async attach(page: Page): Promise<void> {
    await page.exposeFunction('__e2eWallet', async (payload: string) => {
      const { method, params } = JSON.parse(payload) as { method: string; params: unknown[] };
      try {
        const result = await this.handle(method, params ?? []);
        this.log.push({ method, ok: true });
        return JSON.stringify({ result }, (_k, v) => (typeof v === 'bigint' ? `0x${v.toString(16)}` : v));
      } catch (e) {
        const err = e as { message?: string; code?: number; data?: unknown; details?: string };
        this.log.push({ method, ok: false, error: err.message?.split('\n')[0] });
        return JSON.stringify({ error: { code: err.code ?? -32603, message: err.details ?? err.message ?? String(e), data: err.data } });
      }
    });
    await page.addInitScript(INIT_SCRIPT);
  }
}

// runs in the page before any app code
const INIT_SCRIPT = `(() => {
  const listeners = {};
  const provider = {
    isMetaMask: true,
    isE2E: true,
    async request(args) {
      const raw = await window.__e2eWallet(JSON.stringify({ method: args.method, params: args.params || [] }));
      const res = JSON.parse(raw);
      if (res.error) {
        const e = new Error(res.error.message);
        e.code = res.error.code;
        e.data = res.error.data;
        throw e;
      }
      return res.result;
    },
    on(ev, fn) { (listeners[ev] = listeners[ev] || []).push(fn); return provider; },
    removeListener(ev, fn) { listeners[ev] = (listeners[ev] || []).filter((f) => f !== fn); return provider; },
    off(ev, fn) { return provider.removeListener(ev, fn); },
    emit(ev, ...a) { (listeners[ev] || []).forEach((f) => f(...a)); },
  };
  Object.defineProperty(window, 'ethereum', { value: provider, configurable: true, writable: false });
  const info = Object.freeze({
    uuid: '6f1c5e5e-e2e0-4e2e-9e2e-a7c0a1e2e000',
    name: 'E2E Wallet',
    icon: 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2232%22 height=%2232%22%3E%3Crect width=%2232%22 height=%2232%22 fill=%22%237c3aed%22/%3E%3C/svg%3E',
    rdns: 'org.artcoins.e2e',
  });
  const announce = () => window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: Object.freeze({ info, provider }) }));
  window.addEventListener('eip6963:requestProvider', announce);
  announce();
})();`;

export { FORK_RPC, pub };
