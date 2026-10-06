// Checks the fork, snapshots it, and reverts it when the run ends, so every run starts from the same
// state (the claim test drains a live referral balance, the swaps move the pools). E2E_KEEP_STATE=1 keeps it.
import { assertFork, rpc } from './fork';

export default async function globalSetup() {
  await assertFork();
  const id = await rpc<string>('evm_snapshot');
  return async () => {
    if (process.env.E2E_KEEP_STATE === '1') return;
    await rpc('evm_revert', [id]);
  };
}
