# artcoins system review (first full draft)

status: draft for the director. status columns are updated by the director at the end. this is NOT a formal audit.

## 1. scope and method

| item | statement |
|---|---|
| what this is | a structured engineering review with proof tests. it is not a formal audit, not a security certification, and no firm signed off. nothing here says the system is safe. |
| contracts with proof tests | second independent pass. every medium or higher contract finding has a passing proof test that asserts the bad outcome (`test_bug_*`) or a trace. controls and holds are pinned as `test_holds_*` and `test_control_*`. |
| scripts, ui, keepers, ci, docs, registry | first pass only. read the code, ran builds and `cast` reads, no second reviewer. ui behaviour in a browser and wallet was not run. |
| fork tests | pinned block 26130269 (harness constant `FORK_BLOCK`) against live contracts. several area suites forked at nearby blocks (26130300 to 26130400) before the pin; numbers are quoted as the reviews report them. |
| prior audit | the prior audit's attachments (audit text, full archive, credits engine bundle) were not available. its claims were taken from the brief and re checked from code, see section 5. |
| chain reads | tenderly public gateway, read only, 2026-10-06. no broadcasts, no keys. etherscan was not usable (no key), blockscout was used for creator data. |
| owner model | one eoa owns nearly everything (0xCB43078C32423F5348Cab5885911C3B5faE217F9). no multisig, no timelock. every "owner can" below means that one key. |
| ids | kept from each review. hooks review ids H1 to H14 collide with repo hygiene ids H1 to H25, so hygiene ids appear here as HY1 to HY25 (HYn = hygiene Hn). extensions finding F1 is a finding, package f1 is the factory package. registry and docs rows were numbered here (RG, DC). harness findings are HR. |
| status vocabulary | `fixed` only where a review file or STATUS.md says the package is done (today: a0, k1 part 1, registry). everything else is `in progress` or `planned`. "not fixable on live" means the deployed contract is immutable and v2 only replaces it. |
| runbook ids | the runbook (job 4) is not started. RB ids below are provisional, listed in section 2, and must be renamed when the runbook lands. |
| disclosure | review docs name live critical and high issues on immutable contracts (LF-01, K-01, H14). per D26 the branch and draft pr are already public. the owner should read the mitigations first. |
| not covered | `lib/`, permanent collection contracts (renderer 0x9438, adapters, TokenAdminPoker), third party infra, legacy hooks, the LAYER pool end to end. |

## 2. headline table (ten most important)

severity: critical, high, medium. live means exploitable or biting on a deployed contract today. latent means code is wrong but no live coin or pool uses the path.

| # | ids | sev | live or latent | title | fixed in v2 | mitigation today |
|---|---|---|---|---|---|---|
| 1 | LF-01 | critical | live: locker 0x866e (coin 111), legacy locker 0x75BE (LAYER) | `collectRewardsWithoutUnlock` is permissionless and takes the position manager's whole credit in the caller's unlock. uncollected lp fees can be redirected | not fixable on live. l1 in progress (d1, collect only via own unlock). k1 helper done (narrows exposure only) | RB-01 |
| 2 | H14, FT-01 | high | live: coin 111, hook 0x636c | add then remove canonical liquidity in one unlock mints tax exemption budget at zero capital, spent on any side venue. 111 buys on side venues go untaxed (15%) | not fixable on live (token immutable). t1 and h1 in progress (b1, d2) | RB-10 |
| 3 | LF-02, K-01 | high | live: 111 fee swapper 0xeBD9 | any caller moves the swapper's eth slot from escrow into the swapper, where no function can forward it. permanent loss for the recipient. collect plus claim fits in one tx | not fixable on live. p1 and l1 in progress (b5, d1, D13 selfClaimOnly). k1 helper done | RB-02 |
| 4 | LF-09, LF-03 | high | LF-09 live: burn routers 0x2edb (LAYER), 0xE600. LF-03 src only | live routers swap the full balance per call behind stale owner floors (30.8% and 63.9% of spot). src BurnRouter clamp loops in one tx (31 calls, ~29% of balance lost on local, LAYER pool drained 1.9 of 2 weth on fork) | not fixable on live. p1 in progress (b6, BurnRouterV2) | RB-03 |
| 5 | H1, H2 | high, medium | latent for 111 (its recipient implements the selector). live shared hook, any new pool | stream probe decodes outside the try, so an eoa or empty fallback bounty recipient bricks every swap once it holds 0.01 eth. a recipient that rejects eth bricks all skimmed swaps. config is frozen | h1 in progress (b2, d1) | RB-05 |
| 6 | FT-02, FT-03, S-03 | medium | live: open factory 0xf051 (public, fee 0, zero coins) | launch hijack: token address ignores sender and pool or locker config. any caller can also set protocol bps to 0. proved on fork against 0xf051 | f1 in progress (b4). 0xf051 itself: decision needed (owner `setDeprecated(true)`) | RB-04 |
| 7 | H4, H5, H7 | medium | live: any price limited swap on 111 | skim charged on the requested amount, not the fill. 50 eth exact in with a 0.05% limit filled 0.0028 eth and paid 3 eth skim. exact out sell can make the seller pay eth | not fixable on live. h1 in progress (b3, D11) | RB-06 |
| 8 | UI-01 to UI-08 | high | latent: no deployed ui found. not run in a browser | ui has zero mainnet addresses, stale abi (wrong selector), never sends the deploy fee, sell always reverts, wrong hook abi, no native eth pool path. eth can be sent to 0x0, wrong direction swaps | u1 planned | RB-08 |
| 9 | S-01, S-02, S-04 | high | live risk if run: script targets the wrong factory | no script can launch on the current stack. the wiring script hardcodes the open factory 0xf051 and renounces ownership. readme points operators at the legacy deploy | s1 and u1 planned, registry wiring in progress | RB-07 |
| 10 | HY1, HY2, HY3, HY5 | high | live: mirror and ci | mirror pushes any tag to the public repo. v2 review material goes public on merge. origin is the public repo. about 140 fork tests pass without running | ci fixes planned | RB-09 |

provisional runbook items (job 4 owns the real ids):

| id | action | covers |
|---|---|---|
| RB-01 | run the 111 collect and flush keeper on a short cadence (hourly, plus when pending is large), private submission | LF-01, K-04, K-05 |
| RB-02 | never split collect and flush across txs; flush in the same tx; send privately | LF-02, K-01 |
| RB-03 | set LAYER burn router floors near 95% of spot, refresh on a schedule, keep router balances small | LF-09, LF-12 |
| RB-04 | owner calls `setDeprecated(true)` on 0xf051 | FT-02, FT-03, S-03, H11 |
| RB-05 | launch only with bounty and referral recipients that hold code, accept eth and implement `streamForward` | H1, H2, H3 |
| RB-06 | integrators pass no price limit on quote specified skim swaps. publish this | H4, H5, H7 |
| RB-07 | do not run the listed scripts (DeployConversionLockerAndWire, Deploy, DeployNativeEthStack, Launch*, SetUpLayerAutoForward, Live*Verify) against mainnet | S-01 to S-05, S-12 |
| RB-08 | do not host the ui against mainnet | UI-01 to UI-08 |
| RB-09 | confirm which repo origin is, restrict tag pushes, no merge of docs/v2/review to master before fixes ship | HY1 to HY3 |
| RB-10 | decide on the 111 tax exposure: token admin 0xA96a can lower `taxBps`; otherwise accept and monitor | H14, FT-01, FT-05 |
| RB-11 | token admin swaps the 111 renderer if metadata gas matters (renderer is outside this repo) | G1 |
| RB-12 | run `node script-js/verify-registry.mjs` before any owner tx | RG-01 to RG-06 |

