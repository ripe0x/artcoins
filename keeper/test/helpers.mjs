import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// anvil's public test keys (never funded on mainnet with anything that matters). index 1 for unit tests.
export const TEST_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
export const TEST_ADDR = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';
export const OWNER = '0xCB43078C32423F5348Cab5885911C3B5faE217F9';
export const K111 = '0x1111111111111111111111111111111111111111';
export const KLAYER = '0x2222222222222222222222222222222222222222';
export const KV2 = '0x3333333333333333333333333333333333333333';
export const COIN_V2 = '0x4444444444444444444444444444444444444444';

export const tmpDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'keeper-test-'));
export const realRegistry = () => JSON.parse(fs.readFileSync(new URL('../../deployments/mainnet.json', import.meta.url), 'utf8'));

/// the real registry plus a deployed v2 stack with a keeper and one coin
export function registryWithV2({ keeper = true, status = 'current' } = {}) {
  const reg = realRegistry();
  reg.stacks.v2 = { label: 'v2', status, factory: '0x5555555555555555555555555555555555555555', deployedAt: '2026-10-07', notes: '' };
  if (keeper) reg.contracts.push({ name: 'ArtCoinsKeeperV2', address: KV2, stack: 'v2', role: 'other', status, owner: null });
  reg.coins.push({ symbol: 'CRED', name: 'credits', address: COIN_V2, stack: 'v2' });
  return reg;
}

export const baseEnv = (dir, extra = {}) => ({
  KEEPER_PRIVATE_KEY: TEST_KEY,
  KEEPER_111: K111,
  KEEPER_LAYER: KLAYER,
  STATE_PATH: path.join(dir, 'state.json'),
  ...extra,
});

export const silentLog = () => {
  const lines = [];
  const mk = (level) => (msg, fields) => lines.push({ level, msg, ...fields });
  return { lines, info: mk('info'), warn: mk('warn'), error: mk('error') };
};
