# keeper for coin 111 (CollectFlushKeeperV1)

> disclosure: the "why run it often" section describes LF-01 (docs/v2/review/contracts-locker-fees.md), which affects the live immutable locker. keep this file off the public mirror until the owner has reviewed it and run the first collect.

package k1 part 1. contract `src/v2/keepers/CollectFlushKeeperV1.sol`, proofs `test/v2/KeeperV1_111.fork.t.sol` (7 tests, pinned fork block 26_130_269), scripts `script/v2/RunKeeper111.s.sol` (`DeployKeeper111`, `RunKeeper111`). design refs: DESIGN.md section 3 d8 and 2.1, DECISIONS.md D25. the generic v2 keeper is a later package.

## live readings (cast, head block 26_130_371, 2026-10-06)

| item | value |
|---|---|
| locker | 0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab, owner 0xCB43…, keeperRewardBps 0, keeperRewardCap 0.01 eth |
| coin 111 slot | 14 positions (id 309865..309878), native eth is currency0, fee 0x800000 (dynamic), tickSpacing 200, hook 0x636c… |
| reward recipient | 1 slot, 10000 bps, recipient = fee swapper 0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961, admin 0xdEaD (frozen) |
| escrow | 0x7559689765aE86cBB38e68CD1294830CccB125F2, getter `feesToClaim(owner, token)` / `availableFees` |
| swapper `endRecipient` | 0x8C72FBc2bB32e76aa54243F76745266a0F92CD01 (contract, forwards eth on, balance does not accumulate) |
| swapper params | minBlocksBetweenConverts 50, maxSlippageBps 500, maxStepIn 1e24, depositToLocker false, paired native, no owner |
| swapper state | lastConvertBlock 26_106_550, totalArtcoinConverted 2.6198e24, totalKeeperRewards 1.857e15 wei |
| swapper eth balance | 0 |
| escrow eth for swapper | 0 |
| escrow coin for swapper | 0 |
| swapper coin balance | 0 |

v1 names confirmed in src: `locker.collectRewards(token)`, `swapper.flushPaired()` (public, exists), `swapper.convert(minOut)` (reverts `ConvertTooEarly`, `NothingToConvert`, `InsufficientOutput`, `MinOutBelowFloor`), `swapper.flushPaired` reverts `NothingToFlush` on an empty slot. keeper reward paths: locker pays `msg.sender` bps of the eth side fees (0 live), flush and convert each pay 50 bps capped at 0.01 eth (constants in the swapper). the keeper is `msg.sender` for all three and forwards the sum to its caller.

## what `run(doConvert, minOut)` does

| step | call | on non gas revert | on gas shortfall |
|---|---|---|---|
| 1 | `locker.collectRewards(token)`, floor 658k + 50k, then all remaining gas | revert bubbles (D49) | reverts `InsufficientGas(1)` |
| 2 | `swapper.flushPaired()` with explicit gas | reported `FlushSkipped`, flushed 0 | reverts `InsufficientGas(2)` |
| 3 | `swapper.convert(minOut)` if `doConvert` | reported `ConvertSkipped` (`ConvertTooEarly`, `NothingToConvert`, `InsufficientOutput`), converted 0 | reverts `InsufficientGas(3)` |
| 4 | forward all eth and coin the keeper holds to `msg.sender` | coin forward is try/catch so dust cannot brick the run; eth forward reverts if the caller rejects eth | n/a |

gas handling (reviewer finding): each step has a floor (measured collect 658k, flush 72k, convert 299k, plus 50k margin) and gets explicit gas. a shortfall reverts instead of skipping, and an empty revert from a step (out of gas) is rethrown as `InsufficientGas`. reason: with a skip path, an `estimateGas` search lands on the cheapest successful gas, which silently skipped convert. `test_keeperV1_lowGas_neverSilentlySkips` sweeps gas limits from 1.3M down to 0.3M: 8 succeed (all convert), 33 revert, none succeed with converted == 0.

`preview()` returns `(uncollectedEth, uncollectedCoin, escrowedEth, swapperEth, swapperCoin)`. both fee currencies are summed from pool fee growth (so coin only pending fees show). `swapperEth > 0` means a third party claim stranded eth.

