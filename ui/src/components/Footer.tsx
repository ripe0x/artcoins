import type { ContractAddresses } from '../lib/config';
import { useAddressesOrNull } from '../lib/useChain';
import { getV2Stack } from '../lib/v2';

interface ContractLink {
  label: string;
  /** a key of the current stack addresses, or a literal address (the v2 stack) */
  key: keyof ContractAddresses | `0x${string}`;
}

const PRIMARY_LINKS: ContractLink[] = [
  { label: 'Factory', key: 'factory' },
  { label: 'Hook', key: 'hook' },
  { label: 'LP Locker', key: 'locker' },
  { label: 'Fee escrow', key: 'escrow' },
];

const MEV_LINKS: ContractLink[] = [{ label: 'Linear skim', key: 'mevLinearFees' }];

function etherscanBase(chainId: number): string {
  return chainId === 1 ? 'https://etherscan.io' : 'https://sepolia.etherscan.io';
}

function chainName(chainId: number): string {
  if (chainId === 1) return 'Ethereum Mainnet';
  if (chainId === 11155111) return 'Sepolia';
  return `Chain ${chainId}`;
}

function LinkGroup({
  title,
  links,
  chainId,
  addresses,
}: {
  title: string;
  links: ContractLink[];
  chainId: number;
  addresses: ContractAddresses;
}) {
  const base = etherscanBase(chainId);
  return (
    <div>
      <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">
        {title}
      </h4>
      <ul className="space-y-1">
        {links.map(({ label, key }) => {
          const addr = key.startsWith('0x') ? key : (addresses[key as keyof ContractAddresses] as string);
          const isZero = !addr || addr === '0x0000000000000000000000000000000000000000';
          return (
            <li key={label}>
              {isZero ? (
                <span className="text-zinc-700">{label}</span>
              ) : (
                <a
                  href={`${base}/address/${addr}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-zinc-500 hover:text-zinc-200 transition-colors"
                >
                  {label}
                </a>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}

export default function Footer() {
  const { chainId, addresses } = useAddressesOrNull();
  if (!addresses) {
    return (
      <footer className="border-t border-zinc-800 mt-10">
        <div className="mx-auto max-w-5xl px-4 py-8 text-sm text-zinc-500">No artcoins deployment on this network. Switch to Ethereum mainnet.</div>
      </footer>
    );
  }
  const v2 = getV2Stack(chainId);
  const v2Links: ContractLink[] = v2
    ? [
        { label: 'Factory v2', key: v2.factory },
        { label: 'Hook v2', key: v2.hook },
        { label: 'Locker v2', key: v2.locker },
        { label: 'Escrow v2', key: v2.escrow },
      ]
    : [];

  return (
    <footer className="border-t border-zinc-800 mt-10">
      <div className="mx-auto max-w-5xl px-4 py-8 grid grid-cols-2 md:grid-cols-4 gap-6 text-sm">
        <LinkGroup title="Current stack" links={PRIMARY_LINKS} chainId={chainId} addresses={addresses} />
        <LinkGroup title="Anti-Sniper" links={MEV_LINKS} chainId={chainId} addresses={addresses} />
        {v2Links.length > 0 && <LinkGroup title="v2 stack" links={v2Links} chainId={chainId} addresses={addresses} />}
        <div>
          <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">
            Network
          </h4>
          <p className="text-zinc-400">{chainName(chainId)}</p>
          <a
            href="https://github.com/ripe0x/artcoins"
            target="_blank"
            rel="noopener noreferrer"
            className="text-zinc-500 hover:text-zinc-200 transition-colors block mt-1"
          >
            Source on GitHub ↗
          </a>
        </div>
      </div>
      <div className="border-t border-zinc-900 py-4 text-center text-xs text-zinc-600">
        artcoins token launcher
      </div>
    </footer>
  );
}
