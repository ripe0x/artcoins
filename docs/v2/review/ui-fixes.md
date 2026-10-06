# ui fixes (package u1)

scope: `ui/**` plus this file. review: `docs/v2/review/ui.md` (25 findings) and `docs/v2/review/address-wiring.md`. no dependency changed (`package.json` only gained scripts). `src/lib/deployments.generated.ts` untouched, the generator was not changed (see "v2 stack config").

## result

| check | before | after |
|---|---|---|
| `npm ci && npm run build` (`tsc -b` then `vite build`) | fails, 5 tsc errors | passes, also typechecks `ui/test` and `ui/scripts` (new `tsconfig.test.json`) |
| `npm run lint` | 1 error, 3 warnings | 0 errors, 0 warnings |
| `npm test` (new) | none | 29 tests pass |
| `npm run smoke` (new) | none | server renders deploy, tokens, token detail, claim, referrals, footer without a wallet, all ok |
| `npm run check:abi` (new) | none | abi files match the forge artifacts |
| fork proof, buy then sell coin 111 through the universal router (`scripts/fork-swap-sim.ts`, anvil at block 26130269) | sell never worked | both succeed, buy equals the quote exactly, sell pays 0.0219 eth equal to its quote |
| live read proof of the token page reads (`scripts/check-token-reads.ts`, mainnet) | hook and locker reads failed | all decode: pool key matches the launch event pool id, skim 6000/8333/250/5000, mev, token, factory |
| live discovery (`scripts/check-discovery.ts`, mainnet) | scanned from block 0 | one `getLogs` from the registry deploy block, finds coin 111 in 650 ms |

## findings