## measured on fork (tests)

| measure | value |
|---|---|
| `run(true, 0)` full path, all three steps | 798,632 gas |
| minimum gas limit that succeeds (floors) | about 1.1M, use 1.2M |
| eth cost at 5 gwei / 20 gwei | about 0.004 / 0.016 eth for 800k |
| flush and convert eth result with 1 eth round trip | collected 4.6765e15, flushed 4.6765e15, converted 4.7395e15 wei |
| convert realized vs pool spot | about 6.5% under spot (dynamic fee, skim, coin tax), inside the swapper's own 80% floor |

## deploy and run

caller requirements: any account, no allowlist. needs eth for gas only. the keeper has no owner and holds nothing, so any operator can run it and keeps the rewards.

```bash
source /tmp/claude-0/env.sh   # or export MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co
# deploy (dry run first, then broadcast with the operator's keystore)
forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $MAINNET_RPC_URL
forge script script/v2/RunKeeper111.s.sol:DeployKeeper111 --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore>

# run (dry run prints preview and quoted minOut; nothing is sent without --broadcast)
export KEEPER_111=<deployed keeper>
export KEEPER_SLIPPAGE_BPS=100     # default 100
forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $MAINNET_RPC_URL
forge script script/v2/RunKeeper111.s.sol:RunKeeper111 --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore> --gas-limit 1200000

# read only
cast call $KEEPER_111 "preview()(uint256,uint256,uint256,uint256,uint256)" --rpc-url $MAINNET_RPC_URL
```

`minOut` is quoted by simulating the run at current state with `minOut` 0 and subtracting slippage (not a spot quote, spot is about 6.5% too high on this pool and would make convert skip every time). test `test_keeperV1_scriptQuote_convertsAtDefaultSlippage` shows 100 bps converts and an impossible `minOut` skips convert without reverting the run. the quote protects against a sandwich between simulation and inclusion; for a private tx route use a bundle.

proof run: `forge.sh test --match-path test/v2/KeeperV1_111.fork.t.sol -vv`.

## why run it often

LF-01 (critical, proved on fork against the live locker): `collectRewardsWithoutUnlock` is permissionless, and inside a caller's own unlock the position manager's currency delta is shared, so `TAKE_PAIR` takes the net credit. anyone can redirect the uncollected lp fees of 111 to themselves. the locker is immutable and has no pause. the exposure is exactly what has accrued since the last `collectRewards`: the hook never auto collects, and the locker keeper reward is 0, so nobody is paid to collect. the keeper's collect step is the only live mitigation. it shrinks the pending amount, it does not close the hole.

| rule | value |
|---|---|
| cadence | hourly, from a bot or cron |
| extra trigger | also whenever `preview()` shows `uncollectedEth` > 0.02 eth or `uncollectedCoin` > 10,000 coin (10_000e18) |
| skip rule | do not run when pending is below gas cost (about 0.004 eth at 5 gwei for an 800k run, scale with gas price) unless the hourly timer is due |
| flush | every run also flushes, so the escrow to swapper hop is closed in the same tx |
| convert | `doConvert` true; min blocks (50) makes extra convert attempts a reported no-op (`ConvertSkipped`), so running hourly is safe |

other trigger from the stranding bug: `preview().escrowedEth > 0.05 eth` at any time means a flush is overdue (escrowed eth is exposed to a third party claim until flushed).

cron example (check script reads `preview()`, runs the forge script when a trigger holds):

```
0 * * * *  /opt/artcoins/run-keeper-111.sh   # hourly, script applies the 0.02 eth / 10k coin / gas cost rules
```

one off collect now, no keeper needed (owner or anyone; locker pays no reward). keeper rewards on the swapper side go to the caller.

```bash
export LOCKER=0x866ea3Dc2bf7A3e77374619cf50EB697FA766aab
export COIN=0x61C9d89fe1212F6b55fF888816A151463287B8ae
export SWAPPER=0xeBD9B74A4c26C6E54e83C84CB247c069eC42A961
cast send $LOCKER "collectRewards(address)" $COIN --rpc-url $MAINNET_RPC_URL --account <keystore> --gas-limit 900000
# eth side fees now sit at the escrow under the swapper slot and are exposed to a third party claim: flush at once
cast send $SWAPPER "flushPaired()" --rpc-url $MAINNET_RPC_URL --account <keystore> --gas-limit 200000
# coin side (needs 50 blocks since lastConvertBlock; pass a real minOut, 0 relies only on the swapper's 80% spot floor)
cast send $SWAPPER "convert(uint256)" <minOut> --rpc-url $MAINNET_RPC_URL --account <keystore> --gas-limit 500000
```

