// Turns the DeployV2Stack output (tmp/v2-deploy-1.json) into the E2E_V2_JSON file the e2e config reads:
// the VITE_V2_* build env of the second dev server, plus the owner for the cast steps.
//   node e2e/v2-env.mjs ../tmp/v2-deploy-1.json e2e/.local/v2-env.json
import fs from 'node:fs';
import path from 'node:path';

const [src, out] = process.argv.slice(2);
if (!src || !out) {
  console.error('usage: node e2e/v2-env.mjs <v2-deploy-1.json> <out.json>');
  process.exit(2);
}
const d = JSON.parse(fs.readFileSync(src, 'utf8'));
const a = d.addresses;
const env = {
  VITE_V2_FACTORY: a.factory,
  VITE_V2_HOOK: a.hook,
  VITE_V2_LOCKER: a.locker,
  VITE_V2_ESCROW: a.escrow,
  VITE_V2_MEV_MODULE: a.mev,
  // the block the script simulated at, at or before the deploy: a safe fromBlock for TokenCreatedV2 scans
  VITE_V2_DEPLOY_BLOCK: String(d.simulatedAtBlock),
  E2E_V2_OWNER: d.owner,
};
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify(env, null, 2) + '\n');
console.log(JSON.stringify(env, null, 2));
