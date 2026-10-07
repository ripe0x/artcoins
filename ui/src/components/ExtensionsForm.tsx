import { useMemo } from 'react';
import { formatUnits } from 'viem';
import type { AirdropConfig, DevBuyConfig, ExtensionsFormState, LaunchForm, VaultConfig } from '../lib/types';
import type { Issue } from '../lib/encodeV2';
import { Field, Issues, Toggle } from './formUi';
import { hintClass, inputClass, labelClass } from './formStyles';
import { estimateDevBuy } from '../lib/devBuy';
import { MAX_EXTENSION_BPS, VAULT_MIN_LOCKUP_DAYS, VAULT_MIN_VESTING_DAYS } from '../lib/constants';
import { formatPrice } from '../lib/format';

interface Props {
  value: ExtensionsFormState;
  onChange: (v: ExtensionsFormState) => void;
  connectedAddress: string | undefined;
  issues: Issue[];
  /** the whole form, the dev buy estimate reads the pool and supply from it */
  form: LaunchForm;
  configured: { vault: boolean; airdrop: boolean; devBuy: boolean };
}

function Missing() {
  return <p className="text-xs text-amber-400">No extension of this kind is configured for this stack yet.</p>;
}

export default function ExtensionsForm({ value, onChange, connectedAddress, issues, form, configured }: Props) {
  const setVault = (patch: Partial<VaultConfig>) => onChange({ ...value, vault: { ...value.vault, ...patch } });
  const setAirdrop = (patch: Partial<AirdropConfig>) => onChange({ ...value, airdrop: { ...value.airdrop, ...patch } });
  const setDevBuy = (patch: Partial<DevBuyConfig>) => onChange({ ...value, devBuy: { ...value.devBuy, ...patch } });

  const totalAlloc = (value.vault.enabled ? value.vault.allocationPercent : 0) + (value.airdrop.enabled ? value.airdrop.allocationPercent : 0);
  const estimate = useMemo(() => (value.devBuy.enabled ? estimateDevBuy(form) : null), [form, value.devBuy.enabled]);

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between rounded-lg border border-zinc-700 bg-zinc-800/50 px-4 py-2">
        <span className="text-sm text-zinc-400">Supply allocation (max {MAX_EXTENSION_BPS / 100}%)</span>
        <span className={`text-sm font-semibold ${totalAlloc <= MAX_EXTENSION_BPS / 100 ? 'text-green-400' : 'text-red-400'}`}>
          {totalAlloc}% to extensions / {(100 - totalAlloc).toFixed(2).replace(/\.00$/, '')}% to liquidity
        </span>
      </div>

      <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 space-y-4">
        <Toggle enabled={value.vault.enabled} onToggle={() => setVault({ enabled: !value.vault.enabled })} label="Vault (cliff then linear vesting)" />
        {value.vault.enabled && (
          <div className="space-y-3">
            {!configured.vault && <Missing />}
            <Field label="Beneficiary" hint="Receives every claim. It cannot be changed later.">
              <input type="text" className={inputClass} placeholder={connectedAddress ?? '0x...'} value={value.vault.beneficiary} onChange={(e) => setVault({ beneficiary: e.target.value })} />
            </Field>
            <div>
              <label className={labelClass}>Allocation: <span className="text-violet-400 font-semibold">{value.vault.allocationPercent}%</span></label>
              <input type="range" min={1} max={90} value={value.vault.allocationPercent} onChange={(e) => setVault({ allocationPercent: Number(e.target.value) })} className="w-full accent-violet-500" />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <Field label={`Cliff (days, min ${VAULT_MIN_LOCKUP_DAYS})`}>
                <input type="number" className={inputClass} min={VAULT_MIN_LOCKUP_DAYS} value={value.vault.lockupDays} onChange={(e) => setVault({ lockupDays: Number(e.target.value) })} />
              </Field>
              <Field label={`Vesting (days, min ${VAULT_MIN_VESTING_DAYS})`}>
                <input type="number" className={inputClass} min={VAULT_MIN_VESTING_DAYS} value={value.vault.vestingDays} onChange={(e) => setVault({ vestingDays: Number(e.target.value) })} />
              </Field>
            </div>
            <Issues issues={issues} prefix="vault" />
          </div>
        )}
      </div>

      <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 space-y-4">
        <Toggle enabled={value.airdrop.enabled} onToggle={() => setAirdrop({ enabled: !value.airdrop.enabled })} label="Airdrop (merkle)" />
        {value.airdrop.enabled && (
          <div className="space-y-3">
            {!configured.airdrop && <Missing />}
            <Field label="Sweep recipient" hint="Receives whatever is unclaimed after the claim window closes.">
              <input type="text" className={inputClass} placeholder={connectedAddress ?? '0x...'} value={value.airdrop.sweepRecipient} onChange={(e) => setAirdrop({ sweepRecipient: e.target.value })} />
            </Field>
            <div>
              <label className={labelClass}>Allocation: <span className="text-violet-400 font-semibold">{value.airdrop.allocationPercent}%</span></label>
              <input type="range" min={1} max={90} value={value.airdrop.allocationPercent} onChange={(e) => setAirdrop({ allocationPercent: Number(e.target.value) })} className="w-full accent-violet-500" />
            </div>
            <Field label="Merkle root" hint="Required and fixed at launch. There is no way to replace it afterwards.">
              <input type="text" className={inputClass} placeholder="0x... (32 bytes)" value={value.airdrop.merkleRoot} onChange={(e) => setAirdrop({ merkleRoot: e.target.value })} />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Lockup (days)">
                <input type="number" className={inputClass} min={0} value={value.airdrop.lockupDays} onChange={(e) => setAirdrop({ lockupDays: Number(e.target.value) })} />
              </Field>
              <Field label="Vesting (days)">
                <input type="number" className={inputClass} min={0} value={value.airdrop.vestingDays} onChange={(e) => setAirdrop({ vestingDays: Number(e.target.value) })} />
              </Field>
            </div>
            <Issues issues={issues} prefix="airdrop" />
          </div>
        )}
      </div>

      <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 space-y-4">
        <Toggle enabled={value.devBuy.enabled} onToggle={() => setDevBuy({ enabled: !value.devBuy.enabled })} label="Dev buy (buy at launch from your own pool)" />
        {value.devBuy.enabled && (
          <div className="space-y-3">
            {!configured.devBuy && <Missing />}
            <Field label="ETH amount" hint="Sent with the launch transaction and spent buying the coin. It pays the same lp fee and baseline skim as any trader. It takes no supply allocation.">
              <input type="text" className={inputClass} placeholder="0.1" value={value.devBuy.ethAmount} onChange={(e) => setDevBuy({ ethAmount: e.target.value })} />
            </Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Coin recipient">
                <input type="text" className={inputClass} placeholder={connectedAddress ?? '0x...'} value={value.devBuy.recipient} onChange={(e) => setDevBuy({ recipient: e.target.value })} />
              </Field>
              <Field label="Refund recipient" hint="Gets any ETH the pool did not use.">
                <input type="text" className={inputClass} placeholder={connectedAddress ?? '0x...'} value={value.devBuy.refundRecipient} onChange={(e) => setDevBuy({ refundRecipient: e.target.value })} />
              </Field>
            </div>
            <div className="rounded-lg bg-zinc-800/40 p-3 text-xs space-y-1">
              {estimate ? (
                <>
                  <div className="flex justify-between text-zinc-400"><span>Estimated coin out (pool curve, fees included)</span><span className="text-zinc-200">{Number(formatUnits(estimate.coinOut, 18)).toLocaleString(undefined, { maximumFractionDigits: 0 })}</span></div>
                  <div className="flex justify-between text-zinc-400"><span>Average price paid</span><span className="text-zinc-200">{formatPrice(estimate.avgEthPerCoin)} ETH</span></div>
                  {estimate.exhausted && <p className="text-red-400">This buy is larger than the pool. Lower the amount.</p>}
                </>
              ) : (
                <p className="text-zinc-500">Enter a valid ETH amount to see an estimate.</p>
              )}
              <div className="flex items-end gap-2 pt-1">
                <div className="flex-1">
                  <label className="text-zinc-500">Minimum coin out (required, nonzero)</label>
                  <input type="text" className={inputClass} placeholder="whole coins" value={value.devBuy.minTokenOut} onChange={(e) => setDevBuy({ minTokenOut: e.target.value.replace(/[^0-9.]/g, '') })} />
                </div>
                <div className="w-24">
                  <label className="text-zinc-500">Tolerance %</label>
                  <input type="number" className={inputClass} min={0} max={50} step={0.5} value={value.devBuy.toleranceBps / 100} onChange={(e) => setDevBuy({ toleranceBps: Math.round(Number(e.target.value) * 100) })} />
                </div>
                <button
                  type="button"
                  disabled={!estimate}
                  onClick={() => estimate && setDevBuy({ minTokenOut: formatUnits(estimate.minOut, 18).replace(/(\.\d{0,6})\d*$/, '$1') })}
                  className="rounded-lg bg-violet-600 hover:bg-violet-500 disabled:bg-zinc-700 px-3 py-2 text-xs font-semibold"
                >
                  Fill from estimate
                </button>
              </div>
              <p className={hintClass}>The contract reverts if the pool gives less than this. A zero floor is not allowed.</p>
            </div>
            <Issues issues={issues} prefix="devBuy" />
          </div>
        )}
      </div>
      <Issues issues={issues} prefix="extensions" />
    </div>
  );
}