`flushPaired` reverts `NothingToFlush` when no eth fees were collected (coin only fees), which is fine. the three separate txs leave windows between them, so prefer the keeper once deployed.

## what the keeper mitigates and what it cannot

| exposure | keeper effect |
|---|---|
| LF-01 uncollected fee diversion | reduces pending amount by collecting often. cannot prevent a diversion of what is pending at the moment of an attack |
| swapper eth stranding (LF-02, `escrow.claim(swapper, 0)` by anyone) | collect then flush in one tx, so honest flows never leave eth at the escrow between txs. cannot stop a griefer who calls `locker.collectRewards` and `escrow.claim(swapper, 0)` himself (both permissionless, one tx). cannot recover eth already stranded: the swapper has no sweep and `convert` forwards only the swap output. `test_bug_swapperV1_thirdPartyClaim_strandsEth` shows swapper balance stays > 0 after run, and `preview().swapperEth` reports it |
| coin side fees | `convert` runs when min blocks allow; swapper floor 80% of spot and `minOut` bound the sandwich loss; the swapper's own `maxSlippageBps` 500 is a deploy time value, not enforced against the pool fee |
| forgotten fees | none unless someone runs it. no on chain incentive: locker reward 0, swapper rewards 50 bps capped 0.01 eth per call |
| owner raising locker keeper reward | allowed up to the locker's bound (KEEPER_REWARD_BPS_MAX, cap bounds); the keeper forwards whatever it receives, so a runner earns it |

keeper properties tested: holds no eth or coin after a run, caller gets locker reward plus flush plus convert rewards (checked with the locker bps set to 50 by a pranked owner, live is 0), second run in the same block does not revert and pays nothing (`test_keeperV1_nothingToFlush_noRevert`), convert too early is reported and skipped (`test_keeperV1_convertTooEarly_isSwallowed`).

## notes for the reader of the test

| note | detail |
|---|---|
| fork dust | the default test contract's create addresses hold real mainnet eth, so the test zeroes the keeper balance after deploy (`vm.deal(keeper, 0)`) and measures caller deltas, since 0xBEEF also has a real balance |
| end recipient | 0x8C72… forwards eth on, so its balance is not asserted |
| rpc | `MAINNET_RPC_URL`, default tenderly gateway; tests skip when unreachable or `SKIP_FORK_TESTS=true` |
| size | `CollectFlushKeeperV1.sol` is 136 lines (imports, natspec and gas constants included), about 100 lines of code |

## v2 keeper (ArtCoinsKeeperV2)

generic, for any v2 art coin. `src/v2/keepers/ArtCoinsKeeperV2.sol`, tests `test/v2/KeeperV2.t.sol` (mocks `test/v2/mocks/KeeperMock*.sol`). spec: DESIGN d8 generic column.

