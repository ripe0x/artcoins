# v2 test run record

date 2026-10-06 (utc 05:30 to 07:15). foundry 1.7.1, solc 0.8.26 native. pinned fork block 26,130,269 (`ForkBase.FORK_BLOCK`), rpc: tenderly public gateway. all commands go through the serializing wrapper `/tmp/claude-0/forge.sh`. the integration agent's files (`test/v2/integration/**`, `test/v2/IntegrationV2*`) were not touched, run or formatted.

## commands and results

| # | command | result |
|---|---|---|
| 1 | `forge.sh fmt <every .sol under src test script except the integration files>` then `forge.sh fmt --check <same list>` | rc 0. formatted 8 files in src/ and script/ (whitespace only, no logic) and 15 test files. `fmt --check src test script` as ci runs it still reports only the 7 integration files (not mine) |
| 2 | `forge.sh test --match-path "test/v2/review-v2/**" --skip "test/v2/integration/**" --skip "test/v2/IntegrationV2*" -vv` | before flipping: 13 pass, 8 fail. after: **24 pass, 0 fail, 0 skip** (9 suites). the suites fork in their own setUp at the pinned block |
| 3 | `forge.sh test --match-path "test/v2/review/**" --skip "test/v2/integration/**" --skip "test/v2/IntegrationV2*" -vv` | **70 pass, 0 fail, 0 skip** (15 suites). unchanged, v1 proofs still demonstrate the v1 bugs |
| 4a | `FOUNDRY_PROFILE=ci SKIP_FORK_TESTS=true MAINNET_RPC_URL=http://127.0.0.1:9 forge.sh test --no-match-contract "AutoBurnOpenTab\|DeployConversionLockerAndWire" --skip "test/v2/**" --skip script -vvv` (ci sets profile ci) | **565 pass, 0 fail, 143 skip** (66 suites). matches the earlier record in hygiene-fixes.md |
| 4b | fork job, copied from `.github/workflows/test.yml` with `FOUNDRY_PROFILE=ci FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=50`, `--fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000 -vvv`, the same `--match-path`, `--no-match-path "test/v2/{review,review-v2}/**"`, `--no-match-contract` lists, plus `--skip "test/v2/integration/**" --skip "test/v2/IntegrationV2*"` | **589 pass, 13 fail, 3 skip** (49 suites, 179 s). see failures below |
| 4c | the three failing v2 unit files without a fork: `FOUNDRY_PROFILE=ci forge.sh test --match-path "test/v2/{EscrowV2.t.sol,FeeDelivery.t.sol,TokenV2.t.sol}" -vv` | 88 pass, 0 fail |
| 5 | `FOUNDRY_PROFILE=ci forge.sh build --sizes --skip "test/**" --skip script` (and `--json`) | ok. table in `docs/v2/review/sizes.md`. hook 16,716 bytes, headroom 7,860 (gate 1,024). largest v2 contract ArtCoinsDeployerV2 21,166 (limit 24,576) |

## fork job failures (13)

4 are the known v1 state mismatches (hygiene-fixes.md), expected:

| test | failure |
|---|---|
| `BurnRouterForkTest.test_fork_processBurnWeth_keeperRewardCapped` | `InsufficientLayerOut` (out 0.4975 vs floor 7.992) |
| `BurnRouterForkTest.test_fork_processBurnWeth_paysKeeperReward` | `InsufficientLayerOut` (0.4975 vs 0.796) |
| `MainnetLaunchRehearsalForkTest.test_rehearsal_s06_highSuccess_burnCadence` | `InsufficientLayerOut` (1.04e24 vs 1.33e24) |
| `EOAPermit2SwapForkTest.test_rehearsal_s06_highSuccess_burnCadence` | `InsufficientLayerOut` (same) |

9 are new and NOT expected. all three files are plain unit suites (no fork logic) that pass without a fork (run 4c) and fail only because the ci fork job matches `test/v2/**` under a global `--fork-url`:

| test | failure |
|---|---|
| `EscrowV2Test.testFuzz_escrowV2_owedInvariant` | assertion 585534147768897 != 8512599715725 |
| `EscrowV2Test.test_escrowV2_claim_permissionlessPush` | 0 != 1e18 |
| `EscrowV2Test.test_escrowV2_rescue_boundedByTotalOwed` | expected revert did not happen |
| `EscrowV2Test.test_escrowV2_rescue_nothingStray_reverts` | expected revert did not happen |
| `EscrowV2Test.test_escrowV2_selfClaimOnly_ownerCanClaimItself` | 0 != 1e18 |
| `FeeDeliveryTest.test_delivery_eoa_pushed` | 0 != 1e18 |
| `FeeDeliveryTest.test_delivery_reverting_escrowed` | 1.000577e18 != 1e18 (live eth at a collided address) |
| `TokenV2Test.test_exempt_capAndContractsOnly` | expected revert did not happen |
| `TokenV2Test.test_renderer_rules` | expected revert did not happen |

