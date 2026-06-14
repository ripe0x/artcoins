import { Routes, Route } from 'react-router-dom';
import Layout from './components/Layout';
import DeployPage from './pages/DeployPage';
import TokensListPage from './pages/TokensListPage';
import TokenDetailPage from './pages/TokenDetailPage';
import ClaimPage from './pages/ClaimPage';
import ReferralsPage from './pages/ReferralsPage';
import FeeFlowPage from './pages/FeeFlowPage';

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<DeployPage />} />
        <Route path="tokens" element={<TokensListPage />} />
        <Route path="tokens/:address" element={<TokenDetailPage />} />
        <Route path="tokens/:address/claim" element={<ClaimPage />} />
        <Route path="tokens/:address/referrals" element={<ReferralsPage />} />
        <Route path="fee-flow" element={<FeeFlowPage />} />
        <Route
          path="*"
          element={
            <div className="mx-auto max-w-3xl px-4 py-16 text-center text-zinc-500">
              Page not found.
            </div>
          }
        />
      </Route>
    </Routes>
  );
}