| item | detail |
|---|---|
| entry | `collectAndForward(token, doConvert, minOut)`, permissionless, no owner, one immutable (`factory`) |
| art coin check | `factory.deploymentInfo(token)`; reverts `NotArtCoin(token)` when the record token does not match or the locker is zero |
| steps | 1 `locker.collectRewards(token)`. then for each distinct locker reward recipient that answers erc165 `supportsInterface(type(IFeeAutoSwapperV2).interfaceId) == 1`: 2 `flushPaired()`, 3 `convert(minOut)` only when `doConvert`. 4 forward all eth and coin balance to `msg.sender` |
| non swapper recipients | skipped (eoa, no erc165, reverts, wrong answer, wide return, gas burner). probe is a 30k gas staticcall copying one word |
| gas floors (D49) | per step values are floors, not caps: collect 900k, flush 150k, convert 400k, probe 30k, each plus 50k margin and the 63/64 rule. before a step `gasleft()` must clear the floor or the call reverts `InsufficientGas(step)` (1 collect, 2 flush, 3 convert, 4 probe). the step then gets all remaining gas, so a collect that grows past the old figure still runs (fixes V2A-05) |
| failed step (V2A-10) | no empty revert is read as out of gas. if a step reverts and `gasleft()` after the call is under its floor, the keeper reverts `InsufficientGas(step)`. otherwise: collect bubbles the original revert data (a real failure surfaces), flush emits `FlushSkipped(token, swapper, reason)` and convert emits `ConvertSkipped(token, swapper, reason)`, both then report 0 in `SwapperServiced`. flush is reported and not bubbled because `NothingToFlush` is the normal idle answer and one broken swapper should not block the others. reasons are copied up to 256 bytes (no return bomb) |
| funds | holds nothing: balance (eth and coin, including donations) leaves in the same call. caller that rejects eth reverts `EthTransferFailed` |
| reentry | `ReentrancyGuardTransient`, a swapper that reenters the keeper is rejected |
| extra | `preview(token)` view: swapper count, accrued paired and coin, next convertible block. uncollected lp fees are not readable via the locker interface |
| gas figures | v1 measurements with room added. re measure on the v2 stack when the fork harness is ready |

tests (33): happy path (`test_keeperV2_collectAndForward_swapperRecipient`), non art coin and mismatched or zero locker records revert, non erc165 recipients skipped, duplicates serviced once, convert only when asked, collect revert bubbles, flush and convert reverts reported with their reason, steps that run past the old caps (collect 1.3m, flush 400k, convert 700k) still complete, out of gas inside collect reports `InsufficientGas(1)`, low gas reverts for steps 1 to 4, a gas sweep from 100k to 2.5m proving every run either completes all steps or reverts `InsufficientGas` with state untouched, keeper holds nothing (with donations), reentrancy, preview, no owner. fork test against live v2 contracts is not written (no v2 stack on chain yet).

known limit: a recipient that answers erc165 and then burns all gas in `flushPaired` or `convert` now burns up to 63/64 of the tx gas and the run reverts `InsufficientGas`. before D49 the cap bounded the burn but the run reverted the same way. reward recipients are frozen at launch, `collectRewards` stays directly callable.

### D49 follow up for CollectFlushKeeperV1 (coin 111 pin)

| item | detail |
|---|---|
| floors | same rule: collect 658k, flush 72k, convert 299k plus 50k margin are floors checked with `gasleft()` before the step, the call has no `{gas: X}` |
| collect revert | bubbles (fork test `test_keeperV1_collectRevert_bubbles`), out of gas reports `InsufficientGas(1)` |
| flush and convert revert | reported with `FlushSkipped(bytes reason)` and `ConvertSkipped(bytes reason)`, returned 0. `test_keeperV1_convertTooEarly_isSwallowed` now also asserts the `ConvertSkipped` log carries the revert data |
| sweep | `test_keeperV1_lowGas_neverSilentlySkips` still passes on fork (8 completed, 33 reverted, none completed without converting) |

## LAYER keeper (CollectFlushKeeperLayer)

package k3. contract `src/v2/keepers/CollectFlushKeeperLayer.sol` (199 lines), proofs `test/v2/KeeperLayer.fork.t.sol` (11 tests, pinned block 26_130_269, ForkBase), scripts `script/v2/RunKeeperLayer.s.sol` (`DeployKeeperLayer`, `RunKeeperLayer`, both refuse mainnet unless `ALLOW_SUPERSEDED=1`: the legacy stack is superseded in the registry). addresses come from `script/Addresses.sol`.

### live readings (cast, head block 26_132_909, 2026-10-06)