## 3. findings by area

columns: id, severity, title, live exposure, proof, status in v2, mitigation today. "block" refers to DESIGN section 3 (b1 to b8, d1 to d8). "pkg" refers to section 8 packages (h1 hook, t1 token, l1 locker and escrow, m1 mev, p1 periphery, r1 renderers, f1 factory, k1 keepers, u1 ui, s1 scripts).

### 3.1 contracts: hooks and mev (contracts-hooks-mev.md)

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| H14 | high | add then remove canonical liquidity mints tax budget | 111, hook 0x636c | test_bug_H14_addRemoveCanonicalLiquidityMintsTaxBudget (TaxBudget.t.sol), live: test_bug_H14_live_addRemoveBudgetBypassesTax (LiveStack.t.sol) | b1, d2: h1 and t1 in progress | RB-10 |
| H1 | high | stream probe bricks swaps for eoa or empty fallback recipient | not 111. any new pool on 0x636c | test_bug_H1_eoaBountyRecipientSelfBricksPool, test_bug_H1_emptyFallbackRecipientBricksForever, control test_control_H1_noSelectorRecipientIsCaught (SkimDelivery.t.sol). also harness test_knownIssue_* | b2: h1 in progress | RB-05 |
| H2 | medium | bid leg push reverts the swap, rejecting recipient bricks pool | any pool with a recipient that can reject eth | test_bug_H2_rejectingBountyRecipientBricksAllSwaps | d1: h1 in progress | RB-05 |
| H4 | medium | exact in buy skimmed on amountSpecified, not the fill | 111 (live proof) | test_bug_H4_exactInBuyPartialFillSkimsUnfilledAmount, live test_bug_H4_live_priceLimitedBuyOvercharges | b3: h1 in progress | RB-06 |
| H5 | medium | exact out sell, seller pays eth on partial fill | skim hook pools | test_bug_H5_exactOutSellPartialFillMakesSellerPayEth | b3: h1 in progress | RB-06 |
| H6 | medium | sniper extra not grossed up on exact output (~24% discount) | static and base hook only (open stack 0xAAd6, LAYER 0xA5eA) | test_bug_H6_sniperExtraExactOutputDiscount | dropped: D14 removes the static and lp fee mev path | none |
| H7 | medium | sniper extra charged on unfilled input | same hooks as H6 | test_bug_H7_sniperExtraChargedOnUnfilledInput | dropped: D14 | none |
| H11 | medium | anyone opens pools for any coin on the shared hook | 111 and any coin on 0x636c | test_bug_H11_openPoolForFactoryCoinOnSharedHook, live test_bug_H11_live_openPoolForCoin111 | d3: h1 and f1 in progress (no open path) | RB-04 for 0xAAd6 family. live 0x636c: none, UIs must filter by `locker != 0` |
| H13 | medium | self referral rebate from protocol leg | 111 (0.25% of volume cap) | test_bug_H13_selfReferralRebate, live test_bug_H13_live_selfReferralRebate | decision needed. D7 freezes the cap, rebate stays possible | none |
| H3 | low | codeless referralPayout reverts referred swaps | not 111 (payout has code) | test_bug_H3_codelessReferralPayoutRevertsReferredSwaps | d1: h1 in progress | RB-05 |
| H8 | low | module window 180 min vs hook cap 15 min, linear fee cliff | legacy and open stacks | test_bug_H8_linearFeesCliffAtHookCap (SniperAndModules.t.sol) | b7: m1 module half (code in tree, STATUS says in progress), h1 hook half in progress | none |
| H9 | low | skim module on static hook reverts swaps for the window | latent | test_bug_H9_skimModuleOnStaticHookRevertsSwapsForWindow | b7, D22: h1 in progress | none |
| H10 | low | static fee direction inverse of docs | no live impact (symmetric) | test_bug_H10_staticFeeDirectionInvertedVsDocs | dropped: D14 | none |
| H12 | low | `setPoolExtension` works on open and never created pools | live hook 0x636c | test_bug_H12_setPoolExtensionBypassesOpenPoolBan | D7: per pool setters removed, h1 in progress | none |
| N1 to N6 | low, info | uncapped gas on probe and push, extension sees amountSpecified, sniper flush erc20 push, extension gas, stray eth, escrow reentrancy lock | live hook | reading, no test | d1 gas caps, D18: h1 in progress | none |

### 3.2 contracts: factory, token, deployer, escrow (contracts-factory-token.md)

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| FT-01 | high | same mechanism as H14, seen from the token | 111 | test_bug_FT01_live111_addRemoveCanonicalSkipsSidePoolTax (fork: 183,185 coin buy pays 27,477 tax, after add+remove pays none), test_bug_FT01_unbackedCanonicalBudgetExemptsSideVenues | b1, d2: t1 and h1 in progress | RB-10 |
| FT-02 | medium | launch hijack, salt binds no sender or pool or locker config | open factory 0xf051 (proved on fork) | test_bug_FT02_launchHijackSameAddressDifferentConfig, test_bug_FT02_FT03_liveOpenFactoryHijackAndZeroProtocol | b4: f1 in progress | RB-04 |
| FT-03 | medium | caller chosen protocol bps, can be 0 | 0xf051. on 0x4959 owner and admins only | test_bug_FT03_publicCallerZeroesProtocolSlot, live leg of the FT-02 fork test | f1 in progress, no named block (confirm gate or floor) | RB-04 |
| FT-05 | medium | admin mutates image, metadata, tax rate beyond renderer | all coins | test_bug_FT05_tokenAdminMutatesMoreThanRenderer | t1 in progress. D8 keeps tax rate tunable inside a frozen cap, so part is accepted. image and metadata setters: confirm removal | RB-10 |
| FT-07 | medium if public | arbitrary tax sink and exempt list | owner only today. 111 sink 0xf5c3 is a contract | test_bug_FT07_publicDeployerRoutesTaxToSelfAndExemptsSelf | d4, D10: f1 and t1 in progress (sink DEAD or bounty recipient) | none |
| FT-04 | low | cannot disable an allowlisted contract whose erc165 changes | no | test_bug_FT04_cannotDisableExtensionWhoseInterfaceCheckFails | f1 in progress, no named block (confirm) | `setDeprecated` only |
| FT-06 | low | tax config not bound to the factory pool | owner only | test_bug_FT06_taxCanonicalPoolNotBoundToFactoryPool | f1 in progress, d2 mirrors tax mode into the hook record (confirm derive or assert) | none |
| FT-08 | low | venue coverage, unlisted dex untaxed, sub 7 wei untaxed | 111 (sushi v2 weth not a venue) | test_bug_FT08_unlistedVenuesAreUntaxed | accepted, documented (d2) | none |
| FT-10 | low | reward array truncation on protocol slot injection | owner only | test_bug_FT10_mismatchedRewardArraysTruncatedByInjection | f1 in progress, no named block (confirm) | none |
| FT-11 | low | escrow `claim` forced push strands erc20 in fee owner contract | yes | test_bug_FT11_escrowForcedClaimStrandsErc20InFeeOwner | b5, D13: l1 in progress (opt in `selfClaimOnly`, so fee owners must opt in) | none |
| FT-09 | info | extension rounding dust to team | yes (zero at 1B supply) | test_bug_FT09_extensionRoundingDustSweptToTeam | f1 in progress (confirm) | none |
| FT-12 | info | `TokenCreated` incomplete, startingTick misleading | yes | reading | section 6 launch event: f1 in progress | registry and calldata |
| FT-13 | info | single step ownable plus renounce, permit2 allowance, no votes, state after extensions | yes | reading | D20 Ownable2Step, D23: in progress | none |

