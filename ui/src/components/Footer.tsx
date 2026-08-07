import { Link } from 'react-router-dom';
import { useChainId } from 'wagmi';
import { getAddresses } from '../lib/config';

interface ContractLink {
  label: string;
  key: keyof ReturnType<typeof getAddresses>;
}

const PRIMARY_LINKS: ContractLink[] = [
  { label: 'Factory', key: 'factory' },
  { label: 'Hook', key: 'hook' },
  { label: 'LP Locker', key: 'locker' },
];

const MEV_LINKS: ContractLink[] = [
  { label: 'Linear Fees', key: 'mevLinearFees' },
  { label: 'Descending', key: 'mevDescFees' },
  { label: 'Time Delay', key: 'mevTimeDelay' },
];

const EXT_LINKS: ContractLink[] = [
  { label: 'Vault', key: 'vault' },
  { label: 'Airdrop', key: 'airdrop' },
  { label: 'Dev Buy', key: 'devBuy' },
];

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
  addresses: ReturnType<typeof getAddresses>;
}) {
  const base = etherscanBase(chainId);
  return (
    <div>
      <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">
        {title}
      </h4>
      <ul className="space-y-1">
        {links.map(({ label, key }) => {
          const addr = addresses[key] as string;
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
  const chainId = useChainId();
  const addresses = getAddresses(chainId);

  return (
    <footer className="border-t border-zinc-800 mt-10">
      <div className="mx-auto max-w-5xl px-4 py-8 grid grid-cols-2 md:grid-cols-4 gap-6 text-sm">
        <LinkGroup title="Core" links={PRIMARY_LINKS} chainId={chainId} addresses={addresses} />
        <LinkGroup title="Anti-Sniper" links={MEV_LINKS} chainId={chainId} addresses={addresses} />
        <LinkGroup title="Extensions" links={EXT_LINKS} chainId={chainId} addresses={addresses} />
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
        <div>
          <h4 className="text-xs font-semibold uppercase tracking-wider text-zinc-500 mb-2">
            Docs
          </h4>
          <ul className="space-y-1">
            <li>
              <Link
                to="/fee-flow"
                className="text-zinc-500 hover:text-zinc-200 transition-colors"
              >
                Sepolia fee rehearsal (dev notes)
              </Link>
            </li>
          </ul>
        </div>
      </div>
      <div className="border-t border-zinc-900 py-4 text-center text-xs text-zinc-600">
        artcoins
      </div>
    </footer>
  );
}
