import { Outlet, useLocation } from 'react-router-dom';
import ErrorBoundary from './ErrorBoundary';
import Header from './Header';
import Footer from './Footer';

export default function Layout() {
  const { pathname } = useLocation();
  return (
    <div className="min-h-screen bg-[#0a0a0a] text-white flex flex-col">
      <Header />
      <div className="flex-1">
        {/* keyed by path so navigating away clears a caught error */}
        <ErrorBoundary key={pathname}>
          <Outlet />
        </ErrorBoundary>
      </div>
      <Footer />
    </div>
  );
}