### 3.3 contracts: locker, swapper, burn router, protocol fee (contracts-locker-fees.md)

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| LF-01 | critical | `collectRewardsWithoutUnlock` diverts uncollected lp fees | locker 0x866e (111), 0x75BE (LAYER, hook collects each swap so smaller) | LpLockerReview.t.sol test_bug_LF01_collectRewardsWithoutUnlock_lets_anyone_steal_all_lp_fees. fork: LiveForkReview.t.sol test_bug_LF01_fork_live_111_uncollected_fees_stealable | l1 in progress (d1, no unlock free path). live not fixable | RB-01. k1 helper done |
| LF-02 | high | third party escrow claim strands swapper paired fees | 111 swapper 0xeBD9 | FeeAutoSwapperReview.t.sol test_bug_LF02_third_party_claim_strands_native_fees_in_swapper (and weth). fork test_bug_LF02_fork_live_111_swapper_eth_strandable. keeper test_bug_swapperV1_thirdPartyClaim_strandsEth | b5: p1 and l1 in progress. live not fixable | RB-02 |
| LF-03 | high | burn router impact clamp loopable in one tx | src only (not deployed per records) | BurnRouterReview.t.sol test_bug_LF03_impact_clamp_loops_in_one_tx_and_sandwich_profits. fork test_bug_LF03_fork_src_burnrouter_loop_on_live_layer_pool | b6: p1 in progress | none needed live |
| LF-09 | high | live routers burn full balance behind stale floors | 0x2edb, 0xE600 | LiveForkReview.t.sol test_LF09_fork_live_burnrouter_full_balance_owner_floor (0.503 weth in one call) | b6 replaces both: p1 in progress. live not fixable | RB-03 |
| LF-04 | medium | keeper reward on whole balance | src. live LAYER pool fork run: 0.10 eth keeper for 1.9 weth | test_bug_LF04_keeper_reward_on_whole_balance_farmed_by_loop | b6: p1 in progress | none |
| LF-07 | medium | swapper slippage cap is deploy time, 111 at 500 bps | 111 swapper. not quantified | reading | p1 in progress (FeeAutoSwapperV2 in tree), no named block | convert with a quoted minOut, private send |
| LF-05 | low | slot admins can repoint recipients, zero not rejected | yes, but 111 slot admin is 0xdEaD | test_bug_LF05_recipient_mutable_post_launch_and_zero_recipient_strands_fees | D7: l1 in progress (recipients frozen) | none |
| LF-08 | low | swapper payout failure bricks flush and convert | 111 endRecipient accepts eth today | test_bug_LF08_unpayable_end_recipient_bricks_flush_forever | d1: p1 in progress | none |
| LF-10 | low | controller no rescue, rotation depends on old router | src controller. live PC controller 0xd8C6 | reading | p1 in progress (ProtocolFeeControllerV2) | none |
| LF-11 | low | locker `withdrawETH` uses `transfer` | yes | reading | l1 in progress | none |
| LF-12 | info | live router view under reports enforced minimum | 0xE600 | seen in LF-09 fork test | b6 | keepers read the revert, not the view |
| LF-13 | info | `ISwapRouterV3` unused | n/a | reading | delete, hygiene | none |
| HR-2 | low | `placeLiquidity` leaves wei level coin dust in locker (8,767 wei) | yes | Harness.t.sol test_freshStack_launchBuySell_feeFlows (asserts under 1e9) | l1 (owner sweep exists) | none |

### 3.4 contracts: extensions and renderers (contracts-extensions-renderers.md)

every extension finding is latent on the current and open factories (no extension enabled there). renderer gas findings are live.

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| G1 | medium | coin 111 `contractURI` costs ~177M gas, reverts under 50M and 100M call caps | live, 111, renderer 0x7604 forwarding to 0x9438 (outside this repo) | ForkRenderersReview.t.sol test_measure_G4_liveLayerAnd111 (179,363,374 gas). `cast call --gas-limit 200000000` returns 310KB | not fixable here. b8 adds a gas budget (8m) for v2 renderers: r1 in progress | RB-11 |
| A2 | medium | airdrop root replaceable after lockup plus 1 day while zero claims | latent, legacy extension | ExtensionsReview.t.sol test_bug_A2_airdrop_adminSwapsRootAndTakesEverything | no package in DESIGN. decision needed: ship v2 extensions or leave legacy | none |
| G2 | low | LAYER renderer gas unbounded in trade count (32.4M today) | live, LAYER renderer 0x0572 | ForkRenderersReview.t.sol test_bug_G2_liveLayerRendererExceeds50MGasAsTradesGrow (58.8M at 250,000 trades) | legacy renderer, no v2 package | none |
| R1 | low | svg text unescaped in DynamicBlock and Example renderers | latent, no live coin | RenderersReview.t.sol test_bug_R1_* (3 tests) | b8: r1 in progress (RendererV2.t.sol has R1 regression tests) | none |
| R3 | low | sprite renderer href and animation url unescaped | latent | test_bug_R3_spriteRenderer_imageUrlBreaksOutOfHrefAttribute | b8: r1 in progress | none |
| A1 | low | zero root airdrop plus second entry strands first tranche | latent | test_bug_A1_airdrop_zeroRootThenSecondEntryStrandsFirstTranche | no package | none |
| A3 | low | zero airdrop admin locks unclaimed | latent | test_bug_A3_airdrop_zeroAdminLocksUnclaimedForever | no package | none |
| V1 | low | vault admin zero bricks allocation | latent | test_bug_V1_vault_zeroAdminBricksClaims | no package | none |
| LL1 | low | auto forward on native eth pool reverts every afterSwap | latent (not allowlisted on current hook) | test_bug_LL1_autoForward_nativeEthPoolRevertsEverySwap | no package | none |
| LL2 | low | trader can starve the pool extension of gas | live on LAYER | trace only | no package | none |
| AB1 | low | auto burn runs in untrusted swaps, keeper reward always fails | latent | trace only | b6 for the router side: p1 | none |
| D1 | low | dev buy minimums caller chosen, hop on public pool | latent | reading | no package | private mempool for launches |
| R2, R4, D2, V2, A4, LL3, F1, AB2 | info | utf8 truncation, mime splice, dev buy ordering, vault event, merkle duplicate leaves, seed bypass, rounding dust, reads outside try | mixed | R2: test_bug_R2_dynamicBlockRenderer_truncationSplitsUtf8. R4: test_bug_R4_onchainRenderer_mimeTypeInjectsScript. rest reading | R2: b8 r1 in progress. others no package | freeze LAYER scripty content once final (R4) |

