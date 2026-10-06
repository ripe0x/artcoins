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
