import { Outlet, useLocation } from 'react-router-dom';
import Header from './Header';
import Footer from './Footer';
import ErrorBoundary from './ErrorBoundary';

// ── Page width system ───────────────────────────────────────────────────
//
// Layout owns the single <main> element and its horizontal padding. Pages
// no longer render their own <main>/padding wrapper — instead each page's
// top-level element applies one of these tokens (plus its own vertical
// padding, which varies page-to-page: py-8 vs py-12 vs py-16 for
// empty/error states, so that stays page-owned) to center its content at a
// deliberate, named width inside <main>. (Exported individually, rather
// than as one object, so each stays a literal export — an object export
// here would trip `react-refresh/only-export-components` on this
// component file.)
//
//   PAGE_WIDTH_NARROW (max-w-3xl) — single-column form/detail-flow pages
//     (deploy, claim, referrals) and the 404 fallback.
//   PAGE_WIDTH_WIDE (max-w-5xl) — listing/dashboard-style pages with grids
//     or wide tables (tokens list, fee-flow snapshot).
//   PAGE_WIDTH_DETAIL (max-w-4xl) — the token detail page's two-column
//     info-card layout — wider than a form, narrower than a grid listing.
export const PAGE_WIDTH_NARROW = 'mx-auto max-w-3xl';
export const PAGE_WIDTH_WIDE = 'mx-auto max-w-5xl';
export const PAGE_WIDTH_DETAIL = 'mx-auto max-w-4xl';

export default function Layout() {
  const { pathname } = useLocation();
  return (
    <div className="min-h-screen bg-zinc-950 text-white flex flex-col">
      <Header />
      <main className="flex-1 px-4">
        {/* Keyed by route so navigating away from a page that errored
            remounts the boundary (resetting its state) instead of leaving
            the fallback stuck up while the header/footer stay usable. */}
        <ErrorBoundary key={pathname}>
          <Outlet />
        </ErrorBoundary>
      </main>
      <Footer />
    </div>
  );
}
