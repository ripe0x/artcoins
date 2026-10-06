# contracts review: lp locker, fee swapper, burn router, protocol fee

second pass. scope: `src/lp-lockers/**`, `src/FeeAutoSwapper.sol`, `src/interfaces/IFeeAutoSwapper.sol`, `src/protocol-fee/**`, `src/utils/ISwapRouterV3.sol`, escrow as used by these. proof tests in `test/v2/review/locker-fees/` (13 tests, all pass). local tests use uniswap v4 built from `lib/`; the only stub is permit2 (lib pins solc 0.8.17). fork tests pin block 26,130,300 and skip without an rpc.

> disclosure: LF-01 and LF-02 affect live, immutable contracts with no pause. keep this file and `LiveForkReview.t.sol` off the public mirror until the owner has reviewed them and mitigations are in place.

## live facts read on chain (block ~26.13m)

| item | value |
|---|---|
| locker 0x866e… | factory 0x4959…, keeperRewardBps 0, cap 0.01 eth, MAX_LP_POSITIONS 14, exposes `collectRewardsWithoutUnlock` |
| coin 111 slot | 14 positions, native eth pool, skim hook 0x636c…, one reward slot 10000 bps to 0xeBD9…, slot admin 0xdEaD (frozen) |
| 111 fee swapper 0xeBD9… | FeeAutoSwapper bytecode, native, push mode, endRecipient 0x8C72… (contract), maxSlippageBps 500, minBlocks 50, no owner |
| factory teamFeeRecipient | 0x4959 → owner eoa; 0xf051 → burn router 0xE600; 0xd159 (LAYER) → controller 0x5fdc |
| controller 0x5fdc | legacy source, split 6000/4000/0, burnRouter 0x2edb |
| burn router 0x2edb | legacy source, owner floor 5e24 LAYER/weth (30.8% of spot) |
| burn router 0xE600 | source not in repo; keeper reward 50 bps cap 0.01, owner floor 1.035e25 (63.9% of spot), no impact clamp |

src `BurnRouter` (impact clamp) and src `ProtocolFeeController` (immutable split) were not found deployed in repo records; findings on them apply to v2 and to any external deploy of that source.

## findings

| id | sev | title | live |
|---|---|---|---|
| LF-01 | critical | `collectRewardsWithoutUnlock` lets uncollected LP fees be diverted | yes |
| LF-02 | high | third party escrow claim strands FeeAutoSwapper paired side fees | yes (111) |
| LF-03 | high | BurnRouter impact clamp is per call, not per block | src |
| LF-09 | high | live burn routers swap full balance per call, guarded only by stale owner floors | yes |
| LF-04 | medium | BurnRouter keeper reward sized on whole balance | src |
| LF-07 | medium | FeeAutoSwapper slippage cap is deploy time, unenforced vs pool fee; 111 at 500 bps | not quantified |
| LF-05 | low | slot admins can repoint recipients after launch, incl. address(0) | yes |
| LF-08 | low | FeeAutoSwapper payout failure reverts flush/convert, no owner path | design |
| LF-10 | low | controller: no rescue, rotation depends on old router, artcoin burn share parked | src |
| LF-11 | low | locker `withdrawETH` uses `transfer` (2300 gas) | yes |
| LF-12 | info | live router view under-reports enforced minimum | yes (0xE600) |
| LF-13 | info | `ISwapRouterV3` unused | n/a |

### LF-01 critical: fee collection without unlock trusts shared PositionManager deltas

- evidence: `ArtCoinsLpLocker.sol:396-398` (permissionless), `:479-512` (`TAKE_PAIR` of the full net credit, `:495-496`, `:502-503`). same in legacy locker `ArtCoinsLpLockerMultiple.sol:292,352-390`. root cause: inside a caller's unlock, PositionManager's currency delta is shared state that other calls in the same unlock can already have moved; `TAKE_PAIR` takes the net, not the locker's own fee amount.
- impact: uncollected fees of any coin (both currencies) can be redirected away from recipients by an unprivileged caller. the current hook never auto collects, so fees accumulate between keeper calls.
- proof: `LpLockerReview.t.sol::test_bug_LF01_collectRewardsWithoutUnlock_lets_anyone_steal_all_lp_fees` (local v4); `LiveForkReview.t.sol::test_bug_LF01_fork_live_111_uncollected_fees_stealable` (fork, live locker and position manager).
- live mitigation: no switch exists. collect frequently via `collectRewards` so little is ever pending (keeper reward is 0, so the owner must run it).
- v2 fix: remove `collectRewardsWithoutUnlock`. collect only via `modifyLiquidities` (PositionManager opens its own unlock). if an open tab path is required, restrict it to the registered hook and take exact before/after deltas, never `TAKE_PAIR` / open delta.

### LF-02 high: swapper paired fees strandable