| id | status | what changed | files | how verified |
|---|---|---|---|---|
| UI-01 mainnet addresses zero, eth can go to 0x0 | fixed by the wiring job, hardened | config reads the registry; deploy and swap never write to a zero address: deploy needs a configured v2 stack, swap needs a classified pool and a nonzero quoter, claim stays disabled when the airdrop is zero | `lib/config.ts`, `lib/v2.ts`, `pages/DeployPage.tsx`, `components/SwapWidget.tsx`, `pages/ClaimPage.tsx` | read config; smoke render |
| UI-02 unknown chain falls back to sepolia | fixed by the wiring job, hardened | `getAddresses` throws, every page uses `useAddressesOrNull` (a notice, never a throw), writes need the wallet on mainnet (`useWalletGate`, switch button), wagmi is mainnet only | `lib/useChain.ts`, `main.tsx`, `components/Footer.tsx`, pages | smoke render; tsc |
| UI-03 stale `deployToken` abi | fixed | v2 abis generated from the frozen interfaces, `deployToken` selector `0x73dd3f0f` pinned to the forge `methodIdentifiers`; v1 abis generated from the current stack contracts; hand written factory, token, hook, locker and mev abis removed | `lib/abi/v1/*`, `lib/abi/v2/*`, `scripts/gen-abis.mjs`, `lib/abi.ts` | `test/encodeV2.test.ts` (selector and struct round trip), `npm run check:abi` |
| UI-04 deploy fee never sent or read | fixed | `deployFee()` read from the factory (30 s poll), shown, sent as `msg.value = deployFee + extension eth`, read again right before signing and the send aborts if it moved | `lib/factoryState.ts`, `lib/encodeV2.ts`, `components/ReviewAndDeploy.tsx` | `test/encodeV2.test.ts` (value), code |
| UI-05 reward bps ignore the protocol slot | fixed | project recipients must sum to `10000 - defaultProtocolFeeBps` (read from the factory), the default recipient is set to that, the protocol slot is shown as a fixed row, copy no longer says "all rewards go to your wallet", max recipients is 6 | `components/RewardsForm.tsx`, `lib/encodeV2.ts`, `pages/DeployPage.tsx` | `test/encodeV2.test.ts` (rejects 10000, accepts 8000) |
| UI-06 sell always reverts | fixed | native pools (every v2 pool and the live skim pools): `SWAP_EXACT_IN_SINGLE, SETTLE_ALL(coin), TAKE_ALL(eth)`, eth lands at the user, no wrap or unwrap. old weth pools: `TAKE` to the router (`address(2)`, amount 0 = open delta) then `UNWRAP_WETH` | `lib/swap.ts` | fork: sell of coin 111 succeeds and pays its quote. unit: command and action order for both pool kinds. the weth path is proven by encoding against the router source only, no weth pool exists on the current or v2 stack to fork |
| UI-07 old hook abi, wrong direction | fixed | no hook read decides direction: it is derived from the pool key and the coin address; pool key comes from the locker `tokenRewards`, and trading is disabled unless it hashes to the pool id the launch event announced | `lib/swap.ts`, `pages/TokenDetailPage.tsx` | `scripts/check-token-reads.ts` (pool key matches event id), swap tests |
| UI-08 swap widget supports only weth pools | fixed | native eth path (see UI-06), quoter `0x52F0E24D...1203` added to the mainnet config (code present, `poolManager()` checked), stateview from the registry | `lib/config.ts`, `components/SwapWidget.tsx` | fork sim |
| UI-09 no `deprecated()` gating, no simulation | fixed | deploy page reads `deprecated()` and `owner()`, shows "launches are owner only on the current factory" and disables send unless the wallet is the owner; launch and swap are simulated (`simulateContract`) and the decoded revert shown before anything is signed | `pages/DeployPage.tsx`, `components/ReviewAndDeploy.tsx`, `lib/errors.ts` | smoke render shows the banner (default state); fork and live reads of the same calls; code |
| UI-10 self asserted Verified badge | fixed | no "Verified". a neutral "artcoins factory v1/v2" badge means the token was announced by a registry factory (discovery reads those factories only); v2 also checks `factory.isArtCoin(token)`; the token's own `isVerified()` shows as "creator flag, not a trust signal" | `components/OfficialBadge.tsx`, `pages/TokenDetailPage.tsx`, `components/TokenCard.tsx` | code |
| UI-11 strangers' metadata rendered unfiltered | fixed, partly | images only from `https:`, `ipfs:`, `ar:` (via gateway) and `data:image/` (256 KiB cap), no credentials, `referrerPolicy="no-referrer"`, lazy; names, symbols and text stripped of control and bidi characters and clamped; lookalike flag on duplicate normalised name or symbol; contract address shown with a warning. not done: an image proxy, size cap for https images, a curated default list, a report flow | `lib/security.ts`, `lib/metadata.ts`, `components/TokenCard.tsx`, `components/TokenMetadataModal.tsx`, `lib/discovery.ts` | `test/security.test.ts` |
| UI-12 scans from block 0, single factory | fixed | discovery reads the current factory from its registry deploy block and the v2 factory (`TokenCreatedV2`, full config) when configured, one `getLogs` per factory that halves the range on an rpc error; malformed route params never reach reads. not done: persisting the last scanned block, paging, the legacy and open factories (LAYER) | `lib/discovery.ts`, `lib/useTokens.ts` | live: finds coin 111 |
| UI-13 dev buy encoding and min out | fixed | `abi.encode(recipient, refundRecipient, uint128 minTokenOut)` (exactly 96 bytes), `extensionBps` forced to 0, nonzero min out required, an estimate from the exact pool curve (bigint tick math, lp fee and baseline skim off the eth in) fills the field with a tolerance | `lib/encodeV2.ts`, `lib/devBuy.ts`, `lib/curve.ts`, `components/ExtensionsForm.tsx` | `test/curve.test.ts` (tick math anchors, closed form, estimate), `test/encodeV2.test.ts` |
| UI-14 quote handling | fixed | zero min out refused in the encoder and the button; quotes refresh every 12 s and again right before sending; same `hookData` goes to quoter and swap; price impact vs pool mid (fees included) shown, acknowledgement required above 10%, unknown impact blocks; deadline selectable 2 to 30 min from the chain clock; "max" keeps 0.005 eth for gas | `components/SwapWidget.tsx`, `lib/swap.ts` | swap tests, fork sim (quote equals fill) |
| UI-15 mev defaults conflict | fixed | one module, linear skim, start 68.69% over 69 min (`Constants`), window 1 to 180 min and start at most 90% and at least the baseline enforced client side; mev on without a configured module is an error, never a silent disable; `MevConfigV2` all zero when off | `lib/encodeV2.ts`, `components/AntiSniperForm.tsx` | `test/encodeV2.test.ts` |
| UI-16 pool data and fee units | fixed | v2 fee struct, units documented in `encodeV2.ts` (lp fee pips, skim and referral cap per 1e5, bps per 1e4), tick as `tickIfToken0IsArtCoin` with price and fdv shown, presets mirror `script/LaunchDefaults.sol` | `lib/encodeV2.ts`, `lib/launchDefaults.ts`, `components/PoolConfigForm.tsx` | `test/encodeV2.test.ts` |
| UI-17 referral silent and sticky | fixed | referrer shown with its source and a "don't use a referrer" switch; `?ref=` kept in `sessionStorage` only; mixed case must checksum, zero and the connected wallet rejected; `/config.json` fetched with `no-cache` | `lib/useReferrer.ts`, `lib/referrerCheck.ts`, `components/ReferrerNotice.tsx` | `test/security.test.ts` |
| UI-18 supply chain and build health | not changed | dependency set untouched on purpose. needs ci (outside `ui/`): `npm ci --ignore-scripts`, `tsc`, `eslint`, `npm audit --omit=dev`; pinning versions; dropping the irys sdk | none | none |
| UI-19 secrets in the bundle | fixed | the alchemy key is ignored unless `VITE_ALCHEMY_KEY_RESTRICTED=1` asserts it is domain restricted; `VITE_MAINNET_RPC_URL` for a keyless endpoint; default is the tenderly public gateway; walletconnect id documented as public by design; `.env.example` and `ui/README.md` explain | `main.tsx`, `.env.example`, `README.md`, `vite-env.d.ts` | build, code |
| UI-20 allowance scope | fixed | approvals are for the exact amount being sold and permit2 expiry is deadline + 5 min (was max for 30 days) | `components/SwapWidget.tsx` | code; fork sim uses the same exact pattern |
| UI-21 metadata link hardening | fixed | `external_url` rendered only when https without credentials; all json strings cleaned and clamped; image goes through the scheme filter | `components/TokenMetadataModal.tsx`, `lib/security.ts` | `test/security.test.ts` |
| UI-22 image upload | fixed, partly | svg refused in the uploader, manual url field validated with the same scheme filter and shows an error. not done: explaining the irys signature in the ui | `components/ImageUploader.tsx`, `components/TokenConfigForm.tsx` | code |
| UI-23 tx state handling | fixed, partly | receipt `status` checked (a reverted launch, swap or claim says so), launch token read only from `TokenCreatedV2` logs emitted by the factory called, route params validated with `isAddress` before any read or fetch path, error boundary per route. not done: `useReplaced` handling for sped up or dropped txs (the page tells the user to check the link) | `components/ReviewAndDeploy.tsx`, `pages/ClaimPage.tsx`, `pages/ReferralsPage.tsx`, `components/ErrorBoundary.tsx` | smoke render (bad param renders a notice) |
| UI-24 referrals page wrong shape | fixed | reads `skimConfig` through one normaliser that handles the 8 output v1 tuple and the v2 struct; flush and held reads removed (they do not exist on the live hook); claim shows the payout address, v2 compares it with the factory's own `referralPayout()`, v1 requires an explicit confirmation because the deployer chose it; claim state follows the receipt | `pages/ReferralsPage.tsx`, `lib/poolReads.ts` | live read of coin 111 decodes |
| UI-25 provenance and staleness | fixed, partly | rebranded to artcoins (header, title, footer, wallet app name), `FeeFlowPage` (a hardcoded unrelated sepolia stack) and its route and nav link deleted, footer source link points at `ripe0x/artcoins`, footer lists current and v2 stacks from the config, implied price and fdv shown from the tick. not done: an escrow claim ui, `script-js/sync-addresses.mjs` (outside `ui/`, already rewritten by the wiring job) | `components/Header.tsx`, `components/Footer.tsx`, `App.tsx`, `index.html` | build |

