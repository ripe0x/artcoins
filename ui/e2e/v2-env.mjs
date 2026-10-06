// Turns the record script/v2/deploy.sh writes (tmp/v2-local-1.json for env local) into the E2E_V2_JSON file the e2e config reads:
// the VITE_V2_* build env of the second dev server, plus the owner for the cast steps.
//   node e2e/v2-env.mjs ../tmp/v2-local-1.json e2e/.local/v2-env.json
import fs from 'node:fs';
import path from 'node:path';

const [src, out] = process.argv.slice(2);
if (!src || !out) {
  console.error('usage: node e2e/v2-env.mjs <record.json> <out.json>');
  process.exit(2);
}
const d = JSON.parse(fs.readFileSync(src, 'utf8'));
const at = (role) => d.contracts.find((c) => c.role === role)?.address;
const env = {
  VITE_V2_FACTORY: at('factory'),
  VITE_V2_HOOK: at('hook'),
  VITE_V2_LOCKER: at('locker'),
  VITE_V2_ESCROW: at('escrow'),
  VITE_V2_MEV_MODULE: at('mevModule'),
  // the factory deploy block: the fromBlock for TokenCreatedV2 scans
  VITE_V2_DEPLOY_BLOCK: String(d.contracts.find((c) => c.role === 'factory').deployBlock),
  E2E_V2_OWNER: d.owner,
};
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify(env, null, 2) + '\n');
console.log(JSON.stringify(env, null, 2));
