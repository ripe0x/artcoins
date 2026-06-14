import { useState } from 'react';
import { shortAddr } from '../lib/format';

interface Props {
  address: string;
  short?: boolean;
  explorerUrl?: string;
  className?: string;
}

export default function CopyableAddress({ address, short = true, explorerUrl, className = '' }: Props) {
  const [copied, setCopied] = useState(false);

  const handleCopy = async (e: React.MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    try {
      await navigator.clipboard.writeText(address);
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    } catch {
      // ignore
    }
  };

  const display = short ? shortAddr(address) : address;

  return (
    <span className={`inline-flex items-center gap-1.5 ${className}`}>
      <span className="font-mono text-xs">{display}</span>
      <button
        type="button"
        onClick={handleCopy}
        className="text-zinc-500 hover:text-zinc-200 transition-colors"
        title={copied ? 'Copied!' : 'Copy address'}
      >
        {copied ? (
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
          </svg>
        ) : (
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
          </svg>
        )}
      </button>
      {explorerUrl && (
        <a
          href={explorerUrl}
          target="_blank"
          rel="noopener noreferrer"
          onClick={e => e.stopPropagation()}
          className="text-zinc-500 hover:text-zinc-200 transition-colors"
          title="View on Etherscan"
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6" />
            <polyline points="15 3 21 3 21 9" />
            <line x1="10" y1="14" x2="21" y2="3" />
          </svg>
        </a>
      )}
    </span>
  );
}
