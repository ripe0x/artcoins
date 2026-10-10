# artcoins system review (final state of branch v2)

status: final state of the `v2` branch per STATUS.md and DECISIONS.md D6 to D59. section 8 numbers are filled by the director. this is NOT a formal audit.

## 1. scope and method

| item | statement |
|---|---|
| what this is | a structured engineering review with proof tests. it is not a formal audit, not a security certification, and no firm signed off. nothing here says the system is safe. v2 is unaudited and nothing from v2 is deployed. |
| contracts, first pass | the v1 contracts and the live stack were reviewed with proof tests (section 4). every medium or higher contract finding has a passing proof test that asserts the bad outcome (`test_bug_*`) or a trace. controls and holds are pinned as `test_holds_*` and `test_control_*`. |
| contracts, v2 second pass | four independent reviews of the finished v2 packages (section 9). the reviewers did not write the code. fixes landed afterwards from the package authors and were not re reviewed by a second person. |
| scripts, ui, keepers, ci, docs, registry | first pass review (read the code, ran builds and `cast` reads, no second reviewer), then fixed by packages u1 (ui), s1 (deploy scripts), k1 (keepers), the hygiene change and the registry and address wiring jobs. ui behaviour in a browser and wallet was never run. |
| fork tests | pinned block 26130269 (harness constant `FORK_BLOCK`) against live contracts. several area suites forked at nearby blocks (26130300 to 26130400) before the pin; numbers are quoted as the reviews report them. |
| prior audit | the prior audit's attachments (audit text, full archive, credits engine bundle) were not available. its claims were taken from the brief and re checked from code, see section 5. |
| chain reads | tenderly public gateway, read only, 2026-10-06. no broadcasts, no keys. etherscan was not usable (no key), blockscout was used for creator data. |
| owner model | one eoa owns nearly everything (0xCB43078C32423F5348Cab5885911C3B5faE217F9). no multisig, no timelock (D20). every "owner can" below means that one key. |
| ids | kept from each review. hooks review ids H1 to H14 collide with repo hygiene ids H1 to H25, so hygiene ids appear here as HY1 to HY25 (HYn = hygiene Hn). extensions finding F1 is a finding, package f1 is the factory package. registry and docs rows were numbered here (RG, DC). harness findings are HR. v2 second pass ids are V2A, V2B, V2H, V2F. |
| status vocabulary | every finding row starts its status cell with one of five words (compound rows list one per id). `fixed`: code or script changed on this branch, the row names the package and the regression test or decision. `mitigated`: an owner action in the runbook narrows it, the row names the action. `accepted`: a decision id (or a package note where no id exists) and why. `not applicable in v2`: the surface is not shipped. `open`: the row says what is left. a fix in v2 does not change a deployed immutable contract, so rows that exist live also say `live: open` or the action that mitigates them. |
| runbook ids | `action N` is part 1 action N of RUNBOOK.md (1 collect 111, 2 collect LAYER, 3 keeper, 4 deprecate 0xf051, 5 LAYER router floors, 6 LAYER freezes, 7 keep 0x4959 deprecated and retire hook 0x636c, 8 claim LAYER fees, 9 swapper stranding limits, 10 other owner items). `gate N` is row N of "must be true before public" in part 2. `2a`, `2b`, `2c` are the v2 rollout steps. the provisional RB ids of the first draft are gone. |
| disclosure | review docs name live critical and high issues on immutable contracts (LF-01, K-01, H14). per D26 the branch and draft pr are already public. the owner should read the mitigations first. |
| not covered | `lib/`, permanent collection contracts (renderer 0x9438, adapters, TokenAdminPoker), third party infra, legacy hooks, the LAYER pool end to end, and any v2 deployment (none exists, so no deployed v2 bytecode was checked). |

## 2. headline table (ten most important)

severity: critical, high, medium. live means exploitable or biting on a deployed contract today. latent means code is wrong but no live coin or pool uses the path. the last two columns say what v2 did and what the owner can do today on the live contracts.

| # | ids | sev | live or latent | title | status in v2 | mitigation today |
|---|---|---|---|---|---|---|
| 1 | LF-01 | critical | live: locker 0x866e (coin 111), legacy locker 0x75BE (LAYER) | `collectRewardsWithoutUnlock` is permissionless and takes the position manager's whole credit in the caller's unlock. uncollected lp fees can be redirected | fixed. l1: v2 collect opens its own unlock, reverts inside a foreign one, `test_lockerV2_collectInsideForeignUnlock_reverts`. live lockers: open, immutable | actions 1, 3 (111) and 2 (LAYER). narrows the window, does not close it |
| 2 | H14, FT-01 | high | live: coin 111, hook 0x636c | add then remove canonical liquidity in one unlock mints tax exemption budget at zero capital, spent on any side venue. 111 buys on side venues go untaxed (15%) | fixed. D46 (no lp on a taxed pool after arming, removals never attest), h1 + t1, `test_tax_thirdPartyAdd_reverts`. the v2 pass found the netting fix (D34) insufficient (V2A-01, V2H-02), D46 closes it. live 111: open | action 10 (not owner actionable, permanent collection call) |
| 3 | LF-02, K-01 | high | live: 111 fee swapper 0xeBD9 | any caller moves the swapper's eth slot from escrow into the swapper, where no function can forward it. permanent loss for the recipient. collect plus claim fits in one tx | fixed. p1 + l1, D13: `test_swapperV2_thirdPartyEscrowClaim_thenFlush_forwardsAll`, `test_escrowV2_selfClaimOnly_blocksThirdParty`. live swapper: open, stranded eth is unrecoverable | actions 3 and 9. cannot stop a same tx griefer |
| 4 | LF-09, LF-03 | high | LF-09 live: burn routers 0x2edb (LAYER), 0xE600. LF-03 src only | live routers swap the full balance per call behind stale owner floors (30.8% and 63.9% of spot). src BurnRouter clamp loops in one tx (31 calls, ~29% of balance lost on local, LAYER pool drained 1.9 of 2 weth on fork) | fixed. p1: `BurnRouterV2` with pacing, impact cap, fee aware floor (D50) and `maxBurnPerCall` (D40), `test_burnV2_loopingContract_cannotExceedImpact`. live routers: open, owner floor only | action 5 |
| 5 | H1, H2 | high, medium | latent for 111 (its recipient implements the selector). live shared hook, any new pool | stream probe decodes outside the try, so an eoa or empty fallback bounty recipient bricks every swap once it holds 0.01 eth. a recipient that rejects eth bricks all skimmed swaps. config is frozen | fixed. h1, D41: stipend only pushes, probe removed, `test_swap_bountyEoaWithBalance_noRevert`. the v2 pass found the capped push still unsafe (V2H-01, high), D41 closes it. live 0x636c: open for new pools | action 7 |
| 6 | FT-02, FT-03, S-03 | medium | live: open factory 0xf051 (public, fee 0, zero coins) | launch hijack: token address ignores sender and pool or locker config. any caller can also set protocol bps to 0. proved on fork against 0xf051 | fixed. f1: salt binds sender and full config, `test_launch_frontrunCopiedConfig_differentAddress`. FT-03 economic bypass closed by D52, D53. 0xf051 itself: open until the owner sends action 4 | action 4 (one owner tx, reversible, not sent by this review) |
| 7 | H4, H5, H7 | medium | live: any price limited swap on 111 | skim charged on the requested amount, not the fill. 50 eth exact in with a 0.05% limit filled 0.0028 eth and paid 3 eth skim. exact out sell can make the seller pay eth | fixed. h1, b3 + D58: skim on the fill, refund through the escrow to a refund address, `test_skim_exactInPriceLimited_refundsUnfilled`. H7 not applicable (D14). residual V2H-06 open. live 111: open | none in runbook (integrator note not published) |
| 8 | UI-01 to UI-08 | high | latent: no deployed ui found. not run in a browser | ui has zero mainnet addresses, stale abi (wrong selector), never sends the deploy fee, sell always reverts, wrong hook abi, no native eth pool path. eth can be sent to 0x0, wrong direction swaps | fixed. u1: registry addresses, abis from the frozen interfaces, fee read and sent, native sell path proven on a fork, `npm test`, `npm run check:abi`. v2 stack config waits for the v2 deploy | gate 8 |
| 9 | S-01, S-02, S-04 | high | live risk if run: script targets the wrong factory | no script can launch on the current stack. the wiring script hardcodes the open factory 0xf051 and renounces ownership. readme points operators at the legacy deploy | S-02 fixed (readme), S-04 fixed (s1: `DeployV2Stack`, `LaunchV2Coin`, `test_launchV2Coin_script_dryRunOnly`). S-01 open: addresses repointed, renounce path untouched, script unused | none in runbook. do not run the guarded legacy scripts |
| 10 | HY1, HY2, HY3, HY5 | high | live: mirror and ci | mirror pushes any tag to the public repo. v2 review material goes public on merge. origin is the public repo. about 140 fork tests pass without running | HY1 fixed (ancestor tags only), HY5 fixed (`vm.skip`, 7 invariant views left). HY2 and HY3 open: owner decisions (D26) | gate 13 |

runbook key (the ids used in every mitigation column):

| id | what | covers |
|---|---|---|
| action 1 | collect 111 lp fees now, keep collecting | LF-01, LF-02 window |
| action 2 | collect LAYER on the legacy locker | LF-01 legacy |
| action 3 | deploy and run `CollectFlushKeeperV1` for 111 | LF-01, LF-02, K-01, K-04, K-05, K-07 |
| action 4 | `setDeprecated(true)` on the open factory 0xf051 | FT-02, FT-03, S-03 |
| action 5 | LAYER burn router floors near 95% of spot | LF-09, LF-12 |
| action 6 | LAYER freezes (scripty, renderer, extension), irreversible | R4, G2 |
| action 7 | keep 0x4959 deprecated, `setHook(0x636c, false)` after the first v2 coin trades | H1, H2, H3, HR-1 (new launches only) |
| action 8 | claim the owner's unclaimed LAYER fees | context only |
| action 9 | 111 swapper stranding: what the owner can and cannot do | LF-02, K-01 |
| action 10 | other owner items: 111 tax rate (token admin is not the owner), 111 `contractURI` gas, locker keeper reward stays 0 | H14, FT-01, FT-05, G1, K-04 |
| gates 1 to 14 | "must be true before public" in part 2: 2 `verify-v2.sh` clean, 3 registry verifies, 4 sizes, 8 ui points at v2, 12 defaults read back, 13 repo decision D26 | RG, UI, HY, S-10 |

## 3. findings by area

columns: id, severity, title, live exposure, proof (the v1 or live proof test), status in v2, mitigation today. "block" refers to DESIGN section 3 (b1 to b8, d1 to d8). packages: a0 constants and interfaces, h1 hook, t1 token and deployer, l1 locker, escrow and delivery, m1 mev module, p1 periphery (swapper, burn router, controller), r1 renderers, e1 extensions, f1 factory, k1 keepers, u1 ui, s1 deploy scripts, i1 integration. test names without a path are in `test/v2/` (the file is named when ambiguous). D numbers are DECISIONS.md.

