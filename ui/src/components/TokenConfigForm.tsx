import type { TokenFormState } from '../lib/types';
import type { Issue } from '../lib/encodeV2';
import ImageUploader from './ImageUploader';
import { ByteCount, Field, Issues } from './formUi';
import { inputClass } from './formStyles';
import { safeImageUrl } from '../lib/security';
import { STRING_CAPS } from '../lib/launchRules';

interface Props {
  value: TokenFormState;
  onChange: (v: TokenFormState) => void;
  connectedAddress: string | undefined;
  issues: Issue[];
}

export default function TokenConfigForm({ value, onChange, connectedAddress, issues }: Props) {
  const set = (field: keyof TokenFormState, val: string) => onChange({ ...value, [field]: val });
  const imageOk = !value.image.trim() || safeImageUrl(value.image) !== null;

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-4">
        <Field label="Token name" hint={<ByteCount value={value.name.trim()} cap={STRING_CAPS.name} />}>
          <input type="text" className={inputClass} placeholder="My Token" value={value.name} onChange={(e) => set('name', e.target.value)} />
        </Field>
        <Field label="Symbol" hint={<ByteCount value={value.symbol.trim()} cap={STRING_CAPS.symbol} />}>
          <input type="text" className={inputClass} placeholder="MTK" value={value.symbol} onChange={(e) => set('symbol', e.target.value.toUpperCase())} />
        </Field>
      </div>

      <Field label="Token admin" hint={`Can update the image and metadata. Defaults to your connected wallet${connectedAddress ? '' : ' (connect one)'}.`}>
        <input type="text" className={inputClass} placeholder={connectedAddress ?? '0x...'} value={value.admin} onChange={(e) => set('admin', e.target.value)} />
      </Field>

      <Field label="Total supply (whole coins)" hint="Leave empty or 0 for the factory default of 1,000,000,000.">
        <input type="text" className={inputClass} placeholder="1000000000" value={value.totalSupply} onChange={(e) => set('totalSupply', e.target.value.replace(/[^0-9]/g, ''))} />
      </Field>

      <Field label="Token image" hint={
          <>
            https, ipfs, ar or data:image urls only. Anything else is not shown to other users. The chain stores the url, so it is capped at{' '}
            {STRING_CAPS.image} bytes: a data: image will not fit, use a hosted url. <ByteCount value={value.image.trim()} cap={STRING_CAPS.image} />
          </>
        }>
        <ImageUploader value={value.image} onChange={(url) => set('image', url)} placeholder="https://example.com/token-image.png" />
        {!imageOk && <p className="text-xs text-red-400 mt-1">This url scheme is not accepted. Use https, ipfs, ar or a data:image url.</p>}
      </Field>

      <Field label="Description" hint={<ByteCount value={value.metadata} cap={STRING_CAPS.metadata} />}>
        <textarea className={`${inputClass} resize-none`} rows={3} placeholder="Describe your token..." value={value.metadata} onChange={(e) => set('metadata', e.target.value)} />
      </Field>

      <Field label="Context" hint={
          <>
            Free text stored with the token, for example a link or a short json. <ByteCount value={value.context} cap={STRING_CAPS.context} />
          </>
        }>
        <input type="text" className={inputClass} placeholder="Optional context string" value={value.context} onChange={(e) => set('context', e.target.value)} />
      </Field>

      <Field label="Metadata renderer (optional)" hint="A renderer contract that builds the token's on chain json. Leave empty for the default. It is fixed at launch.">
        <input type="text" className={inputClass} placeholder="0x... or empty" value={value.renderer} onChange={(e) => set('renderer', e.target.value)} />
      </Field>
      <Issues issues={issues} prefix="token" />
    </div>
  );
}