### 3.5 scripts and ops (scripts-and-keepers.md part a, harness.md)

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| S-01 | high | wiring script hardcodes open factory 0xf051, hook 0xAAd6, escrow 0xDD1b, and renounces locker ownership | passes only on the wrong factory | reading (DeployConversionLockerAndWire.s.sol:58-61,:129) | s1 planned | RB-07 |
| S-02 | high | readme tells operators to run Deploy.s.sol, which deploys the legacy stack | docs | reading | s1 and docs planned | RB-07 |
| S-03 | high | DeployNativeEthStack opens factory to the public by default | live: 0xf051 matches | reading, FT-02 fork proof | s1 planned (default deprecated true) | RB-04 |
| S-04 | high | no script launches on the current skim stack | none | reading, not run on chain | s1 planned | RB-07 |
| S-05 | medium | LAYER one shot scripts, preflight only warns | LAYER | reading | s1 planned (move to legacy) | RB-07 |
| S-06 | medium | DeployV1Stack post flight does not assert hook is an escrow depositor | deploy time | reading | s1 planned (d7 wiring tests) | none |
| S-07 | medium | DeployV1Stack leaves ownership on the raw deployer key. live 0x4959 differs (fee 0.069, team = owner) | 0x4959 | reading, HR-3 | s1 planned. D20 Ownable2Step | none |
| S-08 | medium | no chain id guard in most deploy scripts | deploy time | reading | s1 planned | RB-07 |
| S-09 | medium | 32 scripts read `PRIVATE_KEY` from env | operator | grep | s1 planned | use keystore, not env |
| S-10 | medium | verify-stack.sh stale and exits 0 on failure | ci | reading | s1 planned (verify-v2.sh, d7) | RB-12 |
| S-11 | medium | sync-addresses.mjs writes legacy addresses into `.env` | operator | reading | registry wiring in progress | RB-12 |
| S-12 | medium | SetUpLayerAutoForward stale backfill, Live*Verify do real swaps | operator | reading | s1 planned | RB-07 |
| S-13 | medium | PC controller doc says 80/20, constant is 8667/1333 | docs | reading | s1 planned | none |
| S-14 to S-21 | low | RedeployBurnRouter rewires team recipient, dead RedeployHook, test launches at fixed tick, tick tool no native mode, puppeteer on chain html, allowlist builder, argv rpc urls, no dry run guard | operator | reading | s1 and u1 planned | RB-07 |
| HR-3 | info | live deployFee 0.069 eth vs DeployV1Stack setting 0 | 0x4959 | cast, harness parity table | s1 | RB-12 |
| HR-1 | high | (same as H1, found by harness) bounty recipient brick | see H1 | test_knownIssue_* (Harness.t.sol) | see H1 | RB-05 |

### 3.6 website (ui.md)

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| UI-01 | high | mainnet addresses zero, eth can go to 0x0 | no hosted ui found | reading (config.ts:28-45, ReviewAndDeploy.tsx:234) | u1 planned | RB-08 |
| UI-02 | high | unknown chain falls back to sepolia addresses | same | reading | u1 planned | RB-08 |
| UI-03 | high | stale `deployToken` abi, selector 0xdf40224a vs live 0x3f1638ea | all live factories | cast code grep | u1 planned | RB-08 |
| UI-04 | high | deploy fee never read or sent (0.069 eth on 0x4959) | 0x4959 | reading, cast | u1 planned | RB-08 |
| UI-05 | high | reward bps sum 10000, factory adds protocol slot, deploy reverts `ProjectSideBpsMismatch` | 0x4959 | reading, cast | u1 planned | RB-08 |
| UI-06 | high | sell always reverts (`TAKE_ALL` then `UNWRAP_WETH`) | any pool | reading of universal router source | u1 planned | RB-08 |
| UI-07 | high | old "newMaterial" hook abi, wrong swap direction | hook 0x636c | cast (selector absent) | u1 planned | RB-08 |
| UI-08 | high | swap widget supports weth pools only, live pools are native | 111 | reading, cast | u1 planned | RB-08 |
| UI-09 | medium | no `deprecated()` gating or simulation | 0x4959 deprecated | reading | u1 planned | RB-08 |
| UI-10 | medium | "Verified" badge is self asserted by the deployer | all | reading | u1 planned | RB-08 |
| UI-11 | medium | hostile metadata and images rendered unfiltered | all | reading | u1 planned | RB-08 |
| UI-12 | medium | token list scans from block 0 and sees one factory | all | reading | u1 planned (registry deploy blocks exist) | RB-08 |
| UI-13 | medium | dev buy encoding wrong, no min out | legacy extension | reading | u1 planned | RB-08 |
| UI-14 | medium | quote handling weak, zero min out possible | all | reading | u1 planned | RB-08 |
| UI-15 | medium | mev defaults conflict with contracts (4140s vs 900s cap) | legacy modules | reading | u1 planned | RB-08 |
| UI-16 | medium | pool data only fits the static fee hook | skim hook | cast abi decode | u1 planned | RB-08 |
| UI-17 | medium | referral injection silent and sticky | n/a | reading | u1 planned | RB-08 |
| UI-18 to UI-25 | low, info | supply chain (72 advisories, 18 high), keys in bundle, allowance scope, link hardening, image upload, tx state, referrals page decode, stale branding and no escrow ui | n/a | build and `npm audit` runs, reading | u1 planned | RB-08 |

### 3.7 keepers and automation (scripts-and-keepers.md part b, keeper-111.md)

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| K-01 | high | 111 swapper strands eth (same as LF-02) | 111 | KeeperV1_111.fork.t.sol test_bug_swapperV1_thirdPartyClaim_strandsEth | see LF-02 | RB-02 |
| K-02 | medium | bare try catch around convert silently skips under estimateGas | keeper design | reproduced on fork (review), KeeperV1_111.fork.t.sol test_keeperV1_lowGas_neverSilentlySkips | fixed: k1 part 1 done (explicit gas floors, revert on shortfall) | none needed |
| K-03 | medium | draft keeper preview read only currency0 fee growth | keeper design | review | fixed: k1 part 1 done (preview sums both currencies) | none needed |
| K-04 | medium | keeper economics do not close (breakeven ~0.23 eth output, pending 0.00065 eth) | 111 | live reads | decision needed: owner funds gas or raises reward in v2 | RB-01 |
| K-05 | medium | single keeper dependency, anonymous eoa 0x71cA with 0.0135 eth | 111 | tx history | decision needed: owner runs second path | RB-01 |
| K-06 | low | convert pacing grief with dust | 111 | reading | p1 in progress | none |
| K-07 | low | convert with minOut 0 leans on contract floors | 111 (0x71cA sends 0) | reading | k1 script quotes minOut | RB-01 |
| K-08 | low | autoburn collect pays keeper reward to the extension | latent | reading | none | keep `keeperRewardBps` 0 |
| K-09 | low | bounty leg reverts swap if 0x8C72 cannot take eth | 111 | see H2 | h1 in progress | none |
| K-10 | low | actions tag pinned, ssh host key trust on first use | ci | reading | ci fixes planned | none |
| K-11 | low | ui bundles alchemy key, referrals page calls dead function | ui | reading | u1 planned | none |
| gap | n/a | no keeper code existed in the repo before this session. LAYER `processBurnWeth`, controller dust and liveness monitoring still have no runner | LAYER | none | generic ArtCoinsKeeperV2 (d8): k1 part 2 planned | manual |

### 3.8 ci and repo hygiene (repo-hygiene.md). HYn is hygiene Hn