### 3.1 contracts: hooks and mev (contracts-hooks-mev.md)

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| H14 | high | add then remove canonical liquidity mints tax budget | 111, hook 0x636c | test_bug_H14_addRemoveCanonicalLiquidityMintsTaxBudget (TaxBudget.t.sol), live: test_bug_H14_live_addRemoveBudgetBypassesTax (LiveStack.t.sol) | fixed. h1 + t1, D46 (taxed pools take no lp after arming, removals never attest) with D34 netting. `test_tax_thirdPartyAdd_reverts`, `test_tax_addOnlyBeforeArming_andInCreationBlock`, `test_venue_roundTripThenSidePoolBuy_taxedInFull` (HookV2.fork), `test_venue_removalAttestsNothing` (TokenV2). live 111: open, token and hook are immutable | action 10 (not owner actionable, a permanent collection call) |
| H1 | high | stream probe bricks swaps for eoa or empty fallback recipient | not 111. any new pool on 0x636c | test_bug_H1_eoaBountyRecipientSelfBricksPool, test_bug_H1_emptyFallbackRecipientBricksForever, control test_control_H1_noSelectorRecipientIsCaught (SkimDelivery.t.sol). also harness test_knownIssue_* | fixed. h1, D41: no recipient code beyond the 2,300 gas stipend, probe removed. `test_swap_bountyEoaWithBalance_noRevert`, `test_swap_bountyEmptyFallback_noRevert`, `test_swap_noStreamProbe`. live: latent for 111, open for any new pool on 0x636c | action 7 (stops new launches on 0x636c via factory 0x4959). no action for 111, its recipient has code |
| H2 | medium | bid leg push reverts the swap, rejecting recipient bricks pool | any pool with a recipient that can reject eth | test_bug_H2_rejectingBountyRecipientBricksAllSwaps | fixed. h1, D41 + FeeDelivery: a rejecting recipient is credited in the escrow. `test_swap_bountyRejectsEth_escrowed`, `test_swap_protocolRejectsOrBurnsGas_escrowed`, `test_delivery_reverting_escrowed`. live: open for new pools on 0x636c | action 7 |
| H4 | medium | exact in buy skimmed on amountSpecified, not the fill | 111 (live proof) | test_bug_H4_exactInBuyPartialFillSkimsUnfilledAmount, live test_bug_H4_live_priceLimitedBuyOvercharges | fixed. h1, b3 + D58: skim on the realized fill, over charge credited in the escrow to the refund address (hookData) else the caller. `test_skim_exactInPriceLimited_refundsUnfilled`, `test_skim_fullFill_noRefund`, `test_skim_universalRouterPartialFill_nothingInEscrow`. live 111: open | none in runbook (integrator note: no price limit on quote specified swaps, not published) |
| H5 | medium | exact out sell, seller pays eth on partial fill | skim hook pools | test_bug_H5_exactOutSellPartialFillMakesSellerPayEth | fixed, residual open. h1, b3 + D58: skim on the fill. `test_skim_exactOutPriceLimited_refundsUnfilled`. residual V2H-06: an exact out seller's eth delta is negative until the refund is claimed (section 9). live: open | none in runbook (integrator note, not published) |
| H6 | medium | sniper extra not grossed up on exact output (~24% discount) | static and base hook only (open stack 0xAAd6, LAYER 0xA5eA) | test_bug_H6_sniperExtraExactOutputDiscount | not applicable in v2 (dropped surface). D14, D22: no static or lp fee mev path. `test_mevV2_neverUsableAsFeeModule` | none |
| H7 | medium | sniper extra charged on unfilled input | same hooks as H6 | test_bug_H7_sniperExtraChargedOnUnfilledInput | not applicable in v2 (dropped surface). D14. the skim analogue (charge on the fill) is H4 | none |
| H11 | medium | anyone opens pools for any coin on the shared hook | 111 and any coin on 0x636c | test_bug_H11_openPoolForFactoryCoinOnSharedHook, live test_bug_H11_live_openPoolForCoin111 | fixed. h1, f1, d3: pools come only from `initializePool` by a launcher. `test_hookV2_noOpenInit`, `test_hookV2_directPoolManagerInit_reverts`. live 0x636c: open, immutable | none. action 7 does not close it. the ui trades only pools whose id matches the launch event (UI-07) |
| H13 | medium | self referral rebate from protocol leg | 111 (0.25% of volume cap) | test_bug_H13_selfReferralRebate, live test_bug_H13_live_selfReferralRebate | accepted. D44, D52: a direct caller cannot be its own referrer (`test_referral_selfReferralByCaller_refused`). a router user can name its own wallet, bounded by the frozen per pool cap (max 1% of volume) and the protocol floor (`test_referral_neverBelowProtocolFloor`). live 111: open, 0.25% cap | none |
| H3 | low | codeless referralPayout reverts referred swaps | not 111 (payout has code) | test_bug_H3_codelessReferralPayoutRevertsReferredSwaps | fixed. h1, D59: the referral leg is pushed to the referrer with the stipend, escrow on failure, `referralPayout` is never called in a swap. `test_referral_rejectingReferrer_escrowed`. live: open for referred swaps on a codeless payout | action 7 |
| H8 | low | module window 180 min vs hook cap 15 min, linear fee cliff | legacy and open stacks | test_bug_H8_linearFeesCliffAtHookCap (SniperAndModules.t.sol) | fixed. m1 + h1, b7, D22: one 180 minute window cap, hook expires the module at the cap. `test_mevV2_durationAboveCap_reverts`, `test_hookV2_lockEndsAtCapEvenIfModuleLies`. live legacy and open hooks: not fixable | none |
| H9 | low | skim module on static hook reverts swaps for the window | latent | test_bug_H9_skimModuleOnStaticHookRevertsSwapsForWindow | not applicable in v2 (dropped surface). D14: no static hook, modules are skim only. `test_mevV2_neverUsableAsFeeModule` | none |
| H10 | low | static fee direction inverse of docs | no live impact (symmetric) | test_bug_H10_staticFeeDirectionInvertedVsDocs | not applicable in v2 (dropped surface). D14: no static fee hook | none |
| H12 | low | `setPoolExtension` works on open and never created pools | live hook 0x636c | test_bug_H12_setPoolExtensionBypassesOpenPoolBan | not applicable in v2 (dropped surface). D7: no per pool setters, the pool extension is frozen at launch and must be allowlisted (`test_hookV2_extensionMustBeAllowlisted`). live 0x636c: open | none for 0x636c |
| N1 to N6 | low, info | uncapped gas on probe and push, extension sees amountSpecified, sniper flush erc20 push, extension gas, stray eth, escrow reentrancy lock | live hook | reading, no test | N1 fixed (D41). N2 fixed (`test_extension_seesRealizedTraderDelta`). N3 not applicable (D14, no base sniper flush). N4 accepted (extensions are owner allowlisted, none are ported, D27). N5 fixed (`test_receive_onlyPoolManager`, `test_rescue_eth`). N6 accepted (V2A-08, self affecting only) | none |

### 3.2 contracts: factory, token, deployer, escrow (contracts-factory-token.md)

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| FT-01 | high | same mechanism as H14, seen from the token | 111 | test_bug_FT01_live111_addRemoveCanonicalSkipsSidePoolTax (fork: 183,185 coin buy pays 27,477 tax, after add+remove pays none), test_bug_FT01_unbackedCanonicalBudgetExemptsSideVenues | fixed. same as H14: D46, `test_venue_removalAttestsNothing`, `test_tax_budgetNotSpendableOnV3Venue`, `test_venue_roundTripThenSidePoolBuy_taxedInFull`. live 111: open | action 10 |
| FT-02 | medium | launch hijack, salt binds no sender or pool or locker config | open factory 0xf051 (proved on fork) | test_bug_FT02_launchHijackSameAddressDifferentConfig, test_bug_FT02_FT03_liveOpenFactoryHijackAndZeroProtocol | fixed. f1, b4: salt binds the sender and the full config hash. `test_launch_frontrunCopiedConfig_differentAddress`, `test_launch_changedLockerConfig_differentAddress`. live 0xf051: open until action 4 is sent | action 4 |
| FT-03 | medium | caller chosen protocol bps, can be 0 | 0xf051. on 0x4959 owner and admins only | test_bug_FT03_publicCallerZeroesProtocolSlot, live leg of the FT-02 fork test | fixed. f1: the protocol bps override exists only in `deployTokenAsOwner` (`test_protocolBps_ownerOnlyOverride`). the economic bypass found in the v2 pass (V2F-01, V2F-02) is closed by D52 (`test_referralCap_protocolFloor_boundary`) and D53 (`test_minLpFee_boundaryAndSetter`). live 0xf051: open until action 4 is sent | action 4 |
| FT-05 | medium | admin mutates image, metadata, tax rate beyond renderer | all coins | test_bug_FT05_tokenAdminMutatesMoreThanRenderer | accepted. D8: the tax rate stays tunable inside the frozen `taxBpsMax` (`test_setTaxBps_aboveCap_reverts`). image and metadata stay admin mutable and cosmetic (DESIGN section 2, t1 notes), bounded by the D30 string caps. live 111: open, token admin is a permanent collection contract | action 10 |
| FT-07 | medium if public | arbitrary tax sink and exempt list | owner only today. 111 sink 0xf5c3 is a contract | test_bug_FT07_publicDeployerRoutesTaxToSelfAndExemptsSelf | fixed. f1 + t1: D10 sink is DEAD or the bounty recipient, D47 exempt entries need the owner allowlist. `test_factoryV2_taxSinkOutsideAllowedSet_reverts`, `test_exemptAllowlist`, `test_sink_mustBeDeadOrBounty`. the live 111 sink is a contract, documented | none |
| FT-04 | low | cannot disable an allowlisted contract whose erc165 changes | no | test_bug_FT04_cannotDisableExtensionWhoseInterfaceCheckFails | fixed. f1: disabling never calls the target. `test_disable_failingModule`, `test_disabledModule_blocksLaunch` | none |
| FT-06 | low | tax config not bound to the factory pool | owner only | test_bug_FT06_taxCanonicalPoolNotBoundToFactoryPool | fixed. f1 + t1: the token derives its canonical pool id, the hook and the factory re check it. `test_canonicalPoolId_matchesKey`, `test_factoryV2_taxSinkOutsideAllowedSet_reverts` | none |
| FT-08 | low | venue coverage, unlisted dex untaxed, sub 7 wei untaxed | 111 (sushi v2 weth not a venue) | test_bug_FT08_unlistedVenuesAreUntaxed | accepted. D9, D24: VENUE mode cannot tax an unlisted dex (the venue list is add only), under 7 wei is untaxed at 15%. HARD mode blocks the PoolManager and listed venues (`test_hard_v3VenueTransfer_reverts`, `test_hard_derivedVenue_blocked`), erc6909 claims on side pools are the accepted residual | none |
| FT-10 | low | reward array truncation on protocol slot injection | owner only | test_bug_FT10_mismatchedRewardArraysTruncatedByInjection | fixed. f1: project array lengths are checked before the protocol slot is appended. `test_bpsSumRules` | none |
| FT-11 | low | escrow `claim` forced push strands erc20 in fee owner contract | yes | test_bug_FT11_escrowForcedClaimStrandsErc20InFeeOwner | fixed. l1, D13: opt in `selfClaimOnly`, `FeeAutoSwapperV2` opts in at construction. `test_escrowV2_selfClaimOnly_blocksThirdParty`, `test_escrowV2_claimTo_onlyFeeOwner`. live escrow 0x7559: open, immutable | none |
| FT-09 | info | extension rounding dust to team | yes (zero at 1B supply) | test_bug_FT09_extensionRoundingDustSweptToTeam | fixed. f1: extension rounding dust goes to the pool supply. `test_dust_toPool_neverTeam` (the locker then sends its own rounding to DEAD, V2F-05) | none |
| FT-12 | info | `TokenCreated` incomplete, startingTick misleading | yes | reading | fixed. f1: `TokenCreatedV2` carries the full config and its hash. `test_event_fullConfig` | registry and calldata |
| FT-13 | info | single step ownable plus renounce, permit2 allowance, no votes, state after extensions | yes | reading | fixed. D20: Ownable2Step on every owned contract, factory `renounceOwnership` reverts. `test_escrowV2_ownable2Step`, `test_owner_twoStepTransfer`, `test_pfcV2_ownable2Step`. the infinite permit2 allowance stays on the token (D37, accepted), no votes (`test_permit2InfiniteAndNoVotes`) | none |

