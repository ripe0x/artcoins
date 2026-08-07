// Backward-compatible ABI export names, sourced from generated/vendored ABIs
// instead of hand-written subsets (see issue #18). Keeping these aliases
// means call sites (`../lib/abi` imports across the app) don't need to
// churn — only the DATA backing them changed, from hand-transcribed
// fragments to solc-compiled ABIs.
//
//   - Contract ABIs compiled from this repo's src/ (plus two v4-periphery
//     lens contracts that compile cleanly standalone): ./abi.generated.ts
//     (script-js/generate-abis.mjs — regenerate with `npm run gen:abi`
//     there, drift-check with `npm run check:abi`).
//   - ABIs that can't be generated (no source in this repo, or a solc
//     version conflict): ./abi.vendor.ts, hand-written and documented there.
//   - Standard ERC20 reads: viem's own `erc20Abi`, re-exported here so call
//     sites don't need a second import.
//
// Each generated export below is the FULL contract ABI (not a curated
// subset) — call sites narrow by `functionName` as before.

export { erc20Abi } from 'viem';

import {
  ArtCoinsAirdropAbi,
  ArtCoinsFactoryAbi,
  ArtCoinsHookAbi,
  ArtCoinsHookSkimFeeAbi,
  ArtCoinsHookStaticFeeAbi,
  ArtCoinsLpLockerAbi,
  ArtCoinsMevDescendingFeesAbi,
  ArtCoinsMevLinearFeesAbi,
  ArtCoinsMevTimeDelayAbi,
  ArtCoinsTokenAbi,
  StateViewAbi,
  V4QuoterAbi,
} from './abi.generated';

export {
  ArtCoinsFactoryAbi as factoryAbi,
  ArtCoinsTokenAbi as tokenAbi,
  ArtCoinsHookAbi as hookBaseAbi,
  ArtCoinsHookSkimFeeAbi as skimHookAbi,
  ArtCoinsHookStaticFeeAbi as staticHookAbi,
  ArtCoinsLpLockerAbi as lockerAbi,
  ArtCoinsAirdropAbi as airdropAbi,
  ArtCoinsMevLinearFeesAbi as mevLinearAbi,
  ArtCoinsMevDescendingFeesAbi as mevDescendingAbi,
  ArtCoinsMevTimeDelayAbi as mevTimeDelayAbi,
  StateViewAbi as stateViewAbi,
  V4QuoterAbi as quoterAbi,
};

// Hand-written: no source in this repo (ReferralPayout), or a solc-version /
// nested-remapping conflict that makes generating them not worth it
// (Permit2, UniversalRouter). See abi.vendor.ts for the per-ABI rationale.
export { permit2Abi, universalRouterAbi, referralPayoutAbi } from './abi.vendor';