| id | sev | title | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| HY1 | high | mirror pushes any tag, any private commit can go public | mirror.yml | reading | ci fixes planned | RB-09 |
| HY2 | high | merge of v2 publishes review docs and proof tests for live bugs | on merge | reading | ci fixes planned (curate merge) | RB-09 |
| HY3 | high | origin is the public repo and carries wip branches | now | `git ls-remote` both urls identical | decision needed (owner, D26) | RB-09 |
| HY4 | high | broadcast folder has no record of the current stack | provenance | grep | fixed: registry done (deployments/mainnet.json, verifier, ci). wiring in progress | RB-12 |
| HY5 | high | ~140 fork tests pass vacuously (return, not skip) | ci | grep, count from files | ci fixes planned | none |
| HY6 | high | harness forks live mainnet by default in ci | ci | reading | ci fixes planned (`SKIP_FORK_TESTS`) | none |
| HY7 | medium | foundry.lock disagrees with gitlinks for 5 of 8 libs | build | `git submodule status` | ci fixes planned. do not `forge update` | none |
| HY8 | medium | `.env.example` holds a 66 char placeholder private key | scanners | grep, history scan | ci fixes planned | none |
| HY9 | medium | ci profile is not what the readme tells users to run | ci | reading | ci fixes planned. d7 size gate (h1) | none |
| HY10 | medium | fmt pinned to 1.5.0, dev toolchain 1.7.1, 2 files fail at 1.7.1 | ci | run at 1.7.1 | ci fixes planned | none |
| HY11 | medium | actions tag pinned, no timeout, no concurrency | ci | reading | ci fixes planned | none |
| HY12 | medium | mirror repo guard is a hard coded name | mirror | reading | ci fixes planned | none |
| HY13 | medium | readme deploy example is the legacy stack | docs | reading | docs planned | RB-07 |
| HY14, HY15 | medium | script-js no lockfile, ui has no ci, 11 high advisories in prod deps | supply chain | `npm audit` | ci fixes planned | none |
| HY16 to HY25 | low, info | unused submodule, oz pin off tag, scratch artifacts, broadcast size, personal paths, model trailers on side branches, gitignore oddities, bytecode equality check missing, mirror verified fast forward only, no mirror drift | n/a | reading | ci fixes and cleanup planned | none |

### 3.9 docs vs code (repo-hygiene.md table and other reviews)

| id | sev | claim | where | reality | v2 status |
|---|---|---|---|---|---|
| DC-1 | medium | "20% of the protocol slice" | README | it is 20% of lp rewards (locker slot). skim hook protocol slice is a different thing | docs planned |
| DC-2 | low | up to 7 reward recipients | README | 6 project recipients once the protocol slot is appended (by reading) | docs planned |
| DC-3 | medium | "construction time config fixed for life" | README | admin can change admin, image, metadata, renderer, tax rate | t1 and docs (FT-05) |
| DC-4 | medium | tax "single deployment" convention | README | not enforced, any deployer can enable on a non deprecated factory | f1 (FT-07) |
| DC-5 | low | ethereum mainnet only | README | no chain guard in factory or hook | docs planned |
| DC-6 | medium | "factory deployed 2026-05-18, see README addresses" | AGENTS.md | no such deploy date, README has no address table | registry wiring in progress |
| DC-7 | low | bump recipe, hardcoded `/Users/dd` paths | AGENTS.md | stale once v2 merges | docs planned |
| DC-8 | high | "wip branches stay private" | AGENTS.md, mirror.yml | origin carries four wip branches (HY3) | decision needed |
| DC-9 | medium | readme deploy command | README:86 | deploys legacy stack (S-02) | docs planned |
| DC-10 | low | stale contract names in `.env.example` | .env.example | pre rename names | docs planned |
| DC-11 | low | hook "~24,547 bytes, 29 bytes headroom" | foundry.toml | 20,558 bytes at ci profile, 4,018 headroom. 24,578 at default profile (over limit) | h1 corrects (D14) |
| DC-12 | medium | `IPreSwapStream` natspec: a non implementing recipient can never brick a swap | interface | false (H1, HR-1) | h1 in progress |
| DC-13 | low | static fee interface docs buy and sell | IArtCoinsHookStaticFee | inverse (H10) | dropped (D14) |
| DC-14 | medium | burn router clamp "uneconomic by construction" | BurnRouter | loops in one tx (LF-03) | p1 in progress |
| DC-15 | low | PC controller 80/20 and "reuses the LAYER router" | DeployPCController | 8667/1333 and live router is 0x0EB2 | s1 planned |
| DC-16 | medium | ui: "all LP rewards go to your wallet", "Verified" | ui | protocol takes 20%. self asserted badge (UI-05, UI-10) | u1 planned |

### 3.10 deployment registry (registry-notes.md, job 1)

| id | sev | finding | live exposure | proof | v2 status | mitigation |
|---|---|---|---|---|---|---|
| RG-01 | high | current stack (0x4959, 0x636c, 0x866e, 0x7559, 0xb038, 111) has no broadcast record | provenance | grep of broadcast/ | fixed: registry and verifier done, ci workflow added. wiring into readme, ui, scripts in progress | RB-12 |
| RG-02 | medium | broadcast has 20 fork only mainnet creates and 44 txs not on chain, indistinguishable from real | misleading | tx lookup, 133 hashes vs 89 on chain | registry marks them. folder cleanup planned | RB-12 |
| RG-03 | medium | source provenance: `commit` fields do not exist in history. 0x4959 stack matches head only under the `ci` profile, with ipfs metadata in the chain code (deploy used a different config than head) | all current contracts | verifier: 56 contracts, 2 coins, 0 drift | d7 `verify-v2.sh` planned (s1) | RB-12 |
| RG-04 | medium | live bytecode differs from head for 0xf051 (version "3"), swapper 0xeBD9, legacy hook, legacy mev modules, LAYER token and renderers | 0xf051, 0xeBD9, legacy | verifier `bytecodeMatch: mismatch` rows | none (legacy). findings on the swapper were also run on live bytecode | none |
| RG-05 | low | six permanent collection contracts and scripty chunks unverified here, `etherscanVerified` unknown | 111 admin, renderer, adapters | registry notes | none | none |
| RG-06 | medium | wrong or zero addresses across repo: ui config, DeployConversionLockerAndWire, sync-addresses, AGENTS.md, DeployPCController comment | scripts and ui | address inventory table | registry wiring in progress | RB-12 |
| RG-07 | info | `version()` returns "1" on both 0x4959 and 0xd159, so it cannot tell stacks apart. 0xf051 reports "3" | integrators | cast | d6 version tag per pool (h1, t1, f1) | registry |
| RG-08 | info | StateView and quoter addresses not recorded anywhere in repo | ui | cast (both have code, point at the pool manager) | u1 | none |
| RG-09 | info | PC controller 0xd8C6 burn router is 0x0EB2, not LAYER's 0x2edb | docs | cast | none | none |

## 4. proofs for medium and above

run prefix for every command: `/tmp/claude-0/forge.sh test --skip "test/v2/harness/**" --skip script -vv --match-path`. the skips only dodge other agents' files that did not compile at the time. fork tests skip when the rpc is down or `SKIP_FORK_TESTS=true`. pass here means the bad outcome was observed.