### 3.3 contracts: locker, swapper, burn router, protocol fee (contracts-locker-fees.md)

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| LF-01 | critical | `collectRewardsWithoutUnlock` diverts uncollected lp fees | locker 0x866e (111), 0x75BE (LAYER, hook collects each swap so smaller) | LpLockerReview.t.sol test_bug_LF01_collectRewardsWithoutUnlock_lets_anyone_steal_all_lp_fees. fork: LiveForkReview.t.sol test_bug_LF01_fork_live_111_uncollected_fees_stealable | fixed. l1, d1: `collectRewards(address)` opens the position manager's own unlock and reverts `PoolManagerUnlocked()` inside a foreign one, there is no `collectRewardsWithoutUnlock`. `test_lockerV2_collectInsideForeignUnlock_reverts`. live 0x866e and 0x75BE: open, immutable, exposure is what accrued since the last collect | actions 1 and 3 (111), action 2 (LAYER). k1 helper narrows only |
| LF-02 | high | third party escrow claim strands swapper paired fees | 111 swapper 0xeBD9 | FeeAutoSwapperReview.t.sol test_bug_LF02_third_party_claim_strands_native_fees_in_swapper (and weth). fork test_bug_LF02_fork_live_111_swapper_eth_strandable. keeper test_bug_swapperV1_thirdPartyClaim_strandsEth | fixed. p1 + l1, b5, D13: the swapper claims from the escrow then forwards its whole balance, `selfClaimOnly`. `test_swapperV2_thirdPartyEscrowClaim_thenFlush_forwardsAll`, `test_escrowV2_selfClaimOnly_blocksThirdParty`. live 111 swapper 0xeBD9: open, nothing recovers stranded eth | actions 3 and 9 (collect and flush in one tx, cannot stop a same tx griefer) |
| LF-03 | high | burn router impact clamp loopable in one tx | src only (not deployed per records) | BurnRouterReview.t.sol test_bug_LF03_impact_clamp_loops_in_one_tx_and_sandwich_profits. fork test_bug_LF03_fork_src_burnrouter_loop_on_live_layer_pool | fixed. p1, b6: one burn per block, impact cap. `test_burnV2_secondCallSameBlock_reverts`, `test_burnV2_loopingContract_cannotExceedImpact`. the src router is not deployed | none needed live |
| LF-09 | high | live routers burn full balance behind stale floors | 0x2edb, 0xE600 | LiveForkReview.t.sol test_LF09_fork_live_burnrouter_full_balance_owner_floor (0.503 weth in one call) | fixed. p1, b6 with D32, D40, D50: `BurnRouterV2` has a bounded fee aware floor and `maxBurnPerCall`. `test_burnV2_spotFloor_bounds`, `test_burnV2_maxBurnPerCall_capsBudget_andBounds`, `test_burnV2_skimPool_50eth_burnsEveryBlock_drains`. live routers 0x2edb and 0xE600: open, immutable, mitigated by the owner floor | action 5 |
| LF-04 | medium | keeper reward on whole balance | src. live LAYER pool fork run: 0.10 eth keeper for 1.9 weth | test_bug_LF04_keeper_reward_on_whole_balance_farmed_by_loop | fixed. p1, D40: reward on the consumed input net of the hook refund, capped. `test_burnV2_partialFill_rewardOnConsumed`, `test_burnV2_skimPool_partialFill_netOfRefund` (also V2B-03) | none |
| LF-07 | medium | swapper slippage cap is deploy time, 111 at 500 bps | 111 swapper. not quantified | reading | fixed. p1, D39 + D50: impact cap (default 100 bps), one convert per block, fee aware floor, `maxStepIn`. `test_swapperV2_impactCap_defaultBindsBelowSlippage`, `test_swapperV2_sandwich_boundedByImpactCap`, `test_swapperV2_feeAwareFloor_6pctSkimPool_convertsAtDefault`. residual loss per call is bounded by the cap, D56. live 111 swapper: open (500 bps, immutable) | actions 1 and 3 (quoted minOut, private send) |
| LF-05 | low | slot admins can repoint recipients, zero not rejected | yes, but 111 slot admin is 0xdEaD | test_bug_LF05_recipient_mutable_post_launch_and_zero_recipient_strands_fees | fixed. l1, D7: no slot admins, the split is frozen at placement, zero recipient rejected. `test_lockerV2_place_freezesSplit`, `test_lockerV2_place_zeroRecipient_reverts`. live 111 admin is 0xdEaD | none |
| LF-08 | low | swapper payout failure bricks flush and convert | 111 endRecipient accepts eth today | test_bug_LF08_unpayable_end_recipient_bricks_flush_forever | fixed. p1, d1: a reverting `endRecipient` falls back to the escrow. `test_swapperV2_revertingEndRecipient_fallsBackToEscrow`. needs the swapper to be an escrow depositor (D33), nothing on chain checks it (V2B-07, runbook 2b steps 1 and 6) | none |
| LF-10 | low | controller no rescue, rotation depends on old router | src controller. live PC controller 0xd8C6 | reading | fixed. p1: the controller has `rescue`, rotation never calls the old router. `test_pfcV2_rescue`, `test_pfcV2_rotation_noOldRouterCall`. the owner rescue is unbounded by design (V2B-09, owner trust) | none |
| LF-11 | low | locker `withdrawETH` uses `transfer` | yes | reading | fixed. l1: `rescue` sends with a call, not `transfer`. `test_lockerV2_rescue_rules`, `test_lockerV2_rescue_cannotTouchInFlightShares` | none |
| LF-12 | info | live router view under reports enforced minimum | 0xE600 | seen in LF-09 fork test | fixed. p1: `floorFor` is the enforced value. `test_burnV2_floorView_matchesEnforcement`. live 0xE600 view is unchanged | action 5 (keepers pass minLayerOut from the setter value) |
| LF-13 | info | `ISwapRouterV3` unused | n/a | reading | open. `src/utils/ISwapRouterV3.sol` is still in the tree (v1 kept as the record, D6). nothing in v2 imports it. delete in a cleanup | none |
| HR-2 | low | `placeLiquidity` leaves wei level coin dust in locker (8,767 wei) | yes | Harness.t.sol test_freshStack_launchBuySell_feeFlows (asserts under 1e9) | fixed. l1: the locker sends coin rounding dust to DEAD (`Constants.DEAD`), so none stays in it | none |

### 3.4 contracts: extensions and renderers (contracts-extensions-renderers.md)

every extension finding is latent on the current and open factories (no extension enabled there). renderer gas findings are live.

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| G1 | medium | coin 111 `contractURI` costs ~177M gas, reverts under 50M and 100M call caps | live, 111, renderer 0x7604 forwarding to 0x9438 (outside this repo) | ForkRenderersReview.t.sol test_measure_G4_liveLayerAnd111 (179,363,374 gas). `cast call --gas-limit 200000000` returns 310KB | fixed for v2 renderers, open live. r1, b8, D30: string caps and the 8m render gas budget. `test_renderV2_maxGlyphsUnderBudget`, `test_renderV2_oversizeTokenStringsStillValid`. live 111 `contractURI` (177M gas): open, renderer is outside this repo | action 10 (permanent collection side) |
| A2 | medium | airdrop root replaceable after lockup plus 1 day while zero claims | latent, legacy extension | ExtensionsReview.t.sol test_bug_A2_airdrop_adminSwapsRootAndTakesEverything | fixed. e1, D27: `ArtCoinsAirdropV2` has no root replacement and no admin function. `test_A2_noRootReplacementOrAdminFunctionExists`, `test_A2_originalRootStillClaimsAfterOneDay` | none |
| G2 | low | LAYER renderer gas unbounded in trade count (32.4M today) | live, LAYER renderer 0x0572 | ForkRenderersReview.t.sol test_bug_G2_liveLayerRendererExceeds50MGasAsTradesGrow (58.8M at 250,000 trades) | not applicable in v2 (dropped surface). D27: the LAYER renderer is not ported. live LAYER renderer: open, grows with trades | action 6 (freezes only, no gas fix) |
| R1 | low | svg text unescaped in DynamicBlock and Example renderers | latent, no live coin | RenderersReview.t.sol test_bug_R1_* (3 tests) | fixed. r1, b8: every token string goes through `SvgText`. `test_renderV2_R1_dynamicBlockNameCannotInjectMarkup`, `test_renderV2_R1_exampleNameCannotInjectMarkup`, `test_renderV2_R1_ampersandSymbolKeepsXmlValid` | none |
| R3 | low | sprite renderer href and animation url unescaped | latent | test_bug_R3_spriteRenderer_imageUrlBreaksOutOfHrefAttribute | fixed. r1: `test_renderV2_R3_spriteImageUrlCannotBreakOutOfHref`, `test_renderV2_R3_spriteAnimationUrlIsJsonEscaped` | none |
| A1 | low | zero root airdrop plus second entry strands first tranche | latent | test_bug_A1_airdrop_zeroRootThenSecondEntryStrandsFirstTranche | fixed. e1: tranches are independent per index, an empty root reverts. `test_A1_twoTranchesInOneLaunchAreIndependent`, `test_launch_emptyRootReverts` | none |
| A3 | low | zero airdrop admin locks unclaimed | latent | test_bug_A3_airdrop_zeroAdminLocksUnclaimedForever | fixed. e1: the sweep pays a frozen nonzero recipient after the window. `test_launch_zeroSweepRecipientReverts`, `test_sweep_afterWindowPaysFixedRecipientOnly` | none |
| V1 | low | vault admin zero bricks allocation | latent | test_bug_V1_vault_zeroAdminBricksClaims | fixed. e1: `test_V1_zeroBeneficiaryReverts`, `test_beneficiaryCannotBeTokenOrVault` | none |
| LL1 | low | auto forward on native eth pool reverts every afterSwap | latent (not allowlisted on current hook) | test_bug_LL1_autoForward_nativeEthPoolRevertsEverySwap | not applicable in v2 (dropped surface). D27: the auto forward extension is not ported | none |
| LL2 | low | trader can starve the pool extension of gas | live on LAYER | trace only | not applicable in v2 (dropped surface). D27: no counter pool extension. live LAYER: open | none |
| AB1 | low | auto burn runs in untrusted swaps, keeper reward always fails | latent | trace only | not applicable in v2 (dropped surface). D27: the auto burn extension is not ported. router side: `processBurnOpenTab` is gated to an owner set caller, default none (D31), `test_burnV2_openTab_disabledByDefault_reverts` | none |
| D1 | low | dev buy minimums caller chosen, hop on public pool | latent | reading | fixed. e1: a nonzero `minTokenOut` is required. `test_minOutZeroReverts`. launches should still go through a private mempool | private mempool for launches |
| R2, R4, D2, V2, A4, LL3, F1, AB2 | info | utf8 truncation, mime splice, dev buy ordering, vault event, merkle duplicate leaves, seed bypass, rounding dust, reads outside try | mixed | R2: test_bug_R2_dynamicBlockRenderer_truncationSplitsUtf8. R4: test_bug_R4_onchainRenderer_mimeTypeInjectsScript. rest reading | R2 fixed (`test_renderV2_R2_dynamicTruncationDoesNotSplitEuro`). R4 not applicable (scripty renderer not ported, D27). D2 open (info, V2F-06: dev buy runs before the module arms, kept for v1 parity, documented). V2 fixed (`test_claim_eventRemainingAmountIsTotalMinusClaimed`). A4 fixed (`test_A4_twoLeavesForOneAddressBothPaid`). LL3 and AB2 not applicable (D27). F1 fixed (`test_dust_toPool_neverTeam`) | R4 live LAYER: action 6 (freeze scripty content) |