| item | value |
|---|---|
| LAYER | 0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9, supply 4.7896e26 at the pin |
| pool (locker `tokenRewards`) | currency0 LAYER, currency1 weth 0xC02a…6Cc2, fee 0x800000 flag, spacing 200, hook 0xA5eA9904…28cc, id 0x85c15a70…1e50. spot at the pin 1.62e25 LAYER per weth, liquidity 7.49e22 |
| legacy locker 0x75BE…1118 | 12 positions from id 252351. no keeper reward (source has none). `collectRewards(address)` permissionless, sends every slot's share to the fee locker via `storeFees`, never to the recipient |
| hook 0xA5eA | `_beforeSwap` runs `locker.collectRewardsWithoutUnlock(LAYER)` on every swap, `_afterSwap` runs the autoforward extension. so the pending lp fee is only the last swap's fee, in that swap's input currency |
| slot 0 | 3800 bps, recipient 0xCB43…17F9 (owner), admin owner. type: eoa with an eip 7702 delegation (code `0xef0100612373d7003d694220f7800eeaf8e3924c0951d3`, 23 bytes) |
| slot 1 | 4200 bps, recipient burn router 0x2eDB…2000, admin owner |
| slot 2 | 2000 bps, recipient protocol fee controller 0x5fDc…0A60, admin legacy factory 0xd159 |
| fee locker 0x1143…6b05 | `claim(feeOwner, token)` permissionless, nonReentrant, `safeTransfer` to `feeOwner` only. reverts `NoFeesToClaim` at 0 |
| fee locker claimable | owner 3,315,375.59 LAYER and 0.47962 weth. router 0 and 0. controller 4,849.42 LAYER and 0.000489 weth |
| controller 0x5fDc | treasury 0x41c3…A6A4 (0xSplits pass through wallet, passThrough 0x7C66…39B5, owner 0xCB43), burnRouter 0x2eDB, split 6000 treasury / 4000 burn / 0 rewards. `processFees(token)` permissionless, splits its whole balance. holds 0 |
| router 0x2eDB (legacy source) | weth 0.000186, eth 0, LAYER 0. threshold 0.01 weth. owner floor `minLayerOutPerWeth` 5e24 (31% of spot). no keeper reward. swaps through the universal router |
| router 0xE600 (open stack) | weth 0, eth 0.005676. threshold 0.01. owner floor 1.0353e25 (64% of spot, the view nets the 0.5% reward, LF-12). reward 50 bps capped 0.01 eth, paid in eth to msg.sender. fed by the open factory team fee (no coins), not on the LAYER fee path |
| router 0x0EB2 (current stack) | weth 0, eth 0.005199. threshold 0.01. no owner floor: 1% impact clamp and an 80% of spot floor on the consumed amount. reward 50 bps capped 0.01 eth. fed by the 111 controller 0xd8C6 (13.33% burn share), not by LAYER fees |
| autoforward extension 0x38d0 | bound to hook 0xA5eA, locker, fee locker, controller, router 0x2eDB. thresholds 0.01 weth and 100,000 LAYER for both the fee locker slots and the controller. owner 0xCB43. no permissionless function: `afterSwap` is onlyHook, setters onlyOwner. per swap it runs at most one of: processBurnLayer, processFees, claim. never processBurnWeth |
| at the pin (26_130_269) | router 0x2eDB weth+eth 0.000128, router weth slot 0.0000582, controller slots 4,849 LAYER and 0.000489 weth, routers 0xE600 0.005676 and 0x0EB2 0.005199 eth. every router below its threshold |

### the LAYER fee path

| hop | from | to | call | who | keeper step |
|---|---|---|---|---|---|
| 1 | lp positions | fee locker: 38% owner, 42% router, 20% controller | `collectRewards(LAYER)`, also every swap via the hook | anyone | 1 |
| 2a | fee locker owner slot | owner | `claim(owner, token)` | anyone, pays the owner only | never. owner decision (RUNBOOK action 8) |
| 2b | fee locker router slot | router 0x2eDB balance | `claim(router, token)` | anyone | 2 |
| 2c | fee locker controller slot | controller balance | `claim(controller, token)` | anyone | 2 |
| 3 | controller balance | 60% treasury 0x41c3, 40% router 0x2eDB | `processFees(token)` | anyone | 3 |
| 4 | router LAYER | burned | `processBurnLayer()` | anyone | 4 |
| 5 | router weth and eth | LAYER bought on the LAYER pool, burned | `processBurnWeth(minLayerOut)` at or above 0.01 weth and the owner floor | anyone | 5, only with `doBurn` |
| 5' | routers 0xE600 and 0x0EB2 | same, reward to caller | `processBurnWeth` | anyone | 5, same loop |
| ext | the extension advances 2 to 4 one stage per swap above its thresholds | | swap | hook | the keeper does 2 to 4 without thresholds |