cause not pinned down beyond "mainnet state replaces the empty local state" (same class as the polluted suites in hygiene-fixes.md; the makeAddr addresses themselves have no code or balance at the block). fix options for the director: add `EscrowV2Test|FeeDeliveryTest|TokenV2Test` to the fork job's `--no-match-contract`, or run them in the no fork job (that job skips all of `test/v2/**`, so these unit suites currently run nowhere in ci without a fork).

## review proof flips (command 2)

| file | test | before | now |
|---|---|---|---|
| `review-v2/a/V2A_TaxBypass.t.sol` | `V2A01HardTest` x2 | setUp reverted `TaxedPoolLiquidityClosed` | setUp places launch liquidity and a parked position before arming, then asserts the post arming add reverts. both tests assert the attack unlock reverts `TaxedPoolLiquidityClosed` and nothing moved |
| same | `V2A01VenueTest` | same | same shape, plus the plain side pool buy is still taxed 15% |
| same | `V2A02ExemptTest` | passes | unchanged, token scope only. the fix is the factory allowlist (D47), regression in `test/v2/FactoryV2.fork.t.sol` |
| `review-v2/hook/HookV2Review.fork.t.sol` | `RvHardNettingTest` x2 (V2H-02) | setUp reverted | prior position placed in the launch phase, setUp asserts the post arming add reverts, tests assert the add reverts and no grant is minted |
| same | `RvVenueNettingTest` x2 (holds) | setUp reverted | kept. `removeThenReAdd` now asserts the re add reverts as a whole, `claimsBuyThenSell` unchanged |
| same | `RvGasTest` | passes | unchanged |
| `review-v2/b/V2BPeriphery.fork.t.sol` | `test_V2B01_burnRouter_bigBudgetNeverBurns_defaultSettings` | failed (refund assumed in escrow) | 10 eth burns, reward on consumed eth only, 50 eth burns every block, donation does not brick, eth still unrescuable (D40) |
| same | `test_V2B01_burnRouter_bricked_evenAtOwnerLimits` | failed | 300 eth burns at default and at the owner limits |
| same | `test_V2B02_swapper_sandwich_profitable_lowFeePool` | failed | attacker profit bounded by impact cap plus fees and not positive at the default cap (D39) |
| same | `test_holds_*` x5 | pass | unchanged |
| `review-v2/factory/V2FFactoryReview.fork.t.sol` | `test_V2F01_referralCapZeroesProtocolSkimFloor` | failed `LpFeeBelowMinimum` | asserts `LpFeeBelowMinimum` (D53), `ReferralCapAboveProtocolFloor` at the old attack config and at cap 301, then a cap 300 launch where a referred swap leaves the protocol leg at or above the floor (D52) and the locker protocol slot earns |
| same | `test_V2F03_maxConfigLaunch_overTxGasCap`, gas tests, `test_holds_*` | pass | unchanged. V2F-03 is accepted by D54, so the proof stays as is with a comment |
| `review-v2/b/V2BExtensions.t.sol` | 2 holds | pass | unchanged |

nothing could not be flipped. every flipped test keeps the original attack narrative and finding id in a comment above it.

## other findings

| item | note |
|---|---|
| ci size gate is a no op | the legacy hook has the same contract name, so forge's json key is `ArtCoinsHookV2 (src/v2/hooks/ArtCoinsHookV2.sol)` and `has("ArtCoinsHookV2")` is false. details in sizes.md |
| fmt not idempotent | `HookV2Mocks.sol` had a ternary assigned to `lim` that `forge fmt` kept rewriting in two shapes. replaced by an if/else |
| fmt touched src and script | task 1 required `fmt --check src test script` to pass; the 5 src files and 3 script files were whitespace only |

## update 2026-10-06 (utc 08:00 to 10:00): integration fmt, ci split, size gate, totals

all commands through `/tmp/claude-0/forge.sh`. profile `ci` unless noted. fork url `https://mainnet.gateway.tenderly.co` (answers, chain id 1), block 26,130,269, retries 8, backoff 2000. invariants `FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=50` on every fork run.

### commands and counts

