import { Component } from 'react';
import type { ErrorInfo, ReactNode } from 'react';

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
}

/**
 * Top-level render-error safety net. Any uncaught error thrown while
 * rendering `<App />` (a page, a hook, anything in the tree below this
 * boundary) is caught here instead of blanking the entire document.
 *
 * This only wraps `<App />` in `main.tsx` for now. A second boundary around
 * the router `<Outlet />` in `Layout.tsx` — so a single page crashing
 * doesn't take the header/nav down with it — is a deliberate follow-up:
 * `Layout.tsx` is owned by another agent concurrently, so it's out of scope
 * here.
 */
export default class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo) {
    console.error('[ErrorBoundary] Unhandled render error:', error, errorInfo.componentStack);
  }

  render() {
    const { error } = this.state;
    if (!error) {
      return this.props.children;
    }

    return (
      <div className="min-h-screen flex items-center justify-center bg-zinc-950 px-4">
        <div className="w-full max-w-md rounded-xl border border-zinc-800 bg-zinc-900 p-6 text-center space-y-4">
          <h1 className="text-lg font-semibold text-white">Something went wrong</h1>
          <p className="text-sm text-zinc-400">
            The app hit an unexpected error while rendering this page. Reloading usually fixes
            it.
          </p>
          <button
            type="button"
            onClick={() => window.location.reload()}
            className="w-full rounded-lg bg-violet-600 hover:bg-violet-500 px-4 py-2 text-sm font-medium text-white transition-colors"
          >
            Reload page
          </button>
          <details className="text-left text-xs text-zinc-500">
            <summary className="cursor-pointer select-none text-zinc-500 hover:text-zinc-300">
              Error details
            </summary>
            <pre className="mt-2 whitespace-pre-wrap break-all rounded-lg bg-zinc-950 border border-zinc-800 p-3 text-red-400/80">
              {error.message}
            </pre>
          </details>
        </div>
      </div>
    );
  }
}