LF-02 stranding shape check (never push a claim into a contract that cannot forward it): none on this path. the two pushed recipients book by balance: `processBurnWeth` wraps eth and reads `balanceOf(weth)`, `processBurnLayer` and `processFees` read `balanceOf`. a third party claim therefore strands nothing, it only moves the balance one hop early. proved by `test_layerKeeper_thirdPartyClaim_doesNotStrand` (griefer claims router and controller slots, then the keeper burns and splits all of it; the owner slot claim pays only the owner). the keeper never claims the owner slot.

### what `run(bool doBurn, uint256 minLayerOutPerWeth, bool unwrap)` does

| step | call | skip rule (no call) | on non gas revert | floor (D49) |
|---|---|---|---|---|
| 1 | `locker.collectRewards(LAYER)` | none | bubbles | 640k + 50k |
| 2 | `feeLocker.claim(slot, token)` for controller and router0, LAYER and weth (controller first) | slot is 0 | `StepSkipped(2, feeLocker, reason)` | 60k + 50k |
| 3 | `controller.processFees(token)` for LAYER and weth | controller balance 0 | `StepSkipped(3, …)` | 80k + 50k |
| 4 | `router.processBurnLayer()` per router | router holds no LAYER | `StepSkipped(4, …)` | 60k + 50k |
| 5 | `router.processBurnWeth(minOut)` per router, if `doBurn` | weth+eth under `minProcessThreshold` | `StepSkipped(5, …)` (`MinLayerOutBelowFloor`, `SlippageFloorNotSet`, `V4TooLittleReceived`, `InsufficientLayerOut`) | 900k + 50k |
| 6 | forward weth (unwrapped if `unwrap`), LAYER and eth the keeper holds to `msg.sender` | | eth send failure reverts `EthTransferFailed` | n/a |

`minOut` per router: with an owner floor (0x2eDB, 0xE600), `max(minLayerOutPerWeth, minLayerOutPerWeth())` times balance over 1e18 (the setter value, not the view, LF-12). floor 0 is passed through and the router reverts `SlippageFloorNotSet`, reported. without a floor getter (0x0EB2) the keeper passes 0: that router enforces its own 1% clamp and spot floor on the consumed amount, and a caller minimum on the full balance would trip on a partial fill. a step revert that leaves gas under its floor reverts `InsufficientGas(step)` (0x969aeb08). returns `(lCol, wCol, lBurn, wBurn, lBought)`: fees credited by the collect, LAYER burned directly, weth in and LAYER out of the weth burns. `preview()` returns `(uncollectedLayer, uncollectedWeth, claimable[4], routerWeth[3], routerThreshold[3])`, claimable order controller LAYER, controller weth, router0 LAYER, router0 weth.