### 3.5 scripts and ops (scripts-and-keepers.md part a, harness.md)

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| S-01 | high | wiring script hardcodes open factory 0xf051, hook 0xAAd6, escrow 0xDD1b, and renounces locker ownership | passes only on the wrong factory | reading (DeployConversionLockerAndWire.s.sol:58-61,:129) | open. the hardcoded addresses are replaced by registry constants and the script requires chain id 1 (address-wiring row 15). left: the renounce step and post asserts are untouched. the script fails closed on the deprecated current factory and nothing needs it | none in runbook. do not run it |
| S-02 | high | readme tells operators to run Deploy.s.sol, which deploys the legacy stack | docs | reading | fixed. README deploy table rewritten, v2 points at `script/v2/DeployV2Stack.s.sol`, old scripts marked history (address-wiring row 3) | none |
| S-03 | high | DeployNativeEthStack opens factory to the public by default | live: 0xf051 matches | reading, FT-02 fork proof | mitigated. `DeployNativeEthStack` refuses mainnet without `ALLOW_SUPERSEDED=1` (address-wiring row 27). the open factory itself is closed by action 4 | action 4 |
| S-04 | high | no script launches on the current skim stack | none | reading, not run on chain | fixed. s1: `script/v2/DeployV2Stack.s.sol`, `LaunchV2Coin.s.sol`. `test_deployV2Stack_launchFirstCoinAsOwner_thenOpen`, `test_launchV2Coin_script_dryRunOnly`. no script targets the old current stack, it is deprecated and replaced | none |
| S-05 | medium | LAYER one shot scripts, preflight only warns | LAYER | reading | mitigated. LAYER one shot scripts refuse mainnet without `ALLOW_SUPERSEDED=1` (address-wiring rows 19, 25, 27) | none in runbook |
| S-06 | medium | DeployV1Stack post flight does not assert hook is an escrow depositor | deploy time | reading | fixed in v2. s1: `DeployV2Lib.check` asserts escrow depositors and core flags (D36). `test_deployV2Stack_wiringComplete`. v1 `DeployV1Stack` unchanged, superseded | none |
| S-07 | medium | DeployV1Stack leaves ownership on the raw deployer key. live 0x4959 differs (fee 0.069, team = owner) | 0x4959 | reading, HR-3 | fixed in v2. D20 Ownable2Step, the deploy lib hands owner powers to OWNER and `acceptV2Ownership` is exercised. `test_deployV2Stack_wiringComplete`, runbook 2a step 12 | none |
| S-08 | medium | no chain id guard in most deploy scripts | deploy time | reading | fixed. the v2 scripts require chain id 1 (`DeployV2Stack`, `LaunchV2Coin`, `RunKeeper111`). legacy scripts refuse mainnet without `ALLOW_SUPERSEDED=1` (address-wiring row 27) | none |
| S-09 | medium | 32 scripts read `PRIVATE_KEY` from env | operator | grep | open. the v2 scripts read no key (`--ledger`, `--account`). 32 legacy scripts still read `PRIVATE_KEY` from env | use a keystore, not env |
| S-10 | medium | verify-stack.sh stale and exits 0 on failure | ci | reading | fixed. `verify-stack.sh` rewritten on the registry and exits nonzero on failure (address-wiring row 23). `script/v2/verify-v2.sh` for the v2 stack | gate 2 |
| S-11 | medium | sync-addresses.mjs writes legacy addresses into `.env` | operator | reading | fixed. `sync-addresses.mjs` prints registry exports and writes nothing (address-wiring row 24) | none |
| S-12 | medium | SetUpLayerAutoForward stale backfill, Live*Verify do real swaps | operator | reading | mitigated. guarded by `ALLOW_SUPERSEDED=1` (address-wiring row 25). `Live*Verify` still send real swaps when the guard is overridden | none in runbook |
| S-13 | medium | PC controller doc says 80/20, constant is 8667/1333 | docs | reading | open. `DeployPCController.s.sol` comments still say 80/20, the constant is 8667/1333. the router address comment was fixed (address-wiring row 17) | none |
| S-14 to S-21 | low | RedeployBurnRouter rewires team recipient, dead RedeployHook, test launches at fixed tick, tick tool no native mode, puppeteer on chain html, allowlist builder, argv rpc urls, no dry run guard | operator | reading | open. the redeploy scripts only gained the `ALLOW_SUPERSEDED=1` guard (row 27). fixed tick test launches, native mode in the tick tool, puppeteer on chain html, the allowlist builder, argv rpc urls and the dry run guard are unchanged | none |
| HR-3 | info | live deployFee 0.069 eth vs DeployV1Stack setting 0 | 0x4959 | cast, harness parity table | fixed. the v2 deploy sets the deploy fee to 0.069 eth by default (`DEPLOY_FEE`, runbook 2a). `test_deployV2Stack_wiringComplete` | gate 12 (read back the defaults) |
| HR-1 | high | (same as H1, found by harness) bounty recipient brick | see H1 | test_knownIssue_* (Harness.t.sol) | fixed. same as H1 (D41) | action 7 |

### 3.6 website (ui.md)

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| UI-01 | high | mainnet addresses zero, eth can go to 0x0 | no hosted ui found | reading (config.ts:28-45, ReviewAndDeploy.tsx:234) | fixed. u1 with the registry wiring: config reads the registry, deploy and swap never write to a zero address. smoke render. left: the v2 stack is not configured until the v2 deploy (`VITE_V2_*` or the generator) | gate 8 |
| UI-02 | high | unknown chain falls back to sepolia addresses | same | reading | fixed. u1: `getAddresses` throws, pages use `useAddressesOrNull`, writes need mainnet. smoke render, `tsc` | gate 8 |
| UI-03 | high | stale `deployToken` abi, selector 0xdf40224a vs live 0x3f1638ea | all live factories | cast code grep | fixed. u1: abis generated from the frozen interfaces, `deployToken` selector 0x73dd3f0f pinned. `test/encodeV2.test.ts`, `npm run check:abi` | gate 8 |
| UI-04 | high | deploy fee never read or sent (0.069 eth on 0x4959) | 0x4959 | reading, cast | fixed. u1: `deployFee()` is read, shown and sent, re read before signing. `test/encodeV2.test.ts` (value) | gate 8 |
| UI-05 | high | reward bps sum 10000, factory adds protocol slot, deploy reverts `ProjectSideBpsMismatch` | 0x4959 | reading, cast | fixed. u1: project recipients must sum to 10000 minus the factory default protocol bps. `test/encodeV2.test.ts` (rejects 10000, accepts 8000) | gate 8 |
| UI-06 | high | sell always reverts (`TAKE_ALL` then `UNWRAP_WETH`) | any pool | reading of universal router source | fixed. u1: native pool sell is `SETTLE_ALL`, `TAKE_ALL`. fork sim: buy then sell of coin 111 through the universal router (`ui/scripts/fork-swap-sim.ts`). the weth path is proven by encoding only | gate 8 |
| UI-07 | high | old "newMaterial" hook abi, wrong swap direction | hook 0x636c | cast (selector absent) | fixed. u1: direction comes from the pool key and the coin, the pool key from the locker and trading needs a match with the launch event pool id. `ui/scripts/check-token-reads.ts` (live reads) | gate 8 |
| UI-08 | high | swap widget supports weth pools only, live pools are native | 111 | reading, cast | fixed. u1: native eth path, quoter in the mainnet config. fork sim | gate 8 |
| UI-09 | medium | no `deprecated()` gating or simulation | 0x4959 deprecated | reading | fixed. u1: the deploy page reads `deprecated()` and `owner()`, launch and swap are simulated before signing. smoke render | gate 8 |
| UI-10 | medium | "Verified" badge is self asserted by the deployer | all | reading | fixed. u1: no Verified badge, a neutral registry factory badge, v2 also checks `isArtCoin`. code only | gate 8 |
| UI-11 | medium | hostile metadata and images rendered unfiltered | all | reading | fixed. u1: image scheme filter, text cleaned and clamped, lookalike flag. `test/security.test.ts`. left: image proxy, size cap for https images, curated list, report flow | gate 8 |
| UI-12 | medium | token list scans from block 0 and sees one factory | all | reading | fixed. u1: one `getLogs` per registry factory from its deploy block. live: finds coin 111 in 650 ms (`ui/scripts/check-discovery.ts`). left: persisted last block, paging, legacy and open factories | gate 8 |
| UI-13 | medium | dev buy encoding wrong, no min out | legacy extension | reading | fixed. u1: dev buy encoding is 96 bytes, nonzero min out, curve estimate. `test/curve.test.ts`, `test/encodeV2.test.ts` | gate 8 |
| UI-14 | medium | quote handling weak, zero min out possible | all | reading | fixed. u1: zero min out refused, quotes refresh, impact shown, acknowledgement above 10%. `test/swap.test.ts`, fork sim (quote equals fill) | gate 8 |
| UI-15 | medium | mev defaults conflict with contracts (4140s vs 900s cap) | legacy modules | reading | fixed. u1: one module, window and start bounds enforced client side. `test/encodeV2.test.ts` | gate 8 |
| UI-16 | medium | pool data only fits the static fee hook | skim hook | cast abi decode | fixed. u1: v2 fee struct, units documented, presets mirror `script/LaunchDefaults.sol`. `test/encodeV2.test.ts` | gate 8 |
| UI-17 | medium | referral injection silent and sticky | n/a | reading | fixed. u1: referrer shown with its source, opt out switch, checksum and self referrer checks. `test/security.test.ts` | gate 8 |
| UI-18 to UI-25 | low, info | supply chain (72 advisories, 18 high), keys in bundle, allowance scope, link hardening, image upload, tx state, referrals page decode, stale branding and no escrow ui | n/a | build and `npm audit` runs, reading | UI-18 open (dependencies untouched on purpose, the ci `ui` job runs `npm audit` informational). UI-19 fixed (restricted key flag). UI-20 fixed (exact allowance). UI-21 fixed (`test/security.test.ts`). UI-22 fixed, left: irys signature not explained. UI-23 fixed, left: `useReplaced` handling. UI-24 fixed (live read of coin 111). UI-25 fixed, left: no escrow claim ui | gate 8 |

ui statuses come from ui-fixes.md (build, lint, `npm test`, `npm run check:abi`, an ssr smoke render and fork or live read scripts). nothing was checked in a browser or with a wallet.

