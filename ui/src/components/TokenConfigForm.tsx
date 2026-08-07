import { useEffect, useRef } from 'react';
import type { TokenFormState } from '../lib/types';
import ImageUploader from './ImageUploader';
import { inputClass, labelClass } from './formStyles';

interface Props {
  value: TokenFormState;
  onChange: (v: TokenFormState) => void;
  connectedAddress: string | undefined;
}

export default function TokenConfigForm({ value, onChange, connectedAddress }: Props) {
  // Prefill the admin field with the connected wallet address, once per
  // address — never overwrites a value the user typed. The ref (rather than
  // an `[connectedAddress]`-only dep array) is what makes this safe to keep
  // `value`/`onChange` in the dep array without looping or re-prefilling
  // after the user clears the field.
  const prefilledAdminRef = useRef<string | null>(null);
  useEffect(() => {
    if (connectedAddress && !value.admin && prefilledAdminRef.current !== connectedAddress) {
      prefilledAdminRef.current = connectedAddress;
      onChange({ ...value, admin: connectedAddress });
    }
  }, [connectedAddress, value, onChange]);

  const set = (field: keyof TokenFormState, val: string) =>
    onChange({ ...value, [field]: val });

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div>
          <label htmlFor="token-name" className={labelClass}>Token Name</label>
          <input
            id="token-name"
            type="text"
            className={inputClass}
            placeholder="My Token"
            value={value.name}
            onChange={e => set('name', e.target.value)}
          />
        </div>
        <div>
          <label htmlFor="token-symbol" className={labelClass}>Symbol</label>
          <input
            id="token-symbol"
            type="text"
            className={inputClass}
            placeholder="MTK"
            value={value.symbol}
            onChange={e => set('symbol', e.target.value.toUpperCase())}
            maxLength={11}
          />
        </div>
      </div>

      <div>
        <label htmlFor="token-admin" className={labelClass}>Token Admin</label>
        <input
          id="token-admin"
          type="text"
          className={inputClass}
          placeholder="0x..."
          value={value.admin}
          onChange={e => set('admin', e.target.value)}
        />
        <p className="text-xs text-zinc-500 mt-1">Defaults to your connected wallet.</p>
      </div>

      <div>
        <label htmlFor="token-total-supply" className={labelClass}>Total Supply</label>
        <input
          id="token-total-supply"
          type="text"
          className={inputClass}
          placeholder="1000000000"
          value={value.totalSupply}
          onChange={e => set('totalSupply', e.target.value.replace(/[^0-9]/g, ''))}
        />
        <p className="text-xs text-zinc-500 mt-1">
          Enter 0 or leave default to use the factory default supply.
        </p>
      </div>

      <div>
        <label className={labelClass}>Token Image</label>
        <ImageUploader
          value={value.image}
          onChange={url => set('image', url)}
          placeholder="https://example.com/token-image.png"
        />
      </div>

      <div>
        <label htmlFor="token-metadata" className={labelClass}>Description / Metadata</label>
        <textarea
          id="token-metadata"
          className={`${inputClass} resize-none`}
          rows={3}
          placeholder="Describe your token..."
          value={value.metadata}
          onChange={e => set('metadata', e.target.value)}
        />
      </div>

      <div>
        <label htmlFor="token-context" className={labelClass}>Context</label>
        <input
          id="token-context"
          type="text"
          className={inputClass}
          placeholder="Optional context string"
          value={value.context}
          onChange={e => set('context', e.target.value)}
        />
        <p className="text-xs text-zinc-500 mt-1">
          Arbitrary context string stored with the token. Can be a URL, JSON, etc.
        </p>
      </div>
    </div>
  );
}
