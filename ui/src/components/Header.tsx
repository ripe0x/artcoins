import { NavLink } from 'react-router-dom';
import { ConnectButton } from '@rainbow-me/rainbowkit';

const navLinkClass = ({ isActive }: { isActive: boolean }) =>
  `text-sm font-medium transition-colors ${
    isActive ? 'text-white' : 'text-zinc-500 hover:text-zinc-200'
  }`;

export default function Header() {
  return (
    <header className="sticky top-0 z-50 border-b border-zinc-800 bg-zinc-950/80 backdrop-blur-md">
      <div className="mx-auto max-w-5xl flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-4 py-3">
        <div className="flex flex-wrap items-center gap-4 sm:gap-8">
          <NavLink to="/" className="flex items-center gap-3" end>
            <span className="text-lg font-semibold tracking-tight">artcoins</span>
          </NavLink>
          <nav className="flex items-center gap-5">
            <NavLink to="/" end className={navLinkClass}>
              Deploy
            </NavLink>
            <NavLink to="/tokens" className={navLinkClass}>
              Tokens
            </NavLink>
          </nav>
        </div>
        <ConnectButton />
      </div>
    </header>
  );
}