### 3.7 keepers and automation (scripts-and-keepers.md part b, keeper-111.md)

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| K-01 | high | 111 swapper strands eth (same as LF-02) | 111 | KeeperV1_111.fork.t.sol test_bug_swapperV1_thirdPartyClaim_strandsEth | fixed in v2, see LF-02. live 111: open | actions 3 and 9 |
| K-02 | medium | bare try catch around convert silently skips under estimateGas | keeper design | reproduced on fork (review), KeeperV1_111.fork.t.sol test_keeperV1_lowGas_neverSilentlySkips | fixed. k1, D49: step gas values are floors, a shortfall reverts `InsufficientGas(step)`. `test_keeperV1_lowGas_neverSilentlySkips` (fork), `test_keeperV2_gasSweep_neverSilentlySkips` | none needed |
| K-03 | medium | draft keeper preview read only currency0 fee growth | keeper design | review | fixed. k1: `preview()` sums both currencies (keeper-111.md) | none needed |
| K-04 | medium | keeper economics do not close (breakeven ~0.23 eth output, pending 0.00065 eth) | 111 | live reads | accepted. D28: the locker keeper reward starts at 0 (the owner can raise it to 2%), the owner or a hot key runs the keeper and pays gas. breakeven stays above current pending value | actions 3 and 10 (keep the reward at 0) |
| K-05 | medium | single keeper dependency, anonymous eoa 0x71cA with 0.0135 eth | 111 | tx history | mitigated. the keepers have no owner and no allowlist, any wallet can deploy and run them (`CollectFlushKeeperV1`, `ArtCoinsKeeperV2`). the owner runs a second path. no on chain fix | action 3 |
| K-06 | low | convert pacing grief with dust | 111 | reading | open. the v2 swapper still sets `lastConvertBlock` on any nonzero convert, so a dust donation plus a call can delay a real convert by `minBlocksBetweenConverts`. the keeper reward is on the swapper's own output, so the grief costs gas only | none |
| K-07 | low | convert with minOut 0 leans on contract floors | 111 (0x71cA sends 0) | reading | mitigated. the keeper script quotes a real minOut (`test_keeperV1_scriptQuote_convertsAtDefaultSlippage`). v2 adds D39 and D50 floors. live 0x71cA still sends 0 | action 3 |
| K-08 | low | autoburn collect pays keeper reward to the extension | latent | reading | not applicable in v2 (dropped surface). D27: no auto burn extension. the locker keeper reward starts at 0 (D28) | keep `keeperRewardBps` 0 |
| K-09 | low | bounty leg reverts swap if 0x8C72 cannot take eth | 111 | see H2 | fixed in v2, see H2 (D41). live 111: open, latent while 0x8C72 accepts eth | none |
| K-10 | low | actions tag pinned, ssh host key trust on first use | ci | reading | open. actions are still pinned by major tag, the mirror ssh host key is trust on first use (hygiene-fixes) | none |
| K-11 | low | ui bundles alchemy key, referrals page calls dead function | ui | reading | fixed. u1: the alchemy key is ignored unless flagged restricted (UI-19), the referrals page is rewritten (UI-24) | none |
| gap | n/a | no keeper code existed in the repo before this session. LAYER `processBurnWeth`, controller dust and liveness monitoring still have no runner | LAYER | none | fixed for 111 and v2 coins. k1: `CollectFlushKeeperV1` and `ArtCoinsKeeperV2` (`test/v2/KeeperV1_111.fork.t.sol`, `test/v2/KeeperV2.t.sol`). open: LAYER `processBurnWeth`, controller dust and liveness monitoring still have no runner | manual |

### 3.8 ci and repo hygiene (repo-hygiene.md). HYn is hygiene Hn

| id | sev | title | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| HY1 | high | mirror pushes any tag, any private commit can go public | mirror.yml | reading | fixed. mirror pushes only tags whose commit is an ancestor of `origin/master` (hygiene-fixes H1) | gate 13 |
| HY2 | high | merge of v2 publishes review docs and proof tests for live bugs | on merge | reading | open. only a header note was added to `mirror.yml`. a curated merge of `docs/v2` and `test/v2/review` is a process decision | gate 13 |
| HY3 | high | origin is the public repo and carries wip branches | now | `git ls-remote` both urls identical | open. `origin` is the public repo, owner decision D26. nothing in the repo can fix it | gate 13 |
| HY4 | high | broadcast folder has no record of the current stack | provenance | grep | fixed. registry `deployments/mainnet.json`, verifier and ci. the v2 stack gets its record at deploy (runbook 2a step 15, `deployments/v2.template.json`) | gates 2 and 3 |
| HY5 | high | ~140 fork tests pass vacuously (return, not skip) | ci | grep, count from files | fixed. 24 files use `vm.skip(true)` instead of a vacuous return (hygiene-fixes H5). left: 7 `invariant_*` view functions in `FeeAutoSwapper.invariants.t.sol` still pass vacuously | none |
| HY6 | high | harness forks live mainnet by default in ci | ci | reading | fixed. the `check` ci job has no network, the `fork-tests` job pins block 26130269 (hygiene-fixes H5, H6) | none |
| HY7 | medium | foundry.lock disagrees with gitlinks for 5 of 8 libs | build | `git submodule status` | fixed. `foundry.lock` rewritten to the gitlink shas (hygiene-fixes H7). do not `forge update` | none |
| HY8 | medium | `.env.example` holds a 66 char placeholder private key | scanners | grep, history scan | accepted. the all zero value is a placeholder, not a key. a comment was added and no history rewrite (hygiene-fixes H8). no decision id | none |
| HY9 | medium | ci profile is not what the readme tells users to run | ci | reading | fixed. size gate under the ci profile (D14, D45), `[profile.fork]` added, README deploy table names the profile (address-wiring row 3) | gate 4 |
| HY10 | medium | fmt pinned to 1.5.0, dev toolchain 1.7.1, 2 files fail at 1.7.1 | ci | run at 1.7.1 | fixed. `FOUNDRY_VERSION: v1.7.1` for every job, tree formatted at 1.7.1 | none |
| HY11 | medium | actions tag pinned, no timeout, no concurrency | ci | reading | open. permissions, timeouts and concurrency are fixed. actions stay pinned by major tag (shas could not be looked up) | none |
| HY12 | medium | mirror repo guard is a hard coded name | mirror | reading | open. the mirror repo guard is still a hard coded name, not in the hygiene change | none |
| HY13 | medium | readme deploy example is the legacy stack | docs | reading | fixed. README deploy section rewritten (address-wiring row 3) | none |
| HY14, HY15 | medium | script-js no lockfile, ui has no ci, 11 high advisories in prod deps | supply chain | `npm audit` | open. script-js lockfile fixed and a ui ci job added (non blocking, `continue-on-error`). left: the prod dependency advisories (UI-18) | none |
| HY16 to HY25 | low, info | unused submodule, oz pin off tag, scratch artifacts, broadcast size, personal paths, model trailers on side branches, gitignore oddities, bytecode equality check missing, mirror verified fast forward only, no mirror drift | n/a | reading | HY23 fixed (size gate, and the registry compares runtime bytes). HY24 fixed (fast forward only noted), ssh host key trust on first use stays open. HY16 to HY22 and HY25 open, not in the hygiene change | none |

### 3.9 docs vs code (repo-hygiene.md table and other reviews)

| id | sev | claim | where | reality | status in v2 |
|---|---|---|---|---|---|
| DC-1 | medium | "20% of the protocol slice" | README | it is 20% of lp rewards (locker slot). skim hook protocol slice is a different thing | fixed. README says 20% of lp rewards (address-wiring row 6) |
| DC-2 | low | up to 7 reward recipients | README | 6 project recipients once the protocol slot is appended (by reading) | fixed. README says up to 6 project recipients (row 4) |
| DC-3 | medium | "construction time config fixed for life" | README | admin can change admin, image, metadata, renderer, tax rate | fixed. README lists what the admin can still change (row 5) |
| DC-4 | medium | tax "single deployment" convention | README | not enforced, any deployer can enable on a non deprecated factory | fixed. README corrected (row 7). v2 enforces the sink rule and the exempt allowlist at launch (D10, D47) |
| DC-5 | low | ethereum mainnet only | README | no chain guard in factory or hook | fixed. README says no chain id enforcement (row 8) |
| DC-6 | medium | "factory deployed 2026-05-18, see README addresses" | AGENTS.md | no such deploy date, README has no address table | fixed. three factories, current 0x4959 deployed 2026-06-06, README table generated (row 1) |
| DC-7 | low | bump recipe, hardcoded home directory paths | AGENTS.md | stale once v2 merges | open. `AGENTS.md` and `CLAUDE.md` still carry home directory paths in the bump recipe |
| DC-8 | high | "wip branches stay private" | AGENTS.md, mirror.yml | origin carries four wip branches (HY3) | open. tied to HY3, owner decision D26 |
| DC-9 | medium | readme deploy command | README:86 | deploys legacy stack (S-02) | fixed. README deploy section (S-02) |
| DC-10 | low | stale contract names in `.env.example` | .env.example | pre rename names | fixed. `.env.example` names corrected (row 9) |
| DC-11 | low | hook "~24,547 bytes, 29 bytes headroom" | foundry.toml | 20,558 bytes at ci profile, 4,018 headroom. 24,578 at default profile (over limit) | fixed. `foundry.toml` now says 16,716 bytes and 7,860 bytes of headroom at the ci profile (D14) |
| DC-12 | medium | `IPreSwapStream` natspec: a non implementing recipient can never brick a swap | interface | false (H1, HR-1) | not applicable in v2 (dropped surface). D41: no probe. the v1 natspec in `src/interfaces/IPreSwapStream.sol` is unchanged (v1 kept as the record, D6) |
| DC-13 | low | static fee interface docs buy and sell | IArtCoinsHookStaticFee | inverse (H10) | not applicable in v2 (dropped surface). D14 |
| DC-14 | medium | burn router clamp "uneconomic by construction" | BurnRouter | loops in one tx (LF-03) | not applicable in v2 (replaced). `BurnRouterV2` (b6). the v1 comment in `src/protocol-fee/BurnRouter.sol` is unchanged (D6) |
| DC-15 | low | PC controller 80/20 and "reuses the LAYER router" | DeployPCController | 8667/1333 and live router is 0x0EB2 | open. the router address comment is fixed (row 17), the 80/20 text remains (S-13) |
| DC-16 | medium | ui: "all LP rewards go to your wallet", "Verified" | ui | protocol takes 20%. self asserted badge (UI-05, UI-10) | fixed. ui copy and badge replaced (UI-05, UI-10) |

### 3.10 deployment registry (registry-notes.md, job 1)

| id | sev | finding | live exposure | proof | status in v2 | mitigation |
|---|---|---|---|---|---|---|
| RG-01 | high | current stack (0x4959, 0x636c, 0x866e, 0x7559, 0xb038, 111) has no broadcast record | provenance | grep of broadcast/ | fixed. registry, verifier and ci workflow. wiring into readme, ui and scripts done (address-wiring.md) | gates 2 and 3 |
| RG-02 | medium | broadcast has 20 fork only mainnet creates and 44 txs not on chain, indistinguishable from real | misleading | tx lookup, 133 hashes vs 89 on chain | open. the registry marks fork only entries, the `broadcast/` folder itself is not cleaned (hygiene H19 unchanged) | none |
| RG-03 | medium | source provenance: `commit` fields do not exist in history. 0x4959 stack matches head only under the `ci` profile, with ipfs metadata in the chain code (deploy used a different config than head) | all current contracts | verifier: 56 contracts, 2 coins, 0 drift | fixed in v2. s1: `verify-v2.sh` compares runtime to the ci build with immutables masked. `test_deployV2Stack_runtimeMatchesBuild`. the live stack's provenance gap stays as recorded | gates 2 and 3 |
| RG-04 | medium | live bytecode differs from head for 0xf051 (version "3"), swapper 0xeBD9, legacy hook, legacy mev modules, LAYER token and renderers | 0xf051, 0xeBD9, legacy | verifier `bytecodeMatch: mismatch` rows | accepted. D6: legacy and open stacks are replaced, not repaired. the registry marks `bytecodeMatch: mismatch` | none |
| RG-05 | low | six permanent collection contracts and scripty chunks unverified here, `etherscanVerified` unknown | 111 admin, renderer, adapters | registry notes | open. six permanent collection contracts and scripty chunks are outside this repo and were not verified here | none |
| RG-06 | medium | wrong or zero addresses across repo: ui config, DeployConversionLockerAndWire, sync-addresses, AGENTS.md, DeployPCController comment | scripts and ui | address inventory table | fixed. 27 wrong or stale sites repointed or guarded (address-wiring.md). `node script-js/gen-addresses.mjs --check` exit 0 | gate 3 |
| RG-07 | info | `version()` returns "1" on both 0x4959 and 0xd159, so it cannot tell stacks apart. 0xf051 reports "3" | integrators | cast | fixed in v2. d6 version tag per pool and `STACK_VERSION`. `test_versionTag_consistentAcrossTokenHookFactory` | registry |
| RG-08 | info | StateView and quoter addresses not recorded anywhere in repo | ui | cast (both have code, point at the pool manager) | open. stateview and quoter are in the ui config, the registry does not carry the quoter (ui-fixes.md) | none |
| RG-09 | info | PC controller 0xd8C6 burn router is 0x0EB2, not LAYER's 0x2edb | docs | cast | fixed. `DeployPCController.s.sol` comment says 0x0EB2 (address-wiring row 17) | none |

