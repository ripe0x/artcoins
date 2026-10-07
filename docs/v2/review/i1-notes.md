# i1 notes: v2 end to end integration suite

files: `test/v2/IntegrationV2.fork.t.sol`, `test/v2/integration/IntegrationV2Base.sol`, `test/v2/integration/TreasuryMocksV2.fork.t.sol`, `test/v2/integration/TaxModesV2.fork.t.sol`, `test/v2/integration/FeeFlowV2.fork.t.sol`, `test/v2/integration/SkimRefundReferralV2.fork.t.sol`, `test/v2/integration/mocks/I1Mocks.sol`.

every test forks mainnet at the harness pin (26,130,269), deploys the stack with `ForkStack.deployV2Stack()` (the deploy script's own routine, owner = broadcaster = the live owner eoa, factory deprecated), and launches through the real factory, hook, locker, mev module, swapper, controller, burn router and keeper on the live PoolManager. no broadcasts.

run (forge rejects two `--match-path` flags, so one brace glob):

```
/tmp/claude-0/forge.sh test --match-path "test/v2/{integration/**,IntegrationV2*}" \
  --skip "test/v2/review/**" --skip "test/v2/review-v2/**" -vv
```

result on the current tree: 28 tests, 28 pass, 0 fail. partial fill tests follow D58; no BUG markers remain. no src file needed a `--skip`.

## coverage

| # | test | what it proves |
|---|---|---|
| 1 | `test_i1_ownerLaunchWhileDeprecated_thenOpen_strangerLaunch_bothPoolsSwap` | stranger refused while deprecated; owner launches the credits engine coin (treasury mock = bounty, sink, slot); `setDeprecated(false)`; stranger launches with `deployToken` paying exactly 0.069 eth to the team recipient; both pools buy and sell; bounty pushed to the treasury, protocol to the controller |
| 2a | `test_i1_treasury_noCode_eoa_pushLands` | eoa with 5 eth (v1 brick) gets every push |
| 2b | `test_i1_treasury_emptyPayableFallback_pushLands` | empty payable fallback gets every push |
| 2c | `test_i1_treasury_revertingFallback_escrowed_thenClaimTo` | legs escrowed; third party `claim` reverts and keeps the balance; `claimTo` by the treasury delivers |
| 2d | `test_i1_treasury_gasBurner_escrowed_swapGasBounded` | escrowed; warm buy costs under eoa reference + 30k |
| 2e | `test_i1_treasury_takeFromPoolManager_failsInStipend_escrowed` | eth take and coin take from `receive` both die inside 2,300 gas; swap settles; leg escrowed; no claim minted; locker push (PoolManager locked) escrowed |
| 2f | `test_i1_treasury_proxyColdSload_escrowed_claimRunsLogic` | eip-1967 proxy: escrowed; stranger `claim` runs the logic's accounting with full gas; locker push (150k) lands |
| 2g | `test_i1_treasury_accountingOverStipend_escrowed_thenAnyoneClaims` | sstore receive: escrowed; stranger `claim` delivers; locker push lands and runs the accounting |
| 2h | `test_i1_treasury_v1StreamForward_neverCalled` | `vm.expectCall(..., 0)` on `streamForward` across swaps and a keeper run |
| 3 | `test_i1_venue_canonicalUntaxed_sidePoolTaxed_v3VenueTaxed_thirdPartyAddClosed` | VENUE at 10%: canonical buy and sell untaxed; canonical third party add reverts `TaxedPoolLiquidityClosed`; hookless side v4 buy taxed to the sink; derived v3 venue listed, created on the real v3 factory, buy taxed to the sink |
| 3 | `test_i1_hard_canonicalPasses_sidePoolTakeAndSettleRevert_venueTransferReverts` | HARD: canonical buy and sell pass, grants consumed exactly; prepaid settle, side pool lp settle, side pool sell settle, side pool take all revert `CanonicalFlowRequired`; listed v3 venue transfer reverts `VenueTransferBlocked`; D24 residual shown (side pool seeded and bought as erc6909 claims only) |
| 3 | `test_i1_hard_lockerCollect_feeSwapperConvert_burnRouterBurn_pass` | HARD: locker collect, swapper convert, burn router burn and the keeper path all pass |
| 4 | `test_i1_feeFlow_keeperCollectFlushConvert_controllerSplit_burn_everyWeiAccounted` | four phases, each balanced to the wei from the contracts' own events, plus the total: recipient deltas + escrow credits + eth burned == skim legs + refunds + lp eth + convert proceeds. coin side balanced too. keeper rewards (locker 1%, swapper 0.5%, burn 0.5%) paid; second burn in a block reverts |
| 5 | `test_i1_antiSniper_skimDecaysLinearlyToBaseline` | charged skim equals the module's linear schedule at 0, 1/4, 1/2, 3/4, end-1, end, end+1h; add lock closed in the window, open after |
| 5 | `test_i1_antiSniper_moduleTreatedAsExpiredAfterMaxWindow` | factory enabled module that reports active forever: trusted until `createdAt + MAX_MEV_WINDOW`, baseline skim and open lp from then on |
| 6 | `test_i1_partialFill_{exactInBuy,exactOutSell}_{poolSwapTest,deltaRouter}_refundToNamed` | D58, price limited: the swapper pays the full charge in the swap, `SkimRefunded` and the escrow credit `charged - fair` to the refund address named in hookData, nothing under the router, a stranger's `escrow.claim(refundTo, 0)` delivers it, net of it the swapper paid realized + fair (buy) or received realized - fair (sell); returned delta == transient delta; hook holds no eth or claims |
| 6 | `test_i1_partialFill_universalRouter_noRefundAddress_creditedToRouter_V2H03` | live universal router, both shapes, no refund address: the refund is credited to the router in the escrow and is stranded (V2H-03, documented); the user paid realized + full charge |
| 6 | `test_i1_partialFill_universalRouter_withRefundAddress_nothingStranded` | same swaps with a refund address: nothing under the router, D58 holds for both shapes, escrow empty after the claims |
| 6 | `test_i1_partialFill_netOfClaimableRefund_isFair_bothShapesBothRouters` | D58 default recipients: with no refund address the PoolManager caller is credited and a permissionless claim makes a currencyDelta router whole; net of the claimable refund every shape and router paid realized +/- fair skim |
| 7 | `test_i1_referral_paysReferrer_protocolNeverBelowFloor` | launch with cap above the D52 bound refused; at the bound, referral = min(cap, protocol - floor), protocol >= floor, carved from the protocol leg only; eoa referrer pushed, rejecting referrer escrowed and pulled with `claimTo`; payout pointer = escrow (D57) |
| 7 | `test_i1_referral_protocolFloorFrozenIntoHook` | `hook.minProtocolShareBps(pid) == factory.minProtocolSkimShareBps()` |
| 8 | `test_i1_versionAndDiscovery_launchEventDecodesToConfigHash` | `poolInfo(pid).version == 2` and every field, `isOfficialPool`, `isArtCoin`, `launcherVersion() == 2`, `deploymentInfo`, `predictToken`; one `TokenCreatedV2` whose topics match and whose decoded config hashes to the event's and the factory's `configHash` |
| 9 | `test_i1_ownerSetters_cannotChangePerCoinFields` | every owner setter on factory, hook, locker, escrow, controller, burn router and the coin's swapper, at extreme values; one hash over hook pool info, skim config, floor, locker record, mev schedule, lp fee, token tax fields, swapper binding, factory record is unchanged; swaps still pay the frozen recipients at the frozen rates; locker still pays the frozen slots |
| 9 | `test_i1_rescue_cannotTouchOwedBalances` | escrow rescue limited to stray eth above `totalOwed`; hook and locker hold nothing (rescue has nothing to take, position nfts forbidden); swapper and burn router refuse eth and the coin; the owed balance still pays its owner |
| 10 | `test_i1_gasTable` | numbers below |

## bugs and gaps found

| pkg | finding | test |
|---|---|---|
| h1 | D42/D51 (refund inside the swap) are superseded by D58: v4 cannot refund eth in the swap, the over charge is credited in the escrow to the hookData refund address, else the PoolManager caller. the partial fill tests are written to D58 and carry no BUG marker. residual V2H-03: a universal router swap with no refund address strands the refund under the router; the mitigation is the refund address (ui and integrators must pass it). residual V2H-06: an exact out seller whose fill is below the charge owes eth until the claim | `test_i1_partialFill_*` (7) |
| f1 | fixed during this run: the factory now passes `minProtocolSkimShareBps` into `PoolInitParams.minProtocolShareBps` (was a `TODO(D52)`) | `test_i1_referral_protocolFloorFrozenIntoHook` passes |

## notes for integrators and the director

| item | note |
|---|---|
| D57 wording | the referral leg is pushed straight to the referrer with the stipend (D41); it reaches the escrow only when that push fails. `referralPayout` (= escrow) is stored but never called during a swap |
| forge and transient storage | one test function is one transaction, so a grant left by one call (a HARD buy taken as claims) is still live for later calls in the same test. the HARD side pool test seeds in `setUp` (its own transaction). verified with a throwaway probe |
| via-ir and `block.timestamp` | reads of `block.timestamp` and `block.number` get reordered past `vm.warp` and `vm.roll`; the suite uses `vm.getBlockTimestamp()` and `vm.getBlockNumber()` |
| v2h-06 | an exact out sell whose fill is smaller than the charged skim leaves the seller owing eth until the refund is claimed (D58); the universal router then reverts at TAKE_ALL. the tests size requests so the fill exceeds the charge |
| stray mainnet eth | test contracts deploy at the same CREATE addresses on every fork; the PoolSwapTest address holds a little mainnet eth and forwards it to the caller on its first swap. balance based eth accounting must include it |
| run command | the brief's command passes `--match-path` twice; forge 1.7.1 rejects that. use the brace glob above |

## gas table

measured in `test_i1_gasTable` with every touched contract marked cold (`vm.cool`) before each call; excludes the 21k base and calldata; router overhead of `PoolSwapTest` included in buy and sell.

| action | gas |
|---|---|
| launch (`deployTokenAsOwner`, 3 positions, 2 slots, VENUE) | 4,971,062 |
| buy 0.1 eth exact in | 142,415 |
| sell exact in | 161,249 |
| `locker.collectRewards` (3 positions, 2 slots) | 326,627 |
| `swapper.convert` | 184,930 |
| `burnRouter.processBurn` | 243,611 |

## fee flow sample (test 4, wei)

| item | wei |
|---|---|
| skim legs and refunds (trades, convert, burn) | 1,485,595,124,932,658,972 |
| lp eth collected | 70,499,999,999,999,999 |
| convert proceeds | 25,065,779,052,791,033 |
| fees taken (sum) | 1,581,160,903,985,450,004 |
| held by recipients and escrow | 1,555,156,816,348,497,921 |
| eth burned (router paid into the pool) | 26,004,087,636,952,083 |
| difference | 0 |