| # | command | result |
|---|---|---|
| 1 | `forge.sh fmt test/v2/integration test/v2/IntegrationV2.fork.t.sol`, then `forge.sh fmt --check src test script` | formatted the 7 integration files (whitespace). `fmt --check src test script` rc 0 |
| 2 | existence check of the ten unit contract names, `SKIP_FORK_TESTS=true MAINNET_RPC_URL=http://127.0.0.1:9 forge.sh test --match-path "test/v2/**" --match-contract "^(EscrowV2Test\|FeeDeliveryTest\|TokenV2Test\|ConstantsV2Test\|MevLinearSkimV2Test\|KeeperV2Test\|ProtocolFeeControllerV2Test\|RendererV2Test\|AirdropV2Test\|VaultV2Test)$"` | **10 suites, 235 pass, 0 fail, 0 skip**. `ExtensionsV2Test` does not exist: `test/v2/ExtensionsV2.t.sol` defines `AirdropV2Test` (32) and `VaultV2Test` (13), used instead. all ten need no fork. patterns are anchored so no review contract matches by substring |
| 3 | the whole v2 tree in one invocation as the fork job runs it: `FOUNDRY_PROFILE=ci FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=50 forge.sh test --match-path "test/v2/**" --fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000 --no-match-contract "^(<the ten>)$" -vvv` | **44 suites, 343 pass, 0 fail, 0 skip**, 265 s wall (4m27). no split needed. includes the two review dirs (94 tests) |
| 4 | v2 unit set, no fork (same as 2) | 235 pass, 0 fail, 0 skip |
| 5a | ci `fork-tests` step, extracted from the new `test.yml` and run verbatim with the job env (`FORK_BLOCK` read from `ForkBase.sol` by the same grep) | **45 suites, 391 pass, 4 fail, 3 skip**, 79 s. the 4 are the known v1 failures below. the 3 skips are `FeeMathReconciliationForkTest` (Sepolia only, 1) and `HookProtocolFeeNumeratorZeroTest` (2) |
| 5b | ci `check` step `Run Forge tests` (new: adds `--no-match-path "test/v2/**"`), extracted and run with `SKIP_FORK_TESTS=true MAINNET_RPC_URL=http://127.0.0.1:9` | **66 suites, 565 pass, 0 fail, 143 skip**. matches the earlier v1 no fork record |
| 5c | ci `check` step `Run v2 unit suites (no fork)`, extracted and run | **10 suites, 235 pass, 0 fail, 0 skip** |
| 5d | ci `review-proofs` step, extracted and run with the fork flags | **24 suites, 94 pass, 0 fail, 0 skip** (70 v1 proofs, 24 second pass regressions), 259 s |
| 6 | size gate step, shell extracted from `test.yml` and run locally | see `sizes.md`: real run prints headroom 7,860 and exits 0; min raised to 99999 exits 1; missing key exits 1 |
| 7 | `node script-js/verify-registry.mjs` (with `NODE_USE_ENV_PROXY=1` so node uses the sandbox proxy), `npm run check:addresses`, `ui npm test` | registry: 68 contract rows, 2 coins, all chain, owner, state and wiring checks ok; 13 bytecode compares flagged, see below. `check:addresses` 4 of 4 ok. ui: 51 pass, 0 fail |

### the 4 known v1 failures (fork job, unchanged)

| test | failure |
|---|---|
| `BurnRouterForkTest.test_fork_processBurnWeth_keeperRewardCapped` (`test/BurnRouter.t.sol`) | `InsufficientLayerOut(4.975e17, 7.992e18)` |
| `BurnRouterForkTest.test_fork_processBurnWeth_paysKeeperReward` | `InsufficientLayerOut(4.975e17, 7.96e17)` |
| `MainnetLaunchRehearsalForkTest.test_rehearsal_s06_highSuccess_burnCadence` | `InsufficientLayerOut(1.0436e24, 1.3314e24)` |
| `EOAPermit2SwapForkTest.test_rehearsal_s06_highSuccess_burnCadence` | same figures |

cause: recorded as known v1 state mismatches in hygiene-fixes.md (the swap returns less layer than the test's floor at the pinned block); not re-investigated here. they test v1 contracts that v2 replaces. expected red, not touched. the previous record's 9 extra failures (`EscrowV2Test`, `FeeDeliveryTest`, `TokenV2Test`) are gone: those suites no longer run under a global fork.

### what changed in `.github/workflows/test.yml`

| change | detail |
|---|---|
| check job, `Run Forge tests` | adds `--no-match-path "test/v2/**"`. the old command ran the whole tree including `test/v2/review/extensions-renderers/ForkRenderersReview.t.sol`, which calls `vm.createSelectFork` in setUp unconditionally and failed without a network: with the old command `check` was 950 pass, **1 fail**, 334 skip (120 suites), so it was red before this change |
| check job, new step `Run v2 unit suites (no fork)` | the ten suites, `--match-path "test/v2/**" --match-contract "^(...)$"` |
| fork job | `--no-match-contract` gains `^(<same ten>)$`, so no suite runs under a global fork url that it was not written for |
| size gate | fixed per `sizes.md`, now fails instead of skipping |

### notes

| item | note |
|---|---|
| compile memory | the first full run of the old `check` command was killed by the oom killer twice (solc at 13.9 GB resident, 15 minutes each, 140 stale files compiled in one process). the cache was warmed by `forge build <paths>` in batches; after that the full commands compile nothing. a cold github runner compiles the full set in one process, see `sizes.md` |
| registry bytecode drift | `verify-registry.mjs` reports 13 `bytecodeMatch` mismatches, all for legacy and open stack contracts, all noting `foundry-out runs=200`. the local `foundry-out` was last built at the ci profile by this session, those contracts were built at the default profile (20,000 runs). all 9 current stack contracts that have local artifacts verify. not drift on chain; rerun after a default profile build to see 0 |
| totals | every row of the totals table in `SYSTEM-REVIEW.md` section 8 is filled from the above. v2 tree total 578 pass, 0 fail, 0 skip (343 fork run plus 235 unit) |