tsc errors from the review: `arweave.ts` x2 (constructor parameter type, `Buffer` for the irys upload), `ReferralsPage.tsx` x2 (rewritten), `FeeFlowPage.tsx` (deleted). eslint error: `FeeFlowPage` unused var (deleted). the 3 exhaustive-deps warnings went away with the rewritten forms.

## v2 stack config

`deployments.generated.ts` has no v2 stack until the registry has one, and `script-js/` is outside this package, so the generator was not changed. `lib/v2.ts` resolves the stack in this order and returns null on any other chain:

1. a `V2` export of `deployments.generated.ts` (shape `V2Stack`: `factory`, `hook`, `locker`, `escrow`, `mevModule`, `devBuy`, `vault`, `airdrop`, `poolExtension`, `deployBlock`) once the generator emits one
2. env `VITE_V2_FACTORY`, `VITE_V2_HOOK`, `VITE_V2_LOCKER` (required together), optional `VITE_V2_ESCROW`, `VITE_V2_MEV_MODULE`, `VITE_V2_DEV_BUY`, `VITE_V2_VAULT`, `VITE_V2_AIRDROP`, `VITE_V2_POOL_EXTENSION`, `VITE_V2_DEPLOY_BLOCK`

with neither, the deploy page shows the closed banner ("launches are owner only on the current factory", read live from `deprecated()`), the form still works as a preview, and discovery lists the current stack only.

