import { useEffect } from 'react';
import type { TokenFormState } from '../lib/types';
import ImageUploader from './ImageUploader';

const inputClass =
  'w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white placeholder-zinc-500 focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500';
const labelClass = 'block text-sm font-medium text-zinc-300 mb-1.5';

interface Props {
  value: TokenFormState;
  onChange: (v: TokenFormState) => void;
  connectedAddress: string | undefined;
}

export default function TokenConfigForm({ value, onChange, connectedAddress }: Props) {
  useEffect(() => {
    if (connectedAddress && !value.admin) {
      onChange({ ...value, admin: connectedAddress });
    }
  }, [connectedAddress]);

  const set = (field: keyof TokenFormState, val: string) =>
    onChange({ ...value, [field]: val });

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className={labelClass}>Token Name</label>
          <input
            type="text"
            className={inputClass}
            placeholder="My Token"
            value={value.name}
            onChange={e => set('name', e.target.value)}
          />
        </div>
        <div>
          <label className={labelClass}>Symbol</label>
          <input
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
        <label className={labelClass}>Token Admin</label>
        <input
          type="text"
          className={inputClass}
          placeholder="0x..."
          value={value.admin}
          onChange={e => set('admin', e.target.value)}
        />
        <p className="text-xs text-zinc-500 mt-1">Defaults to your connected wallet.</p>
      </div>

      <div>
        <label className={labelClass}>Total Supply</label>
        <input
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
        <label className={labelClass}>Description / Metadata</label>
        <textarea
          className={`${inputClass} resize-none`}
          rows={3}
          placeholder="Describe your token..."
          value={value.metadata}
          onChange={e => set('metadata', e.target.value)}
        />
      </div>

      <div>
        <label className={labelClass}>Context</label>
        <input
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