- evidence: `ArtCoinsFeeEscrow.sol:85-99` permissionless push claim; `FeeAutoSwapper.sol:446-453` flush sizes from the escrow ledger, not its own balance; `:280` open `receive()`; no sweep, no owner.
- impact: any party can move the swapper's eth or weth escrow balance into the swapper, after which neither `flushPaired` nor `convert` will ever forward it. no gain to the caller, permanent loss to endRecipient. artcoin side is unaffected (convert reads `balanceOf`). 111's slot admin is 0xdEaD, so the recipient cannot be moved off the swapper.
- proof: `FeeAutoSwapperReview.t.sol::test_bug_LF02_third_party_claim_strands_native_fees_in_swapper`, `..._weth_fees_in_swapper`, `test_holds_LF02_artcoin_side_push_is_not_stranded`; fork on the live 111 swapper bytecode `LiveForkReview.t.sol::test_bug_LF02_fork_live_111_swapper_eth_strandable` (no eth side credit was pending at the fork block, so one is deposited as the allowlisted locker).
- v2 fix: pay out from balance; add permissionless `sweep()` to the immutable endRecipient; escrow `claim` restricted to feeOwner, or keep push but let contracts self claim.

### LF-03 high (src): impact clamp not paced

- evidence: `BurnRouter.sol:226-283` no per block pacing (contrast FeeAutoSwapper `minBlocksBetweenConverts`); spot re-read each call `:233,272`; limit and floor both relative to that spot `:301-315,:357-359`.
- impact: the 100 bps "sole sandwich guard" compounds when called repeatedly in one transaction, so the whole balance can be spent at a manipulated price; the stated "uneconomic by construction" claim does not hold.
- proof: `BurnRouterReview.t.sol::test_bug_LF03_impact_clamp_loops_in_one_tx_and_sandwich_profits` (local: 20 weth balance, 31 calls in one tx, 14% sqrt price move by the burner, value lost by the router ≈ 29% of balance). fork against src deployed on the live LAYER pool: `LiveForkReview.t.sol::test_bug_LF03_fork_src_burnrouter_loop_on_live_layer_pool` (19 calls, 9.7% move, single call consumed 0.094 of 2 weth).
- v2 fix: one burn per N blocks (state `lastBurnBlock`) plus a per period weth budget; floor against a TWAP or an owner bounded reference, not the same tx spot; restrict the open tab entry to the registered extension.

### LF-09 high (live): full balance burns behind stale floors

- evidence: on chain, 0xE600 and 0x2edb take the full weth balance per call; only guard is owner `minLayerOutPerWeth`. at the fork block the floors are 63.9% and 30.8% of spot.
- impact: burns accept execution far below spot; the gap is extractable by ordering around keeper calls. a floor above spot instead blocks burns until updated (runbook item: "LAYER burn router floor" = `setMinLayerOutPerWeth`).
- proof: `LiveForkReview.t.sol::test_LF09_fork_live_burnrouter_full_balance_owner_floor` (0.503 weth consumed in one call; logs spot vs floor).
- runbook now: set floors to ~95% of current spot and refresh on a schedule; keep router balances small. v2: replace both with the fixed LF-03 design.

### LF-04 medium: keeper reward on whole balance

- evidence: `BurnRouter.sol:390-404`, reward = min(0.5% of total balance, 0.01 eth) every call regardless of what the clamped swap consumed.
- proof: `BurnRouterReview.t.sol::test_bug_LF04_keeper_reward_on_whole_balance_farmed_by_loop` (thin pool, 1.9 weth: keeper takes 890 bps of burned vs nominal 50). on the live LAYER pool fork run: 0.10 eth keeper for 1.9 weth.
- fix: reward on `wethIn` actually consumed, paid after the swap; plus LF-03 pacing.

### LF-07 medium: swapper slippage guard depends on deploy params

- `FeeAutoSwapper.sol:71-81,214-216` allow up to 1000 bps; constructor does not compare with the pool's fee. floor (`:390`) is relative to same tx spot; `minOut` is caller supplied. 111 runs 500 bps and 50 block pacing (pacing holds: no loop within a block). whether 500 bps sits below 111's round trip fee (dynamic skim hook) is not verified.
- fix: v2 cap per call impact well under the measured round trip fee and add a reference price.

### LF-05 low: recipients mutable, zero not rejected

- `ArtCoinsLpLocker.sol:527-555` slot admin changes recipient/admin at any time; no zero check (placeLiquidity has one). zero recipient: erc20 credit unclaimable, native credit burned.
- proof: `LpLockerReview.t.sol::test_bug_LF05_recipient_mutable_post_launch_and_zero_recipient_strands_fees`.
- v2: freeze recipients per coin (no update functions), or require non zero.

### LF-08 low: swapper payout failures brick
- `FeeAutoSwapper.sol:486-494`: non payable endRecipient, or a non payable keeper `msg.sender`, reverts flush and convert (locker by contrast skips a failed keeper reward). no owner path. proof: `test_bug_LF08_unpayable_end_recipient_bricks_flush_forever`. live endRecipient has code and has received 0.37 eth, so it accepts eth today.