## what is left (needs the deployed v2 addresses or other owners)

| item | blocked on |
|---|---|
| set the v2 stack (generator emit or `VITE_V2_*`), including the v2 `deployBlock` | v2 deploy and registry entry |
| run a launch end to end against the deployed v2 factory on a fork (simulate and send from the encoder output), then the same for a dev buy, a vault and an airdrop | v2 deploy. the encoder is proven against the frozen interface (selector, struct round trip, field units), not against deployed bytecode |
| confirm the v2 hook and v2 quoter path: the swap widget is proven on the live skim hook (same `hookData` decode, same native pool shape); v2 pools use the same router actions but have not run through the quoter | v2 deploy |
| `ArtCoinsAirdropV2` and `ArtCoinsVaultV2` claim pages: the claim page still speaks the v1 airdrop abi (inert on mainnet, no airdrop is configured) | v2 extension addresses and a decision on the claim ux |
| v2 fee escrow claim ui (failed pushes land there), tax venue admin actions, token admin actions | v2 escrow address, product decision |
| ci for `ui/` (`npm ci --ignore-scripts`, `npm run build`, `npm run lint`, `npm test`, `npm run check:abi`, `npm audit --omit=dev`) | `.github/` is outside this package |
| `gen-addresses.mjs` could emit the v2 stack and the quoter into `deployments.generated.ts` and the registry could carry the quoter | `script-js/` and `deployments/` owner |
| image proxy or host allowlist, curated token list, report flow, listing the legacy factory (LAYER) and the open factory | product decision |
| browser level testing (wallet prompts, real gas estimation, rainbowkit flows): none was possible here, only server render, unit tests and a fork script | a browser |

## notes for reviewers

| note | detail |
|---|---|
| anvil default account | on mainnet it carries a 7702 sweeper delegation, so a fork sell paid to it looked like it received nothing. the fork script uses a fresh funded key and says so in a comment |
| price impact on the live pool | a 0.05 eth buy of coin 111 shows 6.8% against mid, that is the 0.5% lp fee plus the 6% baseline skim plus curve depth. the ui shows it and asks for a confirmation only above 10% |
| dev buy size | the default curve is steep: 0.1 eth buys about 3.1e8 coins of a 1e9 supply, not the 9e8 a flat price would suggest. this is why `minTokenOut` comes from the curve and is required |
| `git` | `ui/src/pages/FeeFlowPage.tsx` is deleted from the working tree and was also removed from the index with `git rm --cached` (a staged deletion). nothing was committed |