| id | setup | action | observed | test and file | command (match path) |
|---|---|---|---|---|---|
| LF-01 | fork, live locker 0x866e and position manager, coin 111 with pending lp fees. local: fresh v4 stack | attacker opens its own unlock, calls `collectRewardsWithoutUnlock`, then settles its own position against the shared credit | attacker takes the full uncollected credit (both currencies). live pending at block 26130325: 13,404 coin, 0 eth | test_bug_LF01_fork_live_111_uncollected_fees_stealable (LiveForkReview.t.sol), test_bug_LF01_collectRewardsWithoutUnlock_lets_anyone_steal_all_lp_fees (LpLockerReview.t.sol) | `"test/v2/review/locker-fees/**"` |
| H14, FT-01 | local pool, or fork of coin 111 with its real 15% tax | one unlock: add then remove canonical liquidity (net ~0 PCT), buy on a side v4 pool, take | local: 0.847 vs 0.996 received, burn sink 0. live: 1.185M vs 1.395M. FT-01 fork: side buy of 183,185 coin pays 27,477 tax, after add+remove pays none, hook attests 7,819,294, router spends at most 2 wei | test_bug_H14_addRemoveCanonicalLiquidityMintsTaxBudget (TaxBudget.t.sol), test_bug_H14_live_addRemoveBudgetBypassesTax (LiveStack.t.sol), test_bug_FT01_live111_addRemoveCanonicalSkipsSidePoolTax | `"test/v2/review/hooks-mev/**"` and `"test/v2/review/factory-token/**"` |
| LF-02, K-01 | fork, live 111 swapper, 1 eth deposited to its escrow slot as the allowlisted locker | stranger calls `escrow.claim(swapper, 0)`, then anyone calls `flushPaired` | swapper balance 1 eth, `flushPaired` reverts `NothingToFlush` (0xeb694a3c), no function moves the eth. a keeper run does not remove the stranded eth | test_bug_LF02_fork_live_111_swapper_eth_strandable, test_bug_swapperV1_thirdPartyClaim_strandsEth (KeeperV1_111.fork.t.sol) | `"test/v2/review/locker-fees/**"`, `test/v2/KeeperV1_111.fork.t.sol` |
| LF-03, LF-04 | local: 20 weth balance. fork: src BurnRouter deployed on the live LAYER pool | one tx loops `processBurnWeth`, burner moves price between calls | local: 31 calls, 14% sqrt price move, ~29% of balance lost. fork: 19 calls, 9.7% move. keeper took 890 bps of burned on a thin pool (0.10 eth on 1.9 weth) | test_bug_LF03_impact_clamp_loops_in_one_tx_and_sandwich_profits, test_bug_LF03_fork_src_burnrouter_loop_on_live_layer_pool, test_bug_LF04_keeper_reward_on_whole_balance_farmed_by_loop | `"test/v2/review/locker-fees/**"` |
| LF-09 | fork, live routers 0x2edb and 0xE600 | one `processBurnWeth(0)` | 0.503 weth consumed in one call, floors at 30.8% and 63.9% of spot. rehearsal suite also fails `test_rehearsal_s06_highSuccess_burnCadence` (`InsufficientLayerOut(1.043e24, 1.331e24)`), 10 of 11 pass | test_LF09_fork_live_burnrouter_full_balance_owner_floor | `"test/v2/review/locker-fees/**"` |
| H1 | local, bounty recipient is an eoa, then a contract with empty fallback, balance over 0.01 eth | swap on the skim pool | every buy and sell reverts `WrappedError(hook, beforeSwap, ...)`. control: a contract with no fallback reverts inside the call and is caught | test_bug_H1_eoaBountyRecipientSelfBricksPool, test_bug_H1_emptyFallbackRecipientBricksForever, test_control_H1_noSelectorRecipientIsCaught (SkimDelivery.t.sol), harness test_knownIssue_* | `"test/v2/review/hooks-mev/**"` |
| H2, H3 | local, recipient rejects eth, or referralPayout has no code | swap, or swap naming a referrer | swap reverts every time (H2), referred swaps revert (H3, "call to non-contract address") | test_bug_H2_rejectingBountyRecipientBricksAllSwaps, test_bug_H3_codelessReferralPayoutRevertsReferredSwaps | `"test/v2/review/hooks-mev/**"` |
| H4, H5, H7 | local, and fork of 111 | exact in buy with a price limit, exact out sell with a limit, sniper extra on partial fill | local: 10 eth specified, 0.505 filled, 0.5 eth skim (49.7% vs 5%). live: 50 eth exact in, 0.0028 eth filled, 3 eth skim. H5: seller sold 0.25 and also paid 0.276 eth. H7: 4.9 eth extra on under 1 eth fill | test_bug_H4_*, test_bug_H4_live_priceLimitedBuyOvercharges, test_bug_H5_*, test_bug_H7_* | `"test/v2/review/hooks-mev/**"` |
| H6 | local static hook, sniper extra 490,000 ppm | same tokens via exact in and exact out | 1.000 eth vs 0.760 eth | test_bug_H6_sniperExtraExactOutputDiscount | `"test/v2/review/hooks-mev/**"` |
| H11, H13 | local and fork of live hook 0x636c | open a pool for coin 111 with own recipients. name self as referrer | 1 eth buy pays attacker over 0.89 eth. self referral takes 0.0025 eth per 1 eth (protocol leg 0.025 to 0.015 at 1% cap) | test_bug_H11_*, test_bug_H11_live_openPoolForCoin111, test_bug_H13_*, test_bug_H13_live_selfReferralRebate | `"test/v2/review/hooks-mev/**"` |
| FT-02, FT-03 | local, and fork of open factory 0xf051 | copy a victim's tokenConfig from a different sender with attacker rewards. call the protocol bps override with 0 | token lands at the predicted address with attacker config, victim launch reverts on collision. locker records one 10000 bps slot for the attacker | test_bug_FT02_launchHijackSameAddressDifferentConfig, test_bug_FT02_FT03_liveOpenFactoryHijackAndZeroProtocol, test_bug_FT03_publicCallerZeroesProtocolSlot | `"test/v2/review/factory-token/**"` |
| FT-05, FT-07 | local | token admin changes image, metadata, tax rate. public deployer sets sink and exempt list to self | both succeed | test_bug_FT05_tokenAdminMutatesMoreThanRenderer, test_bug_FT07_publicDeployerRoutesTaxToSelfAndExemptsSelf | `"test/v2/review/factory-token/**"` |
| G1 | fork, coin 111 | `contractURI()` at 50M, 100M, 200M gas caps | 179,363,374 gas, 314,817 bytes. 50M and 100M revert, 200M returns 310KB | test_measure_G4_liveLayerAnd111 (ForkRenderersReview.t.sol) | `"test/v2/review/extensions-renderers/**"` |
| A2 | local, test contract plays factory | admin waits a day, front runs first claim with `updateMerkleRoot` | admin claims the whole supply, first claimer's proof fails | test_bug_A2_airdrop_adminSwapsRootAndTakesEverything | `"test/v2/review/extensions-renderers/**"` |
| K-02 | reproduced on fork before the keeper was written. LF-07 was not quantified, so it has no proof | K-02: run helper at gas limits from 1.3M down to 0.3M | 8 succeed (all convert), 33 revert, none succeed with convert skipped | test_keeperV1_lowGas_neverSilentlySkips (7 tests in file, 7 of 7 pass at 26130269) | `test/v2/KeeperV1_111.fork.t.sol` |
| UI-01 to UI-17, S-01 to S-14, HY1 to HY15 | read only | `cast`, grep, `npm ci`, `npm run build`, eslint, `git ls-remote`, selector checks against live bytecode | no test file. ui build fails at `tsc -b` (5 errors). live selector 0x3f1638ea vs ui 0xdf40224a. origin refs identical to the public repo. sell revert proven from universal router source, not the deployed bytecode | trace, reading | none |

