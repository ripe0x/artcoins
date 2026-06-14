import { useCallback, useRef, useState } from 'react';
import { useWalletClient } from 'wagmi';
import { IRYS_FREE_TIER_BYTES, uploadImageToArweave } from '../lib/arweave';

interface Props {
  /** Current image URL value (controlled). */
  value: string;
  /** Called whenever the URL changes (either via upload or manual paste). */
  onChange: (url: string) => void;
  /** Optional placeholder for the URL input. */
  placeholder?: string;
}

type Status =
  | { kind: 'idle' }
  | { kind: 'uploading'; fileName: string; size: number }
  | { kind: 'success'; fileName: string; size: number }
  | { kind: 'error'; message: string };

const MAX_FREE_BYTES = IRYS_FREE_TIER_BYTES;
const MAX_UPLOAD_BYTES = MAX_FREE_BYTES; // for now, reject anything over free tier

export default function ImageUploader({ value, onChange, placeholder }: Props) {
  const { data: walletClient } = useWalletClient();
  const [status, setStatus] = useState<Status>({ kind: 'idle' });
  const [dragOver, setDragOver] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const handleFile = useCallback(
    async (file: File) => {
      if (!walletClient) {
        setStatus({
          kind: 'error',
          message: 'Connect a wallet first to sign the upload.',
        });
        return;
      }
      if (!file.type.startsWith('image/')) {
        setStatus({
          kind: 'error',
          message: `Please select an image file (you selected ${file.type || 'unknown type'}).`,
        });
        return;
      }
      if (file.size > MAX_UPLOAD_BYTES) {
        setStatus({
          kind: 'error',
          message: `Image is ${formatBytes(file.size)} — max free upload is ${formatBytes(MAX_FREE_BYTES)}. Please resize or compress.`,
        });
        return;
      }

      setStatus({ kind: 'uploading', fileName: file.name, size: file.size });
      try {
        const result = await uploadImageToArweave(file, walletClient);
        onChange(result.url);
        setStatus({ kind: 'success', fileName: file.name, size: file.size });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        setStatus({
          kind: 'error',
          message: msg.slice(0, 200),
        });
      }
    },
    [walletClient, onChange]
  );

  const onPickClick = () => fileInputRef.current?.click();

  const onDrop = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    setDragOver(false);
    const file = e.dataTransfer.files?.[0];
    if (file) handleFile(file);
  };

  const onDragOver = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    setDragOver(true);
  };

  const onDragLeave = () => setDragOver(false);

  const uploading = status.kind === 'uploading';

  return (
    <div className="space-y-2">
      <div
        onDrop={onDrop}
        onDragOver={onDragOver}
        onDragLeave={onDragLeave}
        className={`relative flex items-center gap-3 rounded-lg border-2 border-dashed px-3 py-3 transition-colors ${
          dragOver
            ? 'border-violet-500 bg-violet-500/5'
            : 'border-zinc-700 hover:border-zinc-600 bg-zinc-800/50'
        }`}
      >
        {/* Preview thumbnail */}
        {value ? (
          <img
            src={value}
            alt="Preview"
            className="w-14 h-14 rounded-md object-cover border border-zinc-700 flex-shrink-0"
            onError={e => {
              (e.currentTarget as HTMLImageElement).style.opacity = '0.2';
            }}
          />
        ) : (
          <div className="w-14 h-14 rounded-md border border-zinc-700 bg-zinc-900 flex items-center justify-center flex-shrink-0">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-zinc-600">
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <circle cx="8.5" cy="8.5" r="1.5" />
              <polyline points="21 15 16 10 5 21" />
            </svg>
          </div>
        )}

        <div className="flex-1 min-w-0">
          <p className="text-xs text-zinc-400 leading-relaxed">
            Drag &amp; drop an image, or{' '}
            <button
              type="button"
              onClick={onPickClick}
              disabled={uploading}
              className="text-violet-400 hover:text-violet-300 font-medium underline underline-offset-2 disabled:text-zinc-600 disabled:no-underline"
            >
              choose a file
            </button>
            . Uploads permanently to Arweave via Irys — free for images under {formatBytes(MAX_FREE_BYTES)}.
          </p>
          <StatusLine status={status} />
        </div>

        <input
          ref={fileInputRef}
          type="file"
          accept="image/*"
          className="hidden"
          onChange={e => {
            const f = e.target.files?.[0];
            if (f) handleFile(f);
            // reset value so selecting the same file twice re-triggers
            e.target.value = '';
          }}
        />

        {uploading && (
          <div className="absolute inset-0 flex items-center justify-center rounded-lg bg-black/60 backdrop-blur-sm">
            <span className="text-sm text-white flex items-center gap-2">
              <Spinner />
              Signing &amp; uploading…
            </span>
          </div>
        )}
      </div>

      {/* URL field — keeps direct-paste option */}
      <input
        type="text"
        value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder ?? 'https://… or ipfs://… or ar://…'}
        className="w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white placeholder-zinc-500 focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 font-mono"
      />
    </div>
  );
}

function StatusLine({ status }: { status: Status }) {
  if (status.kind === 'idle') return null;
  if (status.kind === 'uploading') {
    return (
      <p className="text-xs text-zinc-500 mt-1">
        Uploading <span className="font-mono">{status.fileName}</span> ({formatBytes(status.size)})…
      </p>
    );
  }
  if (status.kind === 'success') {
    return (
      <p className="text-xs text-emerald-400 mt-1">
        ✓ Uploaded <span className="font-mono">{status.fileName}</span> ({formatBytes(status.size)}) to Arweave.
      </p>
    );
  }
  return <p className="text-xs text-red-400 mt-1">✗ {status.message}</p>;
}

function Spinner() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" className="animate-spin">
      <path d="M21 12a9 9 0 1 1-6.219-8.56" />
    </svg>
  );
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
}
