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