## 5. claims from the prior pass that hold

| claim | holds because | source |
|---|---|---|
| tax exemption can be minted by add then remove | confirmed and extended (FT-01, H14), live on 111 | factory-token, hooks |
| create2 salt ignores sender and pool config | confirmed (FT-02, live on 0xf051). ctor args (name, symbol, image, metadata, context, renderer, supply, taxConfig) ARE bound | factory-token |
| deploy fee exact match, extension eth isolated | `msg.value == fee + sum(msgValue)`, `test_holds_deployFeeExactAndExtensionEthIsolated` | factory-token |
| deprecated gate, owner and admins bypass | `test_holds_deprecatedGate` | factory-token |
| deploy entries are `nonReentrant`, allowance reset to 0 after each extension | read | factory-token, extensions |
| protocol bps cap 3000, tax cap 2000 bps compile time | read, enforced on setters and overrides (but see FT-03 floor) | factory-token |
| default token json escapes name, symbol, description, image | `test_holds_contractUriEscapesJson`, `test_holds_jsonEscapingRoundTripsHostileName` (all 5 renderers) | factory-token, extensions |
| escrow: reentrancy safe, state zeroed before transfer, only depositors credit, no eth rescue | read | factory-token |
| fee split has no dust (`b + p + r == totalSkim`) | read, baseline clamped | hooks |
| bounty leg cannot be reduced by a referral | referral capped at protocol share | hooks |
| malformed hookData cannot revert a swap | tolerant decode | hooks |
| no division by zero, int128 bounds, delta signs checked | read | hooks |
| mev module cannot be replaced after launch. a fee module can revert swaps for at most 15 min | `mevModule[id]` written once, `mevModuleOperational` | hooks |
| hook entry points gated (PoolManager, factory, self) | BaseHook and `onlyFactory` | hooks |
| open pools never earn tax budget | `locker != 0` gate plus token pool id check | hooks |
| decay starts at launch, same tx | factory `:246-264` | hooks |
| owner cannot pull lp nfts | `test_holds_LF06_owner_cannot_withdraw_position_nft` | locker-fees |
| recipient bps sum to 10000, at most 7 slots, no dust, reverting recipient cannot block collect | read | locker-fees |
| swapper cannot be looped within a block (50 block pacing) | `FeeAutoSwapper.sol:330-331,363` | locker-fees, keepers |
| swapper artcoin side not strandable | `test_holds_LF02_artcoin_side_push_is_not_stranded` | locker-fees |
| controller split immutable and sums to 100% | read | locker-fees |
| src renderers other than LL are cheap (Default 22K, DynamicBlock 420K, Example 190K gas realistic). the prior "block gas limit" claim is refuted for them | `test_measure_G1_*`, `test_measure_G3_*` | extensions |
| `receiveTokens` is factory only. airdrop leaf double hashed. vault vesting monotone, min 7 day cliff and 90 day linear | `test_holds_receiveTokensOnlyFactory`, `testFuzz_holds_vaultVestingMonotoneAndComplete` | extensions |
| dev buy cannot be piggybacked | pool created in the same tx | extensions |
| skim hook is native eth only. static hook supports eth and erc20 | `SkimFeeInitLib.sol:62-67` | hooks |
| ui attribution hookData encoding, tick rules, fee units, supply units are correct | round trip decoded with cast | ui |
| mirror workflow is fast forward only, no force, scoped token, key via env | read | repo-hygiene |
| 0x4959 stack equals head source under the `ci` profile. 56 contracts, 2 coins, 0 drift on chain | `script-js/verify-registry.mjs` run | registry |
| 0xf051 has zero coins and no pool. two coins exist in total (LAYER, 111) | `TokenCreated` logs from deploy block to head | registry |
| fresh stack from `DeployV1Stack` matches live wiring, launch and fee flows work | harness 8 of 8, skim fork suite 13 of 13 | harness |
| no secrets in history, no private key shapes, no keyed rpc urls. one placeholder key in `.env.example` | scan of 17 commits | repo-hygiene |
| supply bounds: min 1 token, no silent overflow | `MIN_TOKEN_SUPPLY = 1e18`, checked math or the locker int128 cast reverts | factory-token |

## 6. could not reach or verify (merged, deduplicated)

| area | item | why |
|---|---|---|
| general | prior audit text and attachments | not in the container |
| general | etherscan data, verified source flags | api needs a key. blockscout used for creators |
| general | identity and source of 0x71cA, 0xA358, 0x8C72, 0xed3e, 0xb03c, 0xf5c3 (111 tax sink), admin 0xA96a, renderer 0x7604 and 0x9438 | unverified source. behaviour inferred from calls |
| general | whether bounty recipient 0x8C72 or admin 0xA96a are upgradeable, and the practical powers of 0xA96a (`setTaxBps`, referral cap) | source not read |
| general | how 0x4959, 0x866e, 0x7559, 0x636c were deployed, and with which source commit | no broadcast, commits not in history |
| general | whether the 2026-06-06 broadcast exists elsewhere | not in repo |
| hooks | legacy hooks and the live LAYER pool | out of scope |
| hooks | which pool extensions are enabled live (H12 impact) | not enumerated |
| hooks | aggregator behaviour with price limits (real world frequency of H4) | no data |
| factory | bytecode of 0xf051 vs any repo commit | registry says version "3", not head |
| factory | 111's full exempt list | not enumerable on chain |
| locker | whether 500 bps on the 111 swapper is below the 111 round trip fee | not measured |
| locker | source of burn router 0xE600 | not in repo |
| locker | whether the src BurnRouter and controller are deployed by permanent collection | unknown |
| locker | exposure size of LF-01 on LAYER's locker | hook collects each swap |
| locker | how 111's eth side lp fees accrue | 0 pending at the fork block |
| extensions | dev buy end to end on a live launch (D1, D2) | harness did not compile at the time. reading only |
| extensions | LL2 and AB1 profitability | need hook stack and live LAYER pool. reasoning only |
| extensions | per provider eth_call gas caps | only geth default 50M and the block limit used |
| extensions | `SetExtension` event history | `cast logs` returned nothing, maybe rpc truncation |
| extensions | permanent collection renderer source | outside this repo |
| scripts | that launch scripts revert on 0x636c | analysis of `SkimFeeInitLib`, no fork run (needs owner signer) |
| scripts | full `forge build` of the whole project | blocked by sandbox shim and lock. scripts type checked per file |
| scripts | uncollected fee value over history, gas price economics over time | one snapshot |
| scripts | LAYER stack end to end | balances and slots read only |
| ui | browser and wallet behaviour (chain switch, gas estimate warnings, irys signature, react `javascript:` blocking) | no browser |
| ui | sell revert on the deployed router bytecode | proven from source |
| ui | alchemy `getLogs` limits, irys terms, which advisories are reachable, any hosted copy and its headers | not queried |
| ui | sepolia addresses | no sepolia rpc used |
| ui | vault, airdrop, dev buy, other mev modules enabled on 0x4959 | not read |
| ci | github secrets, branch protection, who can push tags, actions logs, public repo settings | github api denied |
| ci | whether `origin` is the public repo or an alias | private repo unreachable |
| ci | that ci passes on a fresh clone, and fmt result at forge 1.5.0 | not installed or run |
| ci | `npm audit` reachability in a client only app, OZ `Bytes.sol` transitive use | not traced |
| ci | counts in HY5 (about 140) | from grep over files, not a run |
| registry | whether source text only differing in comments could be hidden by metadata hash masking | cannot exclude |