## 4. proofs for medium and above

run prefix for every command: `/tmp/claude-0/forge.sh test --skip "test/v2/harness/**" --skip script -vv --match-path`. the skips only dodge other agents' files that did not compile at the time. fork tests skip when the rpc is down or `SKIP_FORK_TESTS=true`. pass here means the bad outcome was observed. these prove the bug on v1 and live contracts, so they pass while the bug exists. v2 regressions are named per row in section 3 and live in the package suites. `test/v2/review/**` is not in the ci fork job, it runs in the informational `review-proofs` job (hygiene-fixes).

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
| v2 | independent end to end check of V2H-01 with a hostile recipient (the package suite builds one, the reviewer did not), a nested swap from a recipient, partial fill refunds through a live universal router, the HARD `donate` path, D34 netting with several canonical flows in one tx, the locker with the real hook and a taxed coin end to end | listed as unverified by the reviewers and by runbook gates 5 and 6 |
| v2 | keeper gas on the real v2 stack, launch gas at the ci profile | figures are v1 measurements with room (keepers) and default profile only (factory review) |
| v2 | any deployed v2 bytecode | no v2 contract exists on mainnet, all v2 results are source and fork rehearsal (`DeployV2Stack.fork.t.sol`) |
| ui | a v2 launch against a deployed v2 factory, the v2 quoter path, the v2 airdrop claim page, a real browser and wallet | needs the v2 deploy (ui-fixes.md) |
| docs | runbook gate 5 says no hostile recipient was built internally, but `test_swap_hostileRecipient_*` exist in `HookV2.fork.t.sol` | the gate text predates those tests. an independent review still has not run them |

## 7. what an external auditor should look at first

this is not a formal audit and nobody here has the independence of one. the list is where this team would spend the first week, ordered by how much v2 changed late and how little independent review the change has had.

| rank | area | why |
|---|---|---|
| 1 | hook swap path: stipend push and sync reset (`ArtCoinsHookV2`, D41, V2H-01) | fee legs are pushed with a zero gas call (`_PUSH_GAS` is 0; a call with 2,300 would give 4,600), so the recipient runs only on the evm's 2,300 gas stipend; it can read state and call `PoolManager.sync`, nothing else; the hook resets sync after the pushes; revert, gas burn and returndata are contained by the escrow fallback; an erc20 prepay style router that syncs before the swap must be tested before being declared supported (D60). no independent run of a hostile recipient exists. also transient skim accrual, the legs sum, and 7,860 bytes of headroom at the ci profile |
| 2 | taxed pool liquidity closure after arming (D46, `_beforeAddLiquidity`, `TaxedPoolLiquidityClosed`) | the whole VENUE and HARD tax rests on one rule: nobody adds liquidity to a taxed canonical pool after `initializeMevModule` except in the creation block, so removals can attest or grant safely. it replaced the netting fix that two reviewers broke (V2A-01, V2H-02). check unarmed pools, the launcher paths, PositionManager salts, the locker collect (remove only) and any extension that runs between placement and arming |
| 3 | HARD mode netting on the token (D24, D34, D43, `ArtCoinsTokenV2`) | the token reverts transfers touching the PoolManager or a venue unless the hook granted a same tx per direction allowance, and nets outflow against inflow grants. several flows in one tx, routers that settle gross after an opposite flow, `donate`, and erc6909 claims on side pools (accepted residual) are not independently verified |
| 4 | escrow refund path with refund address (D58, `ArtCoinsFeeEscrowV2`, `FeeDelivery`, `HookCalldata.refundTo`) | the over skim of a price limited fill is credited in the escrow to an address named in hookData, else the PoolManager caller. a universal router caller that names no address strands it (V2H-03), an exact out seller's eth delta is negative until claimed (V2H-06). check `claim`, `claimTo`, `selfClaimOnly`, core depositors that cannot be removed (D23), return bombs and gas burners |
| 5 | locker collect path against the LF-01 class (`ArtCoinsLpLockerV2`) | the live critical came from shared position manager deltas. the v2 collect opens its own unlock, refuses a foreign one, takes exact balance deltas and pushes with a 150k cap. check every path that touches position manager credit, the 14 position gas cost, and the locker with the real hook and a taxed coin |
| 6 | factory validators (`ArtCoinsFactoryV2`): referral floor (D52), min lp fee (D53), exempt allowlist (D47) | each one closed a medium the v2 pass found, none has had a second look. also the sink rule (D10), salt binding, value accounting, `setTokenDeployer` as an owner trust surface (D55), and the 19.6m gas launch at every cap (D54) |
| 7 | fee aware floors in the swapper and burn router (D39, D40, D50, D56) | `syncPoolFees()` is permissionless and copies the hook's skim config, the floor is a percentage of the fee net spot, sandwiches are bounded by the impact cap and not the floor, the same tx burn sandwich (V2B-05) is an estimate. check the refund exclusion from the floor and reward base and `maxBurnPerCall` |
| 8 | live 111 exposure (H14, FT-01, FT-05, LF-01, LF-02) | the live token, hook, locker and swapper are immutable. the exposure is the 15% buy tax on side venues, admin rate changes inside the 20% cap, and fees accrued since the last collect. the keeper narrows but does not close the window. auditors should size it and say whether the owner and token admin response is enough |
| 9 | owner trust surfaces (D20, D55, V2F-08, V2B-09) | one eoa, no timelock. the owner picks the token deployer, the escrow, the deploy fee up to 1 eth, the exempt allowlist, router thresholds and spot floor bounds. the registry compares the deployer's runtime code, nothing compares it on chain |
| 10 | tooling around launch (ui encoders, `DeployV2Lib`, `LaunchV2Coin`, mirror and ci gates) | the only tested launch path is the harness and the fork rehearsal. an auditor should replay a full launch from the final scripts on a fork and from the ui encoder output |

statement: this document is an engineering review with proof tests, written by the team that wrote v2 and by automated agents. it does not replace a formal audit, and v2 has not had one.

## 8. test totals (director fills at the end)

pin: `FORK_BLOCK` 26130269. prefix for each command: `/tmp/claude-0/forge.sh test`. fork groups skip without an rpc, so record skipped separately. the ci profile is `FOUNDRY_PROFILE=ci`. `test/v2/mocks` and `test/v2/p1/P1Base.sol` are helpers, not test groups. every v2 group needs `--skip script` and may need the harness skips shown, nothing else.

| group | command | total | pass | fail | skip |
|---|---|---|---|---|---|
| v2 harness (`test/v2/harness`) | `--match-path "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv` | 8 | 8 | 0 | 0 |
| v2 integration (`test/v2/integration`, i1, fork) | `--match-path "test/v2/integration/**" --skip script -vv`. five files: `FeeFlowV2`, `SkimRefundReferralV2`, `TaxModesV2` (2 contracts), `TreasuryMocksV2` (all `.fork.t.sol`; helpers `IntegrationV2Base.sol`, `mocks/I1Mocks.sol`) | 23 | 23 | 0 | 0 |
| v2 integration, top level (`IntegrationV2.fork.t.sol`) | `--match-path test/v2/IntegrationV2.fork.t.sol --skip script -vv` | 5 | 5 | 0 | 0 |
| v2 constants and interfaces | `--match-path test/v2/ConstantsV2.t.sol -vv` | 6 | 6 | 0 | 0 |
| v2 escrow | `--match-path test/v2/EscrowV2.t.sol -vv` | 17 | 17 | 0 | 0 |
| v2 fee delivery | `--match-path test/v2/FeeDelivery.t.sol -vv` | 13 | 13 | 0 | 0 |
| v2 mev linear skim | `--match-path test/v2/MevLinearSkimV2.t.sol -vv` | 25 | 25 | 0 | 0 |
| v2 renderers | `--match-path test/v2/RendererV2.t.sol -vv` | 23 | 23 | 0 | 0 |
| v2 extensions | `--match-path test/v2/ExtensionsV2.t.sol -vv` | 45 | 45 | 0 | 0 |
| v2 dev buy (fork) | `--match-path test/v2/DevBuyV2.fork.t.sol -vv` | 13 | 13 | 0 | 0 |
| v2 token unit (t1) | `--match-path test/v2/TokenV2.t.sol -vv` | 58 | 58 | 0 | 0 |
| v2 token fork (t1) | `--match-path test/v2/TokenV2.fork.t.sol -vv` | 5 | 5 | 0 | 0 |
| v2 hook (h1, fork) | `--match-path test/v2/HookV2.fork.t.sol -vv` | 65 | 65 | 0 | 0 |
| v2 hook regressions (p1, fork) | `--match-path test/v2/p1/P1HookRegression.fork.t.sol -vv` | 7 | 7 | 0 | 0 |
| v2 locker (l1, fork) | `--match-path test/v2/LockerV2.fork.t.sol -vv` | 25 | 25 | 0 | 0 |
| v2 swapper (p1, fork) | `--match-path test/v2/FeeAutoSwapperV2.fork.t.sol -vv` | 26 | 26 | 0 | 0 |
| v2 burn router (p1, fork) | `--match-path test/v2/BurnRouterV2.fork.t.sol -vv` | 24 | 24 | 0 | 0 |
| v2 protocol fee controller (p1) | `--match-path test/v2/ProtocolFeeControllerV2.t.sol -vv` | 15 | 15 | 0 | 0 |
| v2 factory (f1, fork) | `--match-path test/v2/FactoryV2.fork.t.sol -vv` | 34 | 34 | 0 | 0 |
| v2 keeper for 111 (fork) | `--match-path test/v2/KeeperV1_111.fork.t.sol -vv` | 8 | 8 | 0 | 0 |
| v2 generic keeper | `--match-path test/v2/KeeperV2.t.sol -vv` | 33 | 33 | 0 | 0 |
| v2 deploy script (s1, fork) | `FOUNDRY_PROFILE=ci ... --match-path test/v2/DeployV2Stack.fork.t.sol --fork-url $MAINNET_RPC_URL -vv` | 6 | 6 | 0 | 0 |
| v2 review (v1 proofs): hooks and mev | `--match-path "test/v2/review/hooks-mev/**" --skip "test/v2/harness/**" --skip script -vv` | 22 | 22 | 0 | 0 |
| v2 review (v1 proofs): factory and token | `--match-path "test/v2/review/factory-token/**" --skip "test/v2/harness/**" --skip script -vv` | 16 | 16 | 0 | 0 |
| v2 review (v1 proofs): locker and fees | `--match-path "test/v2/review/locker-fees/**" --skip "test/v2/harness/**" --skip script -vv` | 13 | 13 | 0 | 0 |
| v2 review (v1 proofs): extensions and renderers | `--match-path "test/v2/review/extensions-renderers/**" --skip "test/v2/harness/**" --skip script -vv` | 19 | 19 | 0 | 0 |
| v2 review second pass, regressions: a (token, locker, escrow) | `--match-path "test/v2/review-v2/a/**" --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv` | 4 | 4 | 0 | 0 |
| v2 review second pass, regressions: b (periphery, extensions) | `--match-path "test/v2/review-v2/b/**" --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv` | 10 | 10 | 0 | 0 |
| v2 review second pass, regressions: hook | `--match-path "test/v2/review-v2/hook/**" --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv` | 5 | 5 | 0 | 0 |
| v2 review second pass, regressions: factory | `--match-path "test/v2/review-v2/factory/**" --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv` | 5 | 5 | 0 | 0 |
| v1 skim hook fork suite | `--fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000 --match-path test/ArtCoinsHookSkimFeeForkTest.t.sol -vv` (review run: 13 of 13) | 13 | 13 | 0 | 0 |
| v1 launch rehearsal fork suite | same flags, `--match-path test/MainnetLaunchRehearsalForkTest.t.sol` (review run: 10 of 11, burn cadence floor) | 11 | 10 | 1 | 0 |
| v1 and v2 fork suites, as ci `fork-tests` | the `Run fork tests` step of `.github/workflows/test.yml`, verbatim, with `FOUNDRY_PROFILE=ci FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=50` and `--fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000`. 25 v1 suites (149 tests) plus the v2 fork suites (249 tests). the 4 failures are the known v1 state mismatches: `BurnRouterForkTest` x2, `MainnetLaunchRehearsalForkTest.test_rehearsal_s06_highSuccess_burnCadence`, `EOAPermit2SwapForkTest.test_rehearsal_s06_highSuccess_burnCadence`, all `InsufficientLayerOut`. skips: 3 v1 tests (fork state gated) | 398 | 391 | 4 | 3 |
| v1 no fork suite, as ci `check` (`Run Forge tests`) | `SKIP_FORK_TESTS=true MAINNET_RPC_URL=http://127.0.0.1:9 forge test --no-match-contract "AutoBurnOpenTab\|DeployConversionLockerAndWire" --no-match-path "test/v2/**" -vvv` under `FOUNDRY_PROFILE=ci` (66 suites; the 143 skips are fork gated tests that run in the fork job) | 708 | 565 | 0 | 143 |
| v2 unit suites, as ci `check` (`Run v2 unit suites (no fork)`) | `SKIP_FORK_TESTS=true MAINNET_RPC_URL=http://127.0.0.1:9 forge test --match-path "test/v2/**" --match-contract "^(EscrowV2Test\|FeeDeliveryTest\|TokenV2Test\|ConstantsV2Test\|MevLinearSkimV2Test\|KeeperV2Test\|ProtocolFeeControllerV2Test\|RendererV2Test\|AirdropV2Test\|VaultV2Test)$" -vvv`, 10 suites | 235 | 235 | 0 | 0 |
| review proofs, as ci `review-proofs` | the `Run review proofs` step verbatim (`--match-path "test/v2/{review,review-v2}/**"` with the fork flags), 24 suites: 70 v1 proofs plus 24 second pass regressions | 94 | 94 | 0 | 0 |
| size gate | the `Size gate` step of `test.yml` run locally (`FOUNDRY_PROFILE=ci forge build --sizes --json --skip "test/**" --skip script`, then the jq): `ArtCoinsHookV2 (src/v2/hooks/ArtCoinsHookV2.sol)` 16,716 bytes, headroom 7,860, min 1,024. forced min 99999 exits 1, missing key exits 1. all v2 contracts under 24,576 (largest `ArtCoinsDeployerV2` 21,166). see `review/sizes.md` | 1 | 1 | 0 | 0 |
| registry verify | `node script-js/verify-registry.mjs` (68 contract rows, 2 coins) and `cd script-js && npm run check:addresses` (4 of 4 ok). code, owner, state and wiring checks all ok, coins ok. 13 fail are the bytecode compare of legacy and open stack contracts against the local `foundry-out`, which this run left at the ci profile (runs 200) while those were deployed at 20,000: an artifact of the local build, not chain drift. all 9 current stack contracts with local artifacts verify. rerun after a default profile build to clear | 70 | 57 | 13 | 0 |
| ui `npm test` | `npm test` in `ui/` (`node --test test/*.test.ts`), run as is with the existing `node_modules`. build, lint, `check:abi` and `smoke` not rerun here | 51 | 51 | 0 | 0 |
| **total, v2 tree only** | one invocation, `FOUNDRY_PROFILE=ci ... forge test --match-path "test/v2/**" --fork-url ... --no-match-contract "^(<10 unit suites>)$"` (343 pass, 44 suites, 265 s) plus the 10 unit suites without a fork (235 pass). 578 = the sum of every v2 group row above | 578 | 578 | 0 | 0 |
| **total, all ci test steps** | check `Run Forge tests` + `Run v2 unit suites` + `fork-tests` + `review-proofs`. skips in `check` are fork gated tests that execute in `fork-tests`, so unique tests are fewer than 1,435 | 1435 | 1285 | 4 | 146 |