### LF-10 low: protocol fee controller (src)
- no rescue (`ProtocolFeeController.sol:21-41`), by design. `setBurnRouter` (`:132-140`) calls the current router's `layerToken()`; a router without it can never be rotated. `processFees(artcoin)` sends the burn share of a non LAYER token to BurnRouter where only `adminSweepHeldToken` moves it.
- controller unset or reverting cannot brick swaps: protocol slot is paid via escrow pull, hook protocol leg via `storeFeesNative`. it can brick deploys (`ArtCoinsFactory.sol:374-382` pushes the deploy fee). protocol slot admin is the factory with no update path (`ArtCoinsFactory.sol:413-416`), so changing `teamFeeRecipient` only affects new coins.

### LF-11 low, LF-12 info, LF-13 info
- LF-11: `ArtCoinsLpLocker.sol:571-573` `transfer` fails to multisig recipients; use `call`.
- LF-12: on 0xE600 the view returned 5.151e24 while the enforced minimum was 5.209e24 (`MinLayerOutBelowFloor`); keepers using the view revert. seen in the LF-09 fork test.
- LF-13: `src/utils/ISwapRouterV3.sol` is referenced nowhere; delete.

## claims that hold

| claim | evidence |
|---|---|
| owner cannot pull LP NFTs; `withdrawERC20(posm)` reverts | `test_holds_LF06_owner_cannot_withdraw_position_nft` |
| recipient bps sum to exactly 10000, ≤7 slots incl. protocol slot, no zero bps | `ArtCoinsLpLocker.sol:211-244` |
| position cap 14 (legacy 12, the `MultipleCap` test targets legacy), checked, contiguous ids from one mint call | `:286-288,:368-374` |
| distribution has no dust: last recipient takes the remainder | `:446-453` |
| reverting recipient cannot block collect (escrow pull model) | `:470-477` |
| hook replacement cannot block collect: hook is part of the stored poolKey and has no remove liquidity callbacks | `ArtCoinsHook.sol:953-956` |
| frequent tiny collects do not cost recipients more than the keeper bps (live bps 0) | `:166-181` |
| swapper cannot be looped within a block | `FeeAutoSwapper.sol:330-331,363` |
| controller split immutable and sums to 100% | `ProtocolFeeController.sol:99-121` |
| LiquiditySupportReceiver: owner only withdrawals, no other exit, accepts eth with event | `LiquiditySupportReceiver.sol:81-116` |

## not verified

- whether 500 bps on the 111 swapper is below the 111 pool's round trip fee.
- source of 0xE600 (not in repo; etherscan needs a key); behaviour inferred from selectors and the fork run.
- whether src BurnRouter / src controller are deployed by permanent-collection.
- exposure size of LF-01 on the legacy LAYER locker (hook collects each swap).
- how 111's eth side LP fees accrue (0 pending at the fork block).

## owner mutable today vs frozen today

| contract | function | who | effect |
|---|---|---|---|
| ArtCoinsLpLocker | setKeeperRewardBps / setKeeperRewardCap | owner | ≤200 bps, cap 0.001..0.05 eth |
| ArtCoinsLpLocker | withdrawETH / withdrawERC20 | owner | sweep locker balances (only dust between collects) |
| ArtCoinsLpLocker | updateRewardRecipient / updateRewardAdmin | slot admin | repoint slot; 111 frozen (admin 0xdEaD); protocol slot frozen (admin = factory) |
| ArtCoinsLpLocker | positions, poolKey, bps, escrow, posm, factory | nobody | frozen |
| FeeAutoSwapper | setup | deployer, once | bind coin |
| FeeAutoSwapper | everything else | nobody | frozen, no rescue |
| BurnRouter (src) | initialize (once), setMinThreshold, adminSweepHeldToken (not LAYER/weth), ownership | owner | threshold ≥0.001 eth; clamp, floor bps, reward frozen |
| burn routers 0x2edb / 0xE600 | setMinLayerOutPerWeth, setMinThreshold, adminSweepHeldToken | owner | floor is the only slippage guard |
| ProtocolFeeController (src) | setTreasury, setBurnRouter | owner | rotate sinks; split frozen; no rescue |
| controller 0x5fdc (legacy) | setTreasury, setBurnRouter, setRewardsReceiver, setSplit, adminRescue, adminRescueEth | owner | full control incl. rescue |
| LiquiditySupportReceiver | adminWithdraw, adminWithdrawEth | owner | any amount to any recipient |
| ArtCoinsFeeEscrow (as used) | addDepositor | owner | no remove, no rescue |

v2 boundary suggestion: periphery (burn router, controller, swapper) gets owner rescue + pause; coin level config (recipients, bps, positions) stays frozen, which also removes LF-05.