## 7. what an external auditor should look at first

this is not a formal audit and nobody here has the independence of one. the list is where this team would spend the first week.

| rank | area | why |
|---|---|---|
| 1 | v2 hook swap path and transient accounting (`ArtCoinsHookV2`, b1, b2, b3, d1) | one contract sits on every swap. transient skim accrual, the refund of unfilled skim, flow grants, and the 1,024 byte size headroom are new and interact. a mistake here freezes or mis prices every pool. h1 is not written yet |
| 2 | hard transfer mode on the token (d2 HARD, D24) | the token reverts transfers touching the PoolManager or a venue unless the hook granted a same tx allowance. wrong accounting bricks the coin or lets exits through. accepted residual: erc6909 claims on side pools. router settle ordering must hold for every router in use |
| 3 | locker collect path against the LF-01 class (`ArtCoinsLpLockerV2`) | live critical came from shared position manager deltas. the v2 collect must open its own unlock and take exact amounts. check every path that touches position manager credit |
| 4 | FeeDelivery fallback and escrow (`FeeDelivery`, `ArtCoinsFeeEscrowV2`, d1, D23) | gas capped push with escrow on failure is the only external dependency allowed to revert a swap. escrow must stay immutable, non pausable, and accept the core depositors forever. check return bombs, gas burners, reentry through `claim`, and `selfClaimOnly` |
| 5 | factory launch flow and value accounting (`ArtCoinsFactoryV2`, b4, d3, d4, d5, section 6) | salt binds sender and full config hash. deploy fee plus extension eth accounting, protocol slot injection, constants hash checks, tax sink limits, launch event completeness |
| 6 | burn router pacing (`BurnRouterV2`, b6) | per block pacing, reserved reward, impact bound, refund claims. the live and src routers failed here. check the open tab entry and any extension that can trigger it |
| 7 | live 111 tax budget exposure (H14, FT-01, FT-05) | the live token and hook are immutable. the exposure is the 15% buy tax on side venues, plus admin rate changes inside the 20% cap. auditors should size it and say whether the owner or token admin response is enough |
| 8 | live 111 collect and flush (LF-01, LF-02, `CollectFlushKeeperV1`) | the keeper narrows but does not close the window. verify it holds nothing, forwards rewards, and cannot be griefed into losing funds |
| 9 | tooling around launch (ui encoders, scripts, mirror and ci gates) | the only tested launch path is the harness. an auditor should replay a full launch from the final scripts on a fork |

statement: this document is an engineering review with proof tests, written by the team that wrote v2 and by automated agents. it does not replace a formal audit, and v2 has not had one.

## 8. test totals (director fills at the end)

pin: `FORK_BLOCK` 26130269. prefix for each command: `/tmp/claude-0/forge.sh test`. fork groups skip without an rpc, so record skipped separately.

| group | command | total | pass | fail | skip |
|---|---|---|---|---|---|
| harness proof suite | `--match-path "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv` | tbd | tbd | tbd | tbd |
| review proofs: hooks and mev | `--match-path "test/v2/review/hooks-mev/**" --skip "test/v2/harness/**" --skip script -vv` | tbd | tbd | tbd | tbd |
| review proofs: factory and token | `--match-path "test/v2/review/factory-token/**" --skip "test/v2/harness/**" --skip script -vv` | tbd | tbd | tbd | tbd |
| review proofs: locker and fees | `--match-path "test/v2/review/locker-fees/**" --skip "test/v2/harness/**" --skip script -vv` | tbd | tbd | tbd | tbd |
| review proofs: extensions and renderers | `--match-path "test/v2/review/extensions-renderers/**" --skip "test/v2/harness/**" --skip script -vv` | tbd | tbd | tbd | tbd |
| v2 constants and interfaces | `--match-path test/v2/ConstantsV2.t.sol -vv` | tbd | tbd | tbd | tbd |
| v2 escrow | `--match-path test/v2/EscrowV2.t.sol -vv` | tbd | tbd | tbd | tbd |
| v2 fee delivery | `--match-path test/v2/FeeDelivery.t.sol -vv` | tbd | tbd | tbd | tbd |
| v2 mev linear skim | `--match-path test/v2/MevLinearSkimV2.t.sol -vv` | tbd | tbd | tbd | tbd |
| v2 renderers | `--match-path test/v2/RendererV2.t.sol -vv` | tbd | tbd | tbd | tbd |
| v2 keeper for 111 (fork) | `--match-path test/v2/KeeperV1_111.fork.t.sol -vv` | tbd | tbd | tbd | tbd |
| v2 token (t1) | `--match-path "test/v2/TokenV2*.fork.t.sol" -vv` | tbd | tbd | tbd | tbd |
| v2 hook (h1) | `--match-path "test/v2/HookV2*.fork.t.sol" -vv` | tbd | tbd | tbd | tbd |
| v2 locker and escrow fork (l1) | `--match-path "test/v2/LockerV2*.fork.t.sol" -vv` | tbd | tbd | tbd | tbd |
| v2 periphery (p1) | `--match-path "test/v2/*Swapper*" --match-path "test/v2/*BurnRouter*" -vv` | tbd | tbd | tbd | tbd |
| v2 factory (f1) | `--match-path "test/v2/FactoryV2*.fork.t.sol" -vv` | tbd | tbd | tbd | tbd |
| v2 deploy and integration (s1, i1) | `--match-path "test/v2/DeployV2Stack.fork.t.sol" -vv` and `test/v2/IntegrationV2.fork.t.sol` | tbd | tbd | tbd | tbd |
| v1 skim hook fork suite | `--fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000 --match-path test/ArtCoinsHookSkimFeeForkTest.t.sol -vv` (review run: 13 of 13) | tbd | tbd | tbd | tbd |
| v1 launch rehearsal fork suite | same flags, `--match-path test/MainnetLaunchRehearsalForkTest.t.sol` (review run: 10 of 11, burn cadence floor) | tbd | tbd | tbd | tbd |
| v1 ci set | `FOUNDRY_PROFILE=ci forge test` as ci runs it, with `SKIP_FORK_TESTS=true` | tbd | tbd | tbd | tbd |
| size gate | `FOUNDRY_PROFILE=ci /tmp/claude-0/forge.sh build --sizes --skip test --skip script` (hook headroom at least 1,024 bytes) | tbd | tbd | tbd | tbd |
| registry verify | `node script-js/verify-registry.mjs` (review run: 56 contracts, 2 coins, 0 drift) | tbd | tbd | tbd | tbd |
| ui build, lint | `npm ci --ignore-scripts && npx tsc -b && npx eslint .` in `ui/` (review run: tsc fails, 5 errors) | tbd | tbd | tbd | tbd |