how the numbers were taken: the fork group counts are the per suite results of one invocation over the whole v2 tree (the ci fork job flags, plus the review paths), not of one invocation per group; a group command above gives the same counts for its suites. the ci rows are the exact commands extracted from `.github/workflows/test.yml` and run with the job env. date 2026-10-06, foundry 1.7.1, solc 0.8.26, fork block 26,130,269. detail and logs notes in `docs/v2/review/test-run.md`. the only failures are the 4 known v1 burn cadence mismatches and the 13 local bytecode compares in the registry row (both explained in the rows).

## 9. v2 second pass

> D73 supersedes the tax model this section reviews. The VENUE and HARD tax
> modes, venue lists, the exemption budget and the per direction grant netting
> are retired; a coin carries one launch flag `restricted`. Independent audit
> ACV2-01 (a canonical buy earned an exemption a side pool take then spent
> untaxed) is closed by that design change: there is no tax to evade. Restriction
> is fee priced, not absolute: a canonical buy and sell of X in one transaction
> grant 2X of the undirected transfer allowance and consume none, so a holder can
> move X wallet to wallet through PoolManager balance operations (settle, mint or
> transfer a claim, take, burn) or add X of coin liquidity, at the cost of the
> home pool's round trip fees; the coins produced stay restricted. The tax era
> findings below (V2A-01,
> V2H-02, the D24/D34/D46 residuals, V2A-03, the t1-notes grant and budget rows)
> describe code that no longer exists; they are kept as the record of why the
> model changed.

four independent reviews of the finished v2 packages, by reviewers who did not write the code: `v2-review-a.md` (token, deployer, locker, escrow, delivery, mev module, keepers), `v2-review-b.md` (swapper, burn router, controller, extensions, renderers), `v2-review-hook.md` (hook and its token, locker, escrow interplay), `v2-review-factory.md` (factory, deployer, launch flow). fixes came from the package authors afterwards (h1, p1, t1, f1, k1) under D41 to D59. the reviewers' proof files are in `test/v2/review-v2/{a,b,hook,factory}`; they passed while the bugs existed, the director has flipped them to regressions, and h1-notes records which ones now revert in `setUp` (`TaxedPoolLiquidityClosed` for a and hook, `LpFeeBelowMinimum` for the factory test). this document did not re run them. the second pass itself is one pass: the fixes were not re reviewed by anyone but their authors.

### 9.1 counts by severity

| review | high | medium | low | info | total | proof file, tests at review time |
|---|---|---|---|---|---|---|
| a: token, locker, escrow, mev, keepers | 1 | 1 | 3 | 5 | 10 | `review-v2/a/V2A_TaxBypass.t.sol`, 4 (local v4) |
| b: periphery, extensions, renderers | 0 | 2 | 3 | 4 | 9 | `review-v2/b/*`, 10 (fork) |
| hook | 1 | 1 | 4 | 4 | 10 | `review-v2/hook/HookV2Review.fork.t.sol`, 5 (V2H-01 trace only, by choice) |
| factory | 0 | 1 | 3 | 5 | 9 | `review-v2/factory/V2FFactoryReview.fork.t.sol`, 5 |
| total | 2 | 5 | 13 | 18 | 38 | |

### 9.2 findings and status

review a (`v2-review-a.md`)

