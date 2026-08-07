import type { PoolFormState } from '../lib/types';
import { inputClass, labelClass, selectClass } from './formStyles';

interface Props {
  value: PoolFormState;
  onChange: (v: PoolFormState) => void;
}

export default function PoolConfigForm({ value, onChange }: Props) {
  const set = <K extends keyof PoolFormState>(field: K, val: PoolFormState[K]) =>
    onChange({ ...value, [field]: val });

  return (
    <div className="space-y-4">
      <div>
        <label htmlFor="pool-paired-token" className={labelClass}>Paired Token</label>
        <select
          id="pool-paired-token"
          className={selectClass}
          value={value.pairedToken}
          onChange={e => set('pairedToken', e.target.value)}
        >
          <option value="weth">WETH (Wrapped Ether)</option>
          <option value="custom">Custom Address</option>
        </select>
      </div>

      {value.pairedToken === 'custom' && (
        <div>
          <label htmlFor="pool-custom-paired-token" className={labelClass}>Custom Token Address</label>
          <input
            id="pool-custom-paired-token"
            type="text"
            className={inputClass}
            placeholder="0x..."
            value={value.customPairedToken}
            onChange={e => set('customPairedToken', e.target.value)}
          />
        </div>
      )}

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <div>
          <label htmlFor="pool-tick-spacing" className={labelClass}>Tick Spacing</label>
          <select
            id="pool-tick-spacing"
            className={selectClass}
            value={value.tickSpacing}
            onChange={e => set('tickSpacing', Number(e.target.value))}
          >
            <option value={1}>1 (Highest precision)</option>
            <option value={10}>10</option>
            <option value={60}>60 (Recommended)</option>
            <option value={200}>200 (Lowest precision)</option>
          </select>
        </div>

        <div>
          <label htmlFor="pool-starting-tick" className={labelClass}>Starting Tick</label>
          <input
            id="pool-starting-tick"
            type="number"
            className={inputClass}
            value={value.startingTick}
            onChange={e => set('startingTick', Number(e.target.value))}
          />
          <p className="text-xs text-zinc-500 mt-1">
            Determines the initial price. Negative = new token is cheaper than paired token.
          </p>
        </div>
      </div>

      <div>
        <label htmlFor="pool-buy-fee" className={labelClass}>
          Buy Fee: <span className="text-violet-400 font-semibold">{value.buyFeePercent}%</span>
        </label>
        <input
          id="pool-buy-fee"
          type="range"
          min={0}
          max={10}
          step={0.1}
          value={value.buyFeePercent}
          onChange={e => set('buyFeePercent', Number(e.target.value))}
          className="w-full accent-violet-500"
        />
        <div className="flex justify-between text-xs text-zinc-600">
          <span>0%</span>
          <span>10%</span>
        </div>
      </div>

      <div>
        <label htmlFor="pool-sell-fee" className={labelClass}>
          Sell Fee: <span className="text-violet-400 font-semibold">{value.sellFeePercent}%</span>
        </label>
        <input
          id="pool-sell-fee"
          type="range"
          min={0}
          max={10}
          step={0.1}
          value={value.sellFeePercent}
          onChange={e => set('sellFeePercent', Number(e.target.value))}
          className="w-full accent-violet-500"
        />
        <div className="flex justify-between text-xs text-zinc-600">
          <span>0%</span>
          <span>10%</span>
        </div>
      </div>
    </div>
  );
}
