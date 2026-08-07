import { useEffect, useRef } from 'react';
import type { ExtensionsFormState, VaultConfig, AirdropConfig, DevBuyConfig } from '../lib/types';
import { inputClass, labelClass } from './formStyles';

interface Props {
  value: ExtensionsFormState;
  onChange: (v: ExtensionsFormState) => void;
  connectedAddress: string | undefined;
}

function Toggle({
  enabled,
  onToggle,
  label,
}: {
  enabled: boolean;
  onToggle: () => void;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={enabled}
      aria-label={label}
      onClick={onToggle}
      className="flex items-center gap-3 w-full"
    >
      <div
        className={`relative w-10 h-5 rounded-full transition-colors ${
          enabled ? 'bg-violet-600' : 'bg-zinc-700'
        }`}
      >
        <div
          className={`absolute top-0.5 w-4 h-4 rounded-full bg-white transition-transform ${
            enabled ? 'translate-x-5' : 'translate-x-0.5'
          }`}
        />
      </div>
      <span className="text-sm font-medium text-white">{label}</span>
    </button>
  );
}

export default function ExtensionsForm({ value, onChange, connectedAddress }: Props) {
  // Prefill vault/airdrop admin fields with the connected wallet address,
  // once per field per address — never overwrites a value the user typed.
  // One ref per field so clearing one after prefill doesn't re-trigger it,
  // while still letting the effect list `value`/`onChange` as deps.
  const prefilledVaultAdminRef = useRef<string | null>(null);
  const prefilledAirdropAdminRef = useRef<string | null>(null);
  useEffect(() => {
    if (!connectedAddress) return;
    let changed = false;
    const next = { ...value };
    if (!next.vault.admin && prefilledVaultAdminRef.current !== connectedAddress) {
      next.vault = { ...next.vault, admin: connectedAddress };
      prefilledVaultAdminRef.current = connectedAddress;
      changed = true;
    }
    if (!next.airdrop.admin && prefilledAirdropAdminRef.current !== connectedAddress) {
      next.airdrop = { ...next.airdrop, admin: connectedAddress };
      prefilledAirdropAdminRef.current = connectedAddress;
      changed = true;
    }
    if (changed) onChange(next);
  }, [connectedAddress, value, onChange]);

  const setVault = (patch: Partial<VaultConfig>) =>
    onChange({ ...value, vault: { ...value.vault, ...patch } });
  const setAirdrop = (patch: Partial<AirdropConfig>) =>
    onChange({ ...value, airdrop: { ...value.airdrop, ...patch } });
  const setDevBuy = (patch: Partial<DevBuyConfig>) =>
    onChange({ ...value, devBuy: { ...value.devBuy, ...patch } });

  const totalAlloc =
    (value.vault.enabled ? value.vault.allocationPercent : 0) +
    (value.airdrop.enabled ? value.airdrop.allocationPercent : 0) +
    (value.devBuy.enabled ? value.devBuy.allocationPercent : 0);

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between rounded-lg border border-zinc-700 bg-zinc-800/50 px-4 py-2">
        <span className="text-sm text-zinc-400">Total Allocation</span>
        <span className={`text-sm font-semibold ${totalAlloc <= 90 ? 'text-green-400' : 'text-red-400'}`}>
          {totalAlloc}% used / {100 - totalAlloc}% to liquidity
        </span>
      </div>

      {/* Vault */}
      <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 space-y-4">
        <Toggle
          enabled={value.vault.enabled}
          onToggle={() => setVault({ enabled: !value.vault.enabled })}
          label="Vault (Team / Treasury Allocation)"
        />
        {value.vault.enabled && (
          <div className="space-y-3 pl-13">
            <div>
              <label htmlFor="vault-admin" className={labelClass}>Admin Address</label>
              <input
                id="vault-admin"
                type="text"
                className={inputClass}
                placeholder="0x..."
                value={value.vault.admin}
                onChange={e => setVault({ admin: e.target.value })}
              />
            </div>
            <div>
              <label htmlFor="vault-allocation" className={labelClass}>
                Allocation:{' '}
                <span className="text-violet-400 font-semibold">{value.vault.allocationPercent}%</span>
              </label>
              <input
                id="vault-allocation"
                type="range"
                min={1}
                max={90}
                value={value.vault.allocationPercent}
                onChange={e => setVault({ allocationPercent: Number(e.target.value) })}
                className="w-full accent-violet-500"
              />
              <div className="flex justify-between text-xs text-zinc-600">
                <span>1%</span>
                <span>90%</span>
              </div>
            </div>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <div>
                <label htmlFor="vault-lockup-days" className={labelClass}>Lockup (days)</label>
                <input
                  id="vault-lockup-days"
                  type="number"
                  className={inputClass}
                  min={7}
                  value={value.vault.lockupDays}
                  onChange={e => setVault({ lockupDays: Math.max(7, Number(e.target.value)) })}
                />
              </div>
              <div>
                <label htmlFor="vault-vesting-days" className={labelClass}>Vesting (days)</label>
                <input
                  id="vault-vesting-days"
                  type="number"
                  className={inputClass}
                  min={0}
                  value={value.vault.vestingDays}
                  onChange={e => setVault({ vestingDays: Number(e.target.value) })}
                />
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Airdrop */}
      <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 space-y-4">
        <Toggle
          enabled={value.airdrop.enabled}
          onToggle={() => setAirdrop({ enabled: !value.airdrop.enabled })}
          label="Airdrop"
        />
        {value.airdrop.enabled && (
          <div className="space-y-3 pl-13">
            <div>
              <label htmlFor="airdrop-admin" className={labelClass}>Admin Address</label>
              <input
                id="airdrop-admin"
                type="text"
                className={inputClass}
                placeholder="0x..."
                value={value.airdrop.admin}
                onChange={e => setAirdrop({ admin: e.target.value })}
              />
            </div>
            <div>
              <label htmlFor="airdrop-allocation" className={labelClass}>
                Allocation:{' '}
                <span className="text-violet-400 font-semibold">{value.airdrop.allocationPercent}%</span>
              </label>
              <input
                id="airdrop-allocation"
                type="range"
                min={1}
                max={90}
                value={value.airdrop.allocationPercent}
                onChange={e => setAirdrop({ allocationPercent: Number(e.target.value) })}
                className="w-full accent-violet-500"
              />
              <div className="flex justify-between text-xs text-zinc-600">
                <span>1%</span>
                <span>90%</span>
              </div>
            </div>
            <div>
              <label htmlFor="airdrop-merkle-root" className={labelClass}>Merkle Root</label>
              <input
                id="airdrop-merkle-root"
                type="text"
                className={inputClass}
                placeholder="0x..."
                value={value.airdrop.merkleRoot}
                onChange={e => setAirdrop({ merkleRoot: e.target.value })}
              />
              <p className="text-xs text-zinc-500 mt-1">
                32-byte merkle root for claim verification. Can be updated later via admin.
              </p>
            </div>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <div>
                <label htmlFor="airdrop-lockup-days" className={labelClass}>Lockup (days)</label>
                <input
                  id="airdrop-lockup-days"
                  type="number"
                  className={inputClass}
                  min={1}
                  value={value.airdrop.lockupDays}
                  onChange={e => setAirdrop({ lockupDays: Math.max(1, Number(e.target.value)) })}
                />
              </div>
              <div>
                <label htmlFor="airdrop-vesting-days" className={labelClass}>Vesting (days)</label>
                <input
                  id="airdrop-vesting-days"
                  type="number"
                  className={inputClass}
                  min={0}
                  value={value.airdrop.vestingDays}
                  onChange={e => setAirdrop({ vestingDays: Number(e.target.value) })}
                />
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Dev Buy */}
      <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 space-y-4">
        <Toggle
          enabled={value.devBuy.enabled}
          onToggle={() => setDevBuy({ enabled: !value.devBuy.enabled })}
          label="Dev Buy (Buy tokens at launch)"
        />
        {value.devBuy.enabled && (
          <div className="space-y-3 pl-13">
            <div>
              <label htmlFor="devbuy-eth-amount" className={labelClass}>ETH Amount</label>
              <input
                id="devbuy-eth-amount"
                type="text"
                className={inputClass}
                placeholder="0.1"
                value={value.devBuy.ethAmount}
                onChange={e => setDevBuy({ ethAmount: e.target.value })}
              />
              <p className="text-xs text-zinc-500 mt-1">
                ETH sent with the transaction to buy tokens at launch.
              </p>
            </div>
            <div>
              <label htmlFor="devbuy-allocation" className={labelClass}>
                Allocation:{' '}
                <span className="text-violet-400 font-semibold">{value.devBuy.allocationPercent}%</span>
              </label>
              <input
                id="devbuy-allocation"
                type="range"
                min={1}
                max={90}
                value={value.devBuy.allocationPercent}
                onChange={e => setDevBuy({ allocationPercent: Number(e.target.value) })}
                className="w-full accent-violet-500"
              />
              <div className="flex justify-between text-xs text-zinc-600">
                <span>1%</span>
                <span>90%</span>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