| id | sev | title | status in v2 | decision, package, regression |
|---|---|---|---|---|
| V2A-01 | high | canonical liquidity round trips mint usable HARD grants and VENUE budget (a grant spent before the opposite report lands is never netted) | fixed | D46 (not the reviewer's direction lock: remove, side buy, take as erc20, mint own principal as claims needs no re add), h1 + t1. `test_V2A01_venue_removeThenReadd_reverts`, `test_V2A01_venue_removalLeavesNoBudget`, `test_V2A01_hard_increaseThenDecrease_reverts`, `test_tax_thirdPartyAdd_reverts` (HookV2.fork), `test_hard_canonicalLpRemove_noGrant_reverts` (TokenV2) |
| V2A-02 | medium | exempt set accepts any contract, so a deployer exempts its own forwarder (FT-07 not fixed) | fixed | D47 exempt allowlist on the factory, f1 + t1. `test_exemptAllowlist` (FactoryV2.fork). the token keeps its contracts only rule as defense in depth |
| V2A-03 | low | HARD: listing a v2 pair after third parties added lp also freezes their counter asset | accepted | t1 notes, no decision id: a list only empty pools rule is griefable with a dust transfer. the launch ui and token docs must say "listing a pool traps its lps' paired asset" (not yet in the ui) |
| V2A-04 | low | venue admin not moved by `updateAdmin`, no transfer path | fixed | D48, t1. `test_venue_transferVenueAdmin`, `test_venue_transferVenueAdmin_noneModeReverts` |
| V2A-05 | low | keeper step gas is a hard ceiling, a large collect reverts `InsufficientGas` forever | fixed | D49, k1. `test_keeperV2_stepsBeyondOldCaps_stillRun`, `test_keeperV2_gasSweep_neverSilentlySkips` |
| V2A-06 | info | escrow wiring not enforced in code (hook constructor skips the core depositor check) | accepted | D36: deploy order rule, the deploy script asserts it. `test_deployV2Stack_wiringComplete` |
| V2A-07 | info | locker storage default `keeperRewardBps` is 50, D28 says 0 | fixed (D65) | the storage default is 0 in source. regression `test_lockerV2_keeperRewardBps_defaultsToZero`. the deploy wiring and gate 12 still set and read it back |
| V2A-08 | info | escrow `storeFees` is `nonReentrant`, a collect from inside a claim callback reverts | accepted | self affecting, nothing lost (reviewer note). no decision id |
| V2A-09 | info | grants and budget are per tx, not per caller (erc4337 bundles) | accepted | t1 notes, D12: per caller binding is impossible in v4, bounded by the net canonical flow of the tx |
| V2A-10 | info | keepers read any empty revert as out of gas | fixed | D49 follow up, k1: `gasleft()` after the call decides. `test_keeperV1_collectRevert_bubbles`, `test_keeperV2_flushAndConvertRevert_areReported_notSilent` |

review b (`v2-review-b.md`)

| id | sev | title | status in v2 | decision, package, regression |
|---|---|---|---|---|
| V2B-01 | medium | burn router floor and reward count the hook's refundable skim, a balance above a few times the per block fill never burns, eth unrescuable | fixed | D40 + D50, p1: refund excluded from floor and reward base, `maxBurnPerCall`. `test_burnV2_skimPool_50eth_burnsEveryBlock_drains`, `test_burnV2_skimPool_300eth_burns`, `test_burnV2_maxBurnPerCall_capsBudget_andBounds`. the router still cannot rescue eth or coin |
| V2B-02 | medium | swapper convert is sandwichable by its own caller on low fee pools | fixed (bounded) | D39 + D50, accepted residual D56: impact cap (default 100 bps), one convert per block, fee aware floor. `test_swapperV2_sandwich_boundedByImpactCap`, `test_swapperV2_feeAwareFloor_chargesBeyondKnownFees`. loss per call is bounded, not zero |
| V2B-03 | low | burn router reward and `Burned.ethIn` include refunded skim | fixed | D40, p1. `test_burnV2_skimPool_partialFill_netOfRefund` |
| V2B-04 | low | ui claim page cannot claim v2 airdrops (v1 abi, no `index`) | open | `ClaimPage` still speaks the v1 abi (inert, no airdrop configured). must be done before any v2 airdrop launches (ui-fixes.md) |
| V2B-05 | low | same tx sandwich of `processBurn`, bounded by `maxImpactBps` | accepted | D39 (impact 25 to 300 bps). profitability is an estimate only, listed unverified in runbook gate 6 |
| V2B-06 | info | controller `processFees(token)` is permissionless for any erc20, a false returning token writes junk escrow credits | fixed (D68) | `FeeDelivery.sendErc20` reverts with `InvalidTransferReturn` when `transfer` returns false or malformed returndata, so the amount stays with the caller. regressions `test_delivery_erc20_falseReturn_reverts_noCredit`, `test_pfcV2_processFees_falseReturningToken_reverts_noCredit`, `test_delivery_erc20_shortReturn_reverts`, `test_delivery_erc20_noCodeToken_reverts` |
| V2B-07 | info | swapper and controller push fallback needs depositor status, nothing on chain checks it | mitigated | D33, D36: runbook 2b steps 1 and 6 (`escrow.isDepositor(feeSwapper)`) |
| V2B-08 | info | dev buy escrow credit shared across launches | fixed (D68) | the dev buy opts into `selfClaimOnly`, claims a nonzero credit to itself each launch (a failed claim reverts the launch), refunds its whole eth balance, and holds zero eth and zero credit in the current escrow after each launch. regressions `test_V2B08_devBuy_refundCreditIsPerLaunch`, `test_V2B08_devBuy_seededCreditClaimedInFull`, `test_V2B08_devBuy_thirdPartyCannotClaim`, `test_V2B08_devBuy_fullFillNoClaim`, `test_V2B08_devBuy_claimFailureRevertsLaunch`, `test_V2B08_devBuy_nonEscrowSenderDuringClaimReverts`, `test_V2B08_devBuy_directEthReverts` |
| V2B-09 | info | owner levers without upper bound (router threshold, controller `rescue`, router `initialize` key check) | accepted | owner trust, DESIGN section 2, D20 (single eoa) |

review hook (`v2-review-hook.md`)

| id | sev | title | status in v2 | decision, package, regression |
|---|---|---|---|---|
| V2H-01 | high | frozen recipients run their own code inside the victim's unlocked PoolManager (revert chosen swaps, take VENUE buyers' coin as tax, front run) | fixed | D41 (+ D59), h1: stipend only pushes, probe removed, a native `sync` by a recipient is undone. `test_swap_hostileRecipient_cannotRevertSwap`, `test_swap_hostileRecipient_cannotSpendBuyerExemption`, `test_swap_noStreamProbe`. the reviewer wrote no hostile contract. residual: stipend and sync prepay note (9.4) |
| V2H-02 | medium | HARD: add then remove (or increase then decrease) in one unlock leaves a free in grant | fixed | D43 first, then D46 (no adds after arming), h1. `test_V2A01_hard_increaseThenDecrease_reverts`, `test_tax_thirdPartyAdd_reverts`. h1-notes: D34 never closed it, the reviewer was right |
| V2H-03 | low | partial fill refund goes to the PoolManager caller, stranded for the universal router | fixed | D58, h1: refund address in hookData (`mevModuleSwapData = abi.encode(address)`), else the caller. `test_skim_refundTo_fromHookData`, `test_calldata_refundTo`. the default is still the caller, a router that cannot claim must name an address |
| V2H-04 | low | H13 fix blocks only direct callers, a router user names its own wallet | accepted | D44, bounded by the frozen cap (max 1% of volume) and the D52 floor |
| V2H-05 | low | referral and event volume base depends on swap shape | fixed | h1: volume is the realized pool side amount for all four shapes. `test_skim_quoteUnspecified_realized` |
| V2H-06 | low | price limited exact out sell can leave the seller owing eth at the PoolManager | open | h1-notes: documented, not fixed. D58: the refund rides the escrow, so the seller's eth delta is negative until it is claimed. routers that only expect to take eth revert |
| V2H-07 | info | hook constructor does not check the escrow lists it as core depositor | open | h1-notes: the escrow needs the hook address first. D36: the deploy script asserts the order (`test_deployV2Stack_wiringComplete`) |
| V2H-08 | info | recipients that can never claim are accepted (hook, PoolManager, escrow as bounty or protocol recipient) | fixed (hook, PoolManager) | h1: `RecipientCannotReceive`. left: the escrow address is mutable and not checked |
| V2H-09 | info | the hook takes the skim before the trader settles, needs eth already in the PoolManager | accepted | mainnet only (D17 eth pairs), note for other chains. no decision id |
| V2H-10 | info | owner can point failed push credits at any contract answering `constantsHash` and `isCoreDepositor` | accepted | D7, D20 owner trust. `test_owner_setFeeEscrow_checksConstantsAndDepositor` |

review factory (`v2-review-factory.md`)

| id | sev | title | status in v2 | decision, package, regression |
|---|---|---|---|---|
| V2F-01 | medium | `minProtocolSkimShareBps` is not a floor, the referral cap can take the whole protocol leg | fixed | D52, h1 + f1: hook pays referral from `protocolLeg - protocolFloor`, factory validates the cap against the floor, deploy script sets 1,000. `test_referral_neverBelowProtocolFloor` (HookV2.fork), `test_referralCap_protocolFloor_boundary` (FactoryV2.fork) |
| V2F-02 | low | `lpFee` has no floor, the protocol locker slot can be worth nothing | fixed | D53, f1: `minLpFee` default 3,000 pips. `test_minLpFee_boundaryAndSetter` |
| V2F-03 | low | an accepted config can exceed the EIP-7825 per tx gas cap (19.6m at every cap) | accepted | D54: only the launcher is affected, the ui keeps configs far below, runbook gate 7 rehearses the real config |
| V2F-04 | low | `isArtCoin` no longer implies `ArtCoinsTokenV2` code, the owner can repoint the deployer | accepted | D55: owner trust, the registry records the deployer and the verifier compares its runtime code. `test_tokenDeployer_setAndRequired` |
| V2F-05 | info | factory comment says rounding dust goes to the pool, the locker sends it to DEAD | open | comment not rechecked (no package note) |
| V2F-06 | info | launcher chosen code runs inside the launch tx before the module arms (dev buy refund) | open | documented, order kept for v1 parity. launcher's own tx |
| V2F-07 | info | factory accepts reward recipients that can never be paid (factory, coin) | fixed (D68) | the factory reverts `RecipientCannotReceive` for a reward recipient equal to the factory, the coin, the PoolManager, the launch's hook, locker, fee escrows, token deployer or mev module, or an extension in the config. regressions `test_launch_rewardRecipientCannotReceive_reverts`, `test_launch_rewardRecipientIsCoin_reverts`. the hook half is V2H-08 |
| V2F-08 | info | owner can reprice a pending launch (`setDeployFee` up to 1 eth) | accepted | D20 owner trust. the ui sends the exact fee and re reads it before signing (UI-04). an additive `deployTokenWithMaxFee` was not added |
| V2F-09 | info | no maximum supply | open | no package note |

### 9.3 medium and above, with the fix

| id | sev | fix | where | decisions |
|---|---|---|---|---|
| V2A-01 | high | taxed pools (VENUE, HARD) accept liquidity only from launchers before arming and in the creation block, removals never attest or grant, the same tx marker is removed | hook `_beforeAddLiquidity`, `TaxedPoolLiquidityClosed`. token reports swaps only | D46 (D34, D43 were the interim) |
| V2A-02 | medium | the factory takes `tax.exempt` entries only from an owner managed `exemptAllowlist` or the launch's own locker, hook, enabled escrow and extensions, all with code (also closes 7702 delegated eoas) | factory `setExemptAllowed`, `_checkCanonical` | D47 |
| V2B-01 | medium | the hook's skim refund credited during a burn is excluded from the floor and the reward base, `maxBurnPerCall` (default 5 eth) drains a large balance over blocks, floor is fee aware | `BurnRouterV2` | D40, D50 |
| V2B-02 | medium | `convert` gets an impact cap (default 100 bps, 25 to 300), one per block, `maxStepIn`, a 95% default floor of the fee net spot, `syncPoolFees()` | `FeeAutoSwapperV2` | D39, D50, D56 |
| V2H-01 | high | recipient code confined to the 2,300 stipend during a swap (D60 wording): legs are pushed with a zero gas call so the callee can only read state and call `PoolManager.sync`, escrow on failure, no `streamForward` probe, referral pushed straight to the referrer, a recipient's native `sync` is reset after the pushes | hook `_leg`, `_split`, `_afterSwap` | D41, D59 |
| V2H-02 | medium | same rule as V2A-01. HARD removals no longer exist after arming | hook, token | D43, D46 |
| V2F-01 | medium | referral can never take the protocol leg below `minProtocolShareBps` of the skim, the factory validates `maxReferralBpsOfVolume` against the floor, the deploy script sets 1,000 | hook `_split`, factory `_validateFee`, `DeployV2Lib` | D52 |

### 9.4 still open residuals

listed by the reviewers and by the package authors. none of these is hidden by a status above.

| source | residual | why it stays |
|---|---|---|
| h1 notes | stipend and sync prepay: a 2,300 gas recipient can read state and call `PoolManager.sync`, nothing else. the hook resets sync after the pushes; an erc20 prepay style router that syncs before the swap must be tested before being declared supported (D60) | HARD forbids prepay and v4 routers sync right before settle. no hostile recipient run by an independent reviewer (gate 5) |
| h1 notes | unarmed taxed pool: if a launcher never calls `initializeMevModule`, adds stay possible in the creation block | the factory always arms in the launch tx |
| h1 notes | owner enabled extensions run between placement and arming | allowlisted code, no third party code runs in that window |
| t1 notes | HARD: erc6909 coin claims can circulate on side pools inside the PoolManager | D24, cannot exit as erc20 |
| t1 notes | HARD: an unused out grant from a canonical buy settled as claims can cover a side pool take later in the same tx | per tx binding (D12), exits stay bounded by net canonical flow |
| t1 notes | HARD: a router that settles and takes the same coin gross after opposite canonical flows in one unlock reverts. prepay style settle reverts | D34 leaves only the net allowance. not verified against every router (gate 6) |
| t1 notes | HARD: listing a venue freezes the coin inside it and, for a v2 pair, the lps' counter asset (V2A-03) | by design, venue admin is the deployer's choice, docs must say it |
| t1 notes | V2A-09 grants per tx not per caller, FT-05 image and metadata stay admin mutable | D12, DESIGN section 2 |
| V2H-06 | exact out seller's eth delta is negative until the escrow refund is claimed | D58, documented only |
| V2H-07 | hook constructor cannot check the escrow | D36 deploy script assert |
| V2H-03, D58 | the default refund address is the PoolManager caller, a universal router must name another | hookData is optional by design |
| D44 | router self referral is accepted, bounded by the frozen cap and the D52 floor | not worth the ux cost of a signed referrer |
| D55 and owner trust (D20, V2F-04, V2F-08, V2B-09, V2H-10) | one eoa, no timelock: it can replace the token deployer (a different token ships under `isArtCoin`), set the deploy fee up to 1 eth, repoint the escrow, manage the exempt allowlist, disable burns with `minProcessThreshold`, `rescue` anything in the controller | principle 2 and D38, the registry compares the deployer's runtime code, nothing enforces it on chain |
| D54, D56 | a launch at every cap costs about 19.6m gas, above the 16.7m cap. the fee aware floor catches charges beyond known fees above about 5% only, sandwiches are bounded by the impact cap | accepted |
| V2B-04, V2F-05, V2F-06, V2F-09 | open info and low items with no package fix (9.2) | no owner, not blocking |
| runbook gates 5, 6 | independently unverified: V2H-01 end to end, a nested swap from a recipient, partial fill refunds through a live universal router, the HARD `donate` path, D34 netting with several flows, the locker with the real hook and a taxed coin end to end, V2B-05 profit | listed in section 6 |

this second pass and its fixes are an engineering review. they are not a formal audit and v2 has not had one.
