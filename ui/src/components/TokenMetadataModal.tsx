import { useEffect, useState } from 'react';
import type { ParsedContractURI } from '../lib/metadata';

interface Props {
  open: boolean;
  onClose: () => void;
  image: string | null;
  name: string;
  symbol: string;
  description?: string;
  parsedMeta: ParsedContractURI | null;
  contractURI?: string;
  onRefresh?: () => void;
}

export default function TokenMetadataModal({
  open,
  onClose,
  image,
  name,
  symbol,
  description,
  parsedMeta,
  contractURI,
  onRefresh,
}: Props) {
  const [showRaw, setShowRaw] = useState(false);
  const [copied, setCopied] = useState(false);

  // Close on Escape
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  // Prevent body scroll while open
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);

  if (!open) return null;

  const attributes = parsedMeta?.attributes ?? [];
  const externalUrl = parsedMeta?.external_url;

  const handleCopy = async () => {
    if (!contractURI) return;
    try {
      await navigator.clipboard.writeText(contractURI);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* ignore */
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm animate-fadeIn"
      onClick={onClose}
    >
      <div
        className="relative w-full max-w-4xl max-h-[90vh] overflow-hidden rounded-2xl border border-zinc-800 bg-zinc-950 shadow-2xl flex flex-col"
        onClick={e => e.stopPropagation()}
      >
        {/* Close button */}
        <button
          type="button"
          onClick={onClose}
          aria-label="Close"
          className="absolute top-4 right-4 z-10 w-9 h-9 rounded-full bg-zinc-900/90 border border-zinc-700 hover:bg-zinc-800 flex items-center justify-center text-zinc-400 hover:text-white transition-colors"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <line x1="18" y1="6" x2="6" y2="18" />
            <line x1="6" y1="6" x2="18" y2="18" />
          </svg>
        </button>

        <div className="overflow-y-auto">
          <div className="grid md:grid-cols-2 gap-0">
            {/* Image side */}
            <div className="bg-gradient-to-br from-zinc-900 to-black p-6 flex items-center justify-center min-h-[320px] md:min-h-[520px] border-b md:border-b-0 md:border-r border-zinc-800">
              {image ? (
                <img
                  src={image}
                  alt={symbol}
                  className="max-w-full max-h-[480px] rounded-xl shadow-xl object-contain"
                  onError={e => {
                    (e.currentTarget as HTMLImageElement).style.display = 'none';
                  }}
                />
              ) : (
                <div className="w-full aspect-square max-w-[400px] rounded-xl bg-gradient-to-br from-violet-900/30 to-zinc-900 flex items-center justify-center">
                  <span className="font-mono text-5xl font-bold text-zinc-600">
                    {symbol.slice(0, 4)}
                  </span>
                </div>
              )}
            </div>

            {/* Details side */}
            <div className="p-6 space-y-5">
              <div>
                <h2 className="text-2xl font-bold text-white">
                  {name} <span className="text-zinc-500 font-normal">({symbol})</span>
                </h2>
                {description && (
                  <p className="text-sm text-zinc-400 mt-2 whitespace-pre-wrap">{description}</p>
                )}
                {externalUrl && (
                  <a
                    href={externalUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-xs text-violet-400 hover:text-violet-300 mt-2"
                  >
                    External link
                    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                      <path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6" />
                      <polyline points="15 3 21 3 21 9" />
                      <line x1="10" y1="14" x2="21" y2="3" />
                    </svg>
                  </a>
                )}
              </div>

              {/* Traits */}
              {attributes.length > 0 && (
                <div>
                  <div className="flex items-center justify-between mb-2">
                    <h3 className="text-xs font-semibold uppercase tracking-wider text-zinc-500">
                      Traits
                    </h3>
                    {onRefresh && (
                      <button
                        type="button"
                        onClick={onRefresh}
                        className="text-xs text-zinc-500 hover:text-violet-400 inline-flex items-center gap-1"
                        title="Re-fetch metadata"
                      >
                        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                          <polyline points="23 4 23 10 17 10" />
                          <polyline points="1 20 1 14 7 14" />
                          <path d="M3.51 9a9 9 0 0114.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0020.49 15" />
                        </svg>
                        Refresh
                      </button>
                    )}
                  </div>
                  <div className="grid grid-cols-2 gap-2">
                    {attributes.map((attr, i) => (
                      <div
                        key={i}
                        className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-3"
                      >
                        <div className="text-[10px] uppercase tracking-wider text-violet-400 font-semibold">
                          {attr.trait_type ?? 'Trait'}
                        </div>
                        <div className="text-sm text-white mt-0.5 break-all font-mono">
                          {String(attr.value)}
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Raw JSON toggle */}
              {contractURI && (
                <div>
                  <div className="flex items-center gap-3 mb-2">
                    <button
                      type="button"
                      onClick={() => setShowRaw(v => !v)}
                      className="text-xs text-zinc-500 hover:text-zinc-300 inline-flex items-center gap-1"
                    >
                      <svg
                        width="10"
                        height="10"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        strokeWidth="2"
                        style={{ transform: showRaw ? 'rotate(90deg)' : 'none', transition: 'transform 150ms' }}
                      >
                        <polyline points="9 18 15 12 9 6" />
                      </svg>
                      {showRaw ? 'Hide raw metadata' : 'Show raw metadata'}
                    </button>
                    <button
                      type="button"
                      onClick={handleCopy}
                      className="text-xs text-zinc-500 hover:text-zinc-300"
                    >
                      {copied ? 'Copied!' : 'Copy URI'}
                    </button>
                  </div>
                  {showRaw && (
                    <pre className="rounded-lg border border-zinc-800 bg-black/40 p-3 text-[11px] text-zinc-400 overflow-auto max-h-64 font-mono whitespace-pre-wrap break-all">
                      {parsedMeta ? JSON.stringify(parsedMeta, null, 2) : contractURI}
                    </pre>
                  )}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
