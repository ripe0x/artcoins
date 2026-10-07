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

## package u2: factory rules, referral escrow claim (D46, D47, D52, D53, D57)

scope: `ui/**` and this file. `deployments.generated.ts` untouched. no dependency changed.

### what changed

| area | change | files |
|---|---|---|
| referral cap | max = `floor(baselineSkimBps * (BPS - bountyBps - minProtocolSkimShareBps) / BPS)`, clamped to the 1% ceiling, zero when the bounty leaves no room. same integer inequality as `_validateFee` (`ReferralCapAboveProtocolFloor`). slider max follows the baseline and bounty on the form, an over max value shows the maximum and a "set it" button, the validator blocks it. `minProtocolSkimShareBps` is read from the factory | `lib/launchRules.ts`, `lib/encodeV2.ts`, `components/PoolConfigForm.tsx` |
| lp fee floor | `minLpFee()` read from the factory (new in the abi), slider min and validator error below it (`LpFeeBelowMinimum`) | `lib/factoryState.ts`, `lib/encodeV2.ts`, `components/PoolConfigForm.tsx` |
| string caps | name 64, symbol 16, image 2048, metadata 4096, context 4096, in utf8 bytes via `TextEncoder`, on the exact value the builder sends (name, symbol, image trimmed). live byte counters, the char `maxLength` on name and symbol is gone. a unit test reads `ArtCoinsTokenV2.sol` and fails if the numbers drift | `lib/constants.ts`, `lib/launchRules.ts`, `components/TokenConfigForm.tsx`, `components/formUi.tsx` |
| tax exempt allowlist | per entry reads `exemptAllowed`, `enabledEscrows`, `enabledExtensions` (the three ways `_validateTax` lets an entry through; this launch's locker and hook are known client side). a refused entry shows "not allowed by the launcher owner" and blocks the launch. unread entries block too (never assumed allowed). duplicates rejected | `lib/factoryState.ts` (`useExemptStatus`), `lib/launchRules.ts`, `lib/encodeV2.ts`, `components/TaxForm.tsx`, `pages/DeployPage.tsx` |
| tax mode text | VENUE: side pools taxed. HARD: side pools blocked, and listing a v2 pair later traps its lps (they cannot withdraw, their weth is stuck). both modes: liquidity on the canonical pool is locker only, third party lp goes to side pools (D46). NONE: canonical pool stays open | `components/TaxForm.tsx`, `lib/encodeV2.ts` (hard warning), `components/ReviewAndDeploy.tsx` |
| protocol floor text | "protocol keeps at least X% of the skim" now states it holds for referred swaps too (D52, the factory wires the floor into pool init since 0ff16f3) and the referral cap maximum is shown on the pool step, the header strip and the review step | `components/PoolConfigForm.tsx`, `pages/DeployPage.tsx`, `components/ReviewAndDeploy.tsx` |
| defaults | once the factory answers, the coin 111 defaults are pulled inside its limits (lp fee up to the minimum, bounty down to the ceiling, referral cap down to the maximum) so an untouched form launches. only ever moves a value that is out of range | `pages/DeployPage.tsx` |
| referral payout | v2 default payout is the escrow (D57). the referral page asks the coin's factory `enabledEscrows(payout)` (or matches the stack escrow) and then shows an escrow panel: explains `claim(referrer, address(0))`, anyone may trigger it, eth goes to the referrer, `selfClaimOnly` and `claimTo`. balance read `balances(referrer, 0)`, simulated claim, receipt checked. a typed address claims for another referrer. v1 coins and a non escrow v2 payout keep the old ReferralPayout flow | `components/EscrowClaim.tsx`, `lib/escrowClaim.ts`, `pages/ReferralsPage.tsx` |
| abis | factory and escrow abis now come from the contract artifacts `ArtCoinsFactoryV2` and `ArtCoinsFeeEscrowV2` (superset of the interface: `minLpFee`, `exemptAllowed`, `tokenDeployer`, `owner`, additive errors). the generator fails if a contract abi ever loses an interface item. other v2 abis still come from the interfaces. regenerated, hook and token abis picked up the current interfaces | `scripts/gen-abis.mjs`, `lib/abi/v2/*` |

### checks

| check | result |
|---|---|
| build artifacts | `/tmp/claude-0/forge.sh build --skip "test/**" --skip script` |
| `npm run gen:abi` then `npm run check:abi` | abis match artifacts |
| `npm run build` | passes (`tsc -b` incl. tests, then vite). the vite `eval` warning is from a dependency and was there before |
| `npm run lint` | 0 errors, 0 warnings |
| `npm test` | 47 pass. new `test/launchRules.test.ts`: referral cap worked values, tightness (max passes the bigint solidity expression, max+1 fails) on a grid, negative room, validator at and over the cap, floor 1667 vs 1000; utf8 caps at the boundary per field, multibyte (2, 3, 4 byte chars), trimmed fields, drift guards against `ArtCoinsTokenV2.sol` and `Constants.sol`; lp fee floor; exempt allowlist (allowed, refused, unread, no factory, duplicates); escrow claim selector against the forge artifact and the self claim only block |
| `npm run smoke` | server render ok for every route (no wallet) |

### things to know

| item | detail |
|---|---|
| default form vs the floor | the coin 111 style defaults (bounty 83.33%) leave exactly 16.67% for the protocol. at the deploy script floor of 10% the max cap is 0.4% (default 0.25% passes). at a floor of 16.67% or more the maximum is 0 and the bounty default is clamped down by the new defaults step. the old unit test ctx used 1667, changed to the script value 1000 |
| exempt reads | three reads per entry (max 16 entries, one multicall). the factory also requires an exempt entry to have code (`InvalidTaxConfig`), the ui does not check code, the launch simulation shows it |
| escrow vs page text | the escrow balance is per address across all coins and any failed lp fee push, the page says so |
| not browser tested | wallet prompts and the claim flow were only type checked and server rendered here |

### still needs the deployed v2 addresses or other owners

| item | blocked on |
|---|---|
| v2 stack (`V2` export or `VITE_V2_*`, with `VITE_V2_ESCROW` for the stack fallback match) | v2 deploy and registry entry |
| run a launch on a fork against the deployed v2 factory with the encoder output, including a venue tax launch with an allowlisted and a refused exempt entry, and an over cap referral and a below min lp fee launch to confirm the revert names match the ui messages | v2 deploy |
| run a referred swap on a v2 coin, then the escrow claim from the ui against the deployed escrow, with and without `selfClaimOnly` | v2 deploy, a browser |
| the owner must allowlist (`setExemptAllowed`) the fee swapper, burn router and any venue helper before launches can exempt them. the form only shows what the factory says | launcher owner |
| the referral page matches the escrow through `enabledEscrows`: the escrow must be enabled on the factory (`setEscrow(escrow, true)` in the deploy script) or `VITE_V2_ESCROW` set | deploy script, config |
| escrow admin ui (`setSelfClaimOnly`, `claimTo` buttons), vault and airdrop claim pages, tax venue admin actions | product decision |

### follow up: refund address in swap hookData (D58, V2H-03)

| item | detail |
|---|---|
| change | every swap the ui sends or quotes through the v2 hook now carries `mevModuleSwapData = abi.encode(connected wallet)` inside `PoolSwapData`. without it a price limited partial fill's skim refund is credited in the escrow to the universal router and stranded |
| how | `encodeSwapHookData({referrer, refundTo})` in `lib/attribution.ts`. the attribution part (`poolExtensionSwapData`) is unchanged byte for byte. `components/SwapWidget.tsx` sets `refundTo` only when the pool's hook equals the configured v2 hook, so v1 pools keep their old hookData. same bytes go to the quoter and the swap |
| no wallet | with no connected wallet there is no refund address, the quote is read without one, the send path needs a wallet anyway |
| tests | `test/hookData.test.ts`: the encoded hookData decodes to the user through a port of `HookCalldata.refundTo` (same offsets and checks), `mevModuleSwapData` is exactly 32 bytes, attribution unchanged with a referrer, zero or invalid refund address never encoded, plain `0x` with neither. `npm test` 51 pass, build and lint pass |
| not verified | against deployed bytecode or the live universal router: needs the v2 deploy. the i1 fork tests already cover the hook side (`test_i1_partialFill_universalRouter_withRefundAddress_nothingStranded`) |

### follow up: v2 airdrop claim path (V2B-04)

| item | detail |
|---|---|
| change | `pages/ClaimPage.tsx` now routes by token. when a v2 stack is configured (`getV2Stack`) the page reads `factory.isArtCoin(token)` and `deploymentInfo(token).extensions` on the v2 factory. a v2 coin goes to the new v2 claim, anything else (and every chain with no v2 stack) keeps the v1 claim unchanged. an rpc failure on the factory read shows an error, it never silently falls to v1 |
| index and address | the extension index is the position in `deploymentInfo.extensions` (the factory pushes them in config order, the airdrop keys the tranche by the same position). candidates are the entries equal to the configured v2 airdrop address, or every entry when none is configured, probed with `tranche(token, index)` (a non airdrop extension has no such function, the read fails, the candidate is dropped). zero supply tranches never match |
| which tranche | `pickTranche`: the allowlist file's optional `index`, else the tranche whose on-chain root equals the file root, else the first. a root mismatch is shown, not claimed against |
| proof | same `StandardMerkleTree` over `["address","uint256"]` as `lib/merkle.ts`, verified locally before the claim button enables. `claim(token, index, wallet, amount, proof)` through the generated `airdropV2Abi`. views: `amountAvailableToClaim(token, index, ...)`, `leafClaimed` |
| windows | `lib/airdropV2.ts` `trancheState` mirrors the contract: locked before `lockupEnd`, vesting, vested, closed at `sweepTime` (claim reverts), swept. the page shows lockup end, vesting end, claim window close (`sweepTime = vestingEnd + 14 days`), sweep due or done, sweep recipient. no sweep button, it is permissionless and pays only the fixed recipient |
| errors | decodes `ClaimWindowClosed`, `AlreadySwept`, `ZeroClaim` besides the v1 names |
| tests | `test/airdropV2.test.ts` (new): a port of `ArtCoinsAirdropV2._leaf` and of OpenZeppelin `MerkleProof` pair hashing. two leaf tree built by `lib/merkle.ts` has the same leaf hashes and the same root as the solidity recomputation, checked against fixed vectors computed with `cast keccak` and `cast abi-encode`. ui proofs verify through the solidity walk, a wrong amount does not. window boundaries, candidate indexes, tranche pick. `npm test` 57 pass, `npm run build` and `npm run lint` pass |
| allowlist file | gains an optional `index` field (additive, `AllowlistFile`). `script-js/build-allowlist.ts` is outside this change and does not write it, the root match covers that |
| not verified | against a deployed v2 airdrop: none exists yet. not run in a browser (another agent owns the smoke). `VITE_V2_AIRDROP` (or the registry `V2.airdrop`) should be set when a v2 airdrop is deployed, otherwise the page probes every extension |
| status | V2B-04 fixed |

### follow up: browser run findings UI-E2E-01 to -06 (see ui-e2e.md)

| id | change | files |
|---|---|---|
| UI-E2E-01 | discovery scans the registry legacy factory (`STACKS.legacy`, from its deploy block) as a v1 source: it emits the same `TokenCreated` event (topic 0x9299d1d1…, checked on the fork), so LAYER gets a card (`artcoins factory v1 (legacy)`, block 25045152) and a page with the widget on the weth calldata path. the open stack launched no coin and is not scanned. `TokenRecord.legacy` is new. the pair row comes from `classifyPool` (native ETH, WETH, or unsupported) instead of the hardcoded "native ETH". legacy coins skip the anti sniper reads (older module abis) and the widget sends empty hookData with a note instead of a referrer (the legacy hook reads none, and the weth path was only proven with `0x`). skim rows show "Fee config unavailable." as the legacy hook has no `skimConfig` | `lib/discovery.ts`, `lib/useTokens.ts`, `components/OfficialBadge.tsx`, `components/TokenCard.tsx`, `pages/TokenDetailPage.tsx`, `components/SwapWidget.tsx` |
| UI-E2E-02 | `sellApprovalSteps`: neither approval step is offered above the balance, so the button reads "Insufficient 111" and nothing can be signed | `lib/chainClock.ts`, `components/SwapWidget.tsx` |
| UI-E2E-03 | chain deadlines use the chain clock: `useChainNow` = latest block timestamp plus the seconds since it was read (a skewed browser clock cancels out), browser clock only when no block is known. permit2 expiry is signed from `latestChainTimestamp` (fallback: browser clock) plus deadline plus 5 min, and the "is the allowance still good" check adds a 120 s margin (`CHAIN_DEADLINE_MARGIN_SEC`). the anti sniper countdown on the token page uses the same clock | `lib/chainClock.ts`, `lib/useChainNow.ts`, `components/SwapWidget.tsx`, `pages/TokenDetailPage.tsx` |
| UI-E2E-04 | deprecated notice says "owner only on the v2 factory" | `pages/DeployPage.tsx` |
| UI-E2E-05 | copy follows D59: the hook pays the referral straight to the referrer, only a failed push (a contract rejecting eth with 2,300 gas) sits in the escrow and is claimed on the referral page. heading is now "Referral earnings that could not be delivered". pool form hint and review row say referrers are paid in eth on each swap | `components/EscrowClaim.tsx`, `components/PoolConfigForm.tsx`, `components/ReviewAndDeploy.tsx`, `lib/escrowClaim.ts` (comment) |
| UI-E2E-06 | `contractURI()` leaves the multicall: `readContractUri` reads it alone through react query with an explicit 300M gas limit, a 60 s timeout, one retry without the explicit gas when the node refuses it, never a retry after a timeout. a failure leaves the symbol placeholder (tooltip says why). the renderer row shows `…` while loading and `—` when the read failed, "default (on-chain)" only when the token answered the zero address | `lib/contractUri.ts`, `pages/TokenDetailPage.tsx` |

tests

| suite | result |
|---|---|
| `npm test` | 74 pass (new: `chainClock.test.ts`, `contractUri.test.ts`, `discovery.test.ts`) |
| `npm run build`, `npm run lint` | pass (the rolldown direct eval warning comes from a dependency, as before) |
| `npm run test:e2e` on an anvil fork at block 26130269 with the v2 stack deployed (project `v2`) | 19 of 19 pass, 1.8 min. the five `test.fail` cases are real tests now (03 over balance, 05 wording, countdown, referral copy) and LAYER runs through the widget (04a: page, WETH pair, buy 0.01 eth, sell all, empty hookData, router left with 0 weth) |

e2e changes: 01 expects both cards ("2 tokens total"), 04a is the widget scenario, `fixtures.ts` filters reown's `Error checking Cross-Origin-Opener-Policy: Failed to fetch` (remote probe the sandbox blocks) as noise, the v2 referral test looks for the new heading.

open items

| item | note |
|---|---|
| UI-E2E-07 | image `onError` still leaves an empty box, not in this batch |
| explicit gas on contractURI | on the 60M anvil the call still fails and the placeholder shows (test 02a). public rpcs were not tried with the explicit 300M, the single retry without it covers a node that refuses it |
| idle chain on anvil | the chain clock is the latest block timestamp. on a mainnet node that is at most a block old. an idle anvil fork can lag, so the permit2 expiry signed from it is only good while the fork has been mined recently (the e2e mines before every sell) |
| `script-js/gen-addresses.mjs` | not touched (outside scope): the legacy locker is read from the launch event, not the registry |
| deploy script | compiled with `--skip src/v2/keepers/CollectFlushKeeperLayer.sol --skip script/v2/RunKeeperLayer.s.sol`; `cache/DeployV2Stack.s.sol` removed and `tmp/v2-deploy-1.json` restored afterwards |
