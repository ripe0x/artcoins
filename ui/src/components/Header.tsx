import { NavLink } from 'react-router-dom';
import { ConnectButton } from '@rainbow-me/rainbowkit';

const navLinkClass = ({ isActive }: { isActive: boolean }) =>
  `text-sm font-medium transition-colors ${
    isActive ? 'text-white' : 'text-zinc-500 hover:text-zinc-200'
  }`;

export default function Header() {
  return (
    <header className="sticky top-0 z-50 border-b border-zinc-800 bg-[#0a0a0a]/80 backdrop-blur-md">
      <div className="mx-auto max-w-5xl flex items-center justify-between px-4 py-3">
        <div className="flex items-center gap-8">
          <NavLink to="/" className="flex items-center gap-3" end>
            <div className="w-8 h-8 rounded-lg bg-violet-600 flex items-center justify-center font-bold text-sm">
              NM
            </div>
            <span className="text-lg font-semibold tracking-tight">NewMaterial</span>
          </NavLink>
          <nav className="flex items-center gap-5">
            <NavLink to="/" end className={navLinkClass}>
              Deploy
            </NavLink>
            <NavLink to="/tokens" className={navLinkClass}>
              Tokens
            </NavLink>
            <NavLink to="/fee-flow" className={navLinkClass}>
              Fee flow
            </NavLink>
          </nav>
        </div>
        <ConnectButton />
      </div>
    </header>
  );
}