deviations from the brief: the second argument is a rate (LAYER per 1e18 weth, the routers' own unit), not an absolute `minLayerOut`, because the weth each router burns is only known after the claims and splits inside the run and up to three routers burn in one call. `unwrap` is the third argument. constructor `(locker, LAYER, weth, feeLocker, controller, [router0, router1, router2])`, all three routers required (no zero slots).

### measured on fork (tests)

| measure | value |
|---|---|
| collect (12 positions) | 590k cold, 332k warm |
| claim, processFees, processBurnLayer | 9k to 37k, 17k to 27k, 18k to 20k each |
| processBurnWeth | 0x2eDB 345k, 0xE600 474k, 0x0EB2 511k (each swap runs the hook's own collect) |
| full path, 0x2eDB burn (collect, 4 claims, 2 splits, LAYER burn, weth burn) | 853k (warm, after the test swaps) |
| collect cold plus two reward router burns | 1.84M |
| idle run (nothing pending) | 228k warm, about 0.65M cold (the collect walks 12 positions) |
| sweep 2.6M to 0.3M, step 50k, fees pending and router0 due | 23 completed (all collected, claimed and burned), 24 reverted, 0 skipped. lowest limit that completed 1.5M |
| gas limit to set | 3,500,000 (all three routers due); unused gas is not charged |
| burn result, 3 weth round trip | 0.0204 weth burned for 293,849 LAYER (1.44e25 per weth, above the 5e24 floor), 211,221 LAYER burned directly |
| reward | 0x2eDB pays 0. 0xE600 and 0x0EB2 pay 0.5% (0.000254 eth for 0.0257 + 0.0252 weth burned) |
| script quote at default 200 bps | 1.413e25 LAYER per weth after the round trip, burns |
| runtime size (ci profile) | 8,093 bytes |
| no rpc | `SKIP_FORK_TESTS=true` or an unreachable rpc: all 11 report SKIP |

### deploy and run

```bash
source /tmp/claude-0/env.sh   # or export MAINNET_RPC_URL=https://mainnet.gateway.tenderly.co
export ALLOW_SUPERSEDED=1     # the scripts target the superseded legacy stack and refuse mainnet without it
# deploy (dry run, then broadcast with the keeper hot key)
forge script script/v2/RunKeeperLayer.s.sol:DeployKeeperLayer --rpc-url $MAINNET_RPC_URL
forge script script/v2/RunKeeperLayer.s.sol:DeployKeeperLayer --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore>

# run: prints preview, simulates with rate 0, quotes realized rate minus KEEPER_SLIPPAGE_BPS (default 200)
export KEEPER_LAYER=<deployed keeper>
forge script script/v2/RunKeeperLayer.s.sol:RunKeeperLayer --rpc-url $MAINNET_RPC_URL
forge script script/v2/RunKeeperLayer.s.sol:RunKeeperLayer --rpc-url $MAINNET_RPC_URL --broadcast --account <keystore> --gas-limit 3500000
# env: KEEPER_DO_BURN (default true), KEEPER_UNWRAP (default true)

# read only
cast call $KEEPER_LAYER "preview()(uint256,uint256,uint256[4],uint256[3],uint256[3])" --rpc-url $MAINNET_RPC_URL
```

proof run: `forge.sh test --match-path test/v2/KeeperLayer.fork.t.sol --skip "test/v2/review/**" --skip "test/v2/review-v2/**" -vv` (11 pass at the pin).

### cadence

the hook already collects on every swap, so the LF-01 exposure on LAYER is one swap's fee and the collect step is cheap insurance. the job is burning weth, which nothing else does (the extension never calls `processBurnWeth`).

| rule | value |
|---|---|
| cron | daily: read `preview()`, run when any `routerWeth[i] >= routerThreshold[i]`, or when `routerWeth[0] + claimable[3] + 0.4 * (claimable[1] + controller weth)` reaches 0.01 weth |
| weekly | run regardless (pushes the controller and router LAYER slots below the 100k extension threshold and burns them) |
| before a run | router floors fresh (RUNBOOK action 5). the script's simulated rate minus 200 bps protects the runner even with a stale floor |
| skip | when nothing is due: an idle run costs about 0.65M gas for no effect |
| economics | at current volume nobody earns enough to run it: 0x2eDB pays nothing, the reward routers pay 0.5% of a 0.01 weth burn (0.00005 eth) against about 0.5M gas. owner funded, hot key under 0.05 eth |

### what it cannot do

| limit | detail |
|---|---|
| owner slot | 3.3M LAYER and 0.48 weth stay at the fee locker. claiming is the owner's decision (action 8) |
| treasury | the controller's 60% sits in the pass through wallet 0x41c3 (now 0.0216 weth, 1.0M LAYER); moving it is the treasury's `passThroughTokens`, not this keeper |
| dust | weth under 0.01 at a router waits; LAYER of any size is burned |
| stale floors | the keeper can only tighten a floor. a third party can still call `processBurnWeth` with the owner floor as the minimum (LF-09); keep floors fresh |
| LF-01 | cannot stop a diversion of the pending fee, it only keeps it at one swap's worth |
| recipient changes | slots 0 and 1 are owner administered. if slot 1 is repointed (v2 router), redeploy the keeper with the new router0; the old one keeps working on whatever lands at the old router |
| gas | a run with all three routers due needs about 2.8M of headroom because each weth burn needs 985k free to start. a shortfall reverts `InsufficientGas(5)`, it never drops the burn |
