import { Component, type ErrorInfo, type ReactNode } from 'react';

interface State {
  error: Error | null;
}

/** A render error on one page must not blank the whole app (UI-23). */
export default class ErrorBoundary extends Component<{ children: ReactNode }, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('ui render error', error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      return (
        <div className="mx-auto max-w-3xl px-4 py-16 text-center space-y-3">
          <h1 className="text-xl font-semibold">Something went wrong on this page</h1>
          <p className="text-sm text-zinc-500 break-words">{this.state.error.message.split('\n')[0]}</p>
          <button type="button" onClick={() => this.setState({ error: null })} className="rounded-lg border border-zinc-700 px-4 py-2 text-sm text-zinc-300 hover:text-white">
            Try again
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}
