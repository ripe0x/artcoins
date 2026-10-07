# v2 review: hook (independent)

scope: `src/v2/hooks/ArtCoinsHookV2.sol`, `src/v2/hooks/libraries/HookCalldata.sol`, `src/v2/interfaces/IArtCoinsHookV2.sol`, and how the hook works with `ArtCoinsTokenV2` (tax modes, D34 netting), `ArtCoinsLpLockerV2`, `ArtCoinsFeeEscrowV2`, `FeeDelivery`, `ArtCoinsMevLinearSkimV2`. reviewed against the working tree on 2026-10-06. note: the author changed the hook while this review was running (VENUE inflows now reported, D34 wiring). line numbers below are for the current working tree.

proofs: `test/v2/review-v2/hook/HookV2Review.fork.t.sol` (fork, pinned block 26,130,269, uses the author's `HookV2ForkBase`). run:

```
/tmp/claude-0/forge.sh test --match-path "test/v2/review-v2/hook/*" \
  --skip "test/[A-Z]*" --skip "test/legacy/**" --skip "test/mocks/**" --skip "test/v2/[A-GI-Z]*" \
  --skip "test/v2/review/**" --skip "test/v2/harness/**" --skip "test/v2/p1/**" \
  --skip "test/v2/mocks/[A-GI-Z]*" --skip script -vv
```

5 tests, 5 pass. the skip list only keeps compile time down. nothing under `src/` had to be skipped, and `src/v2/ArtCoinsFactoryV2.sol` compiled.

## findings

| id | sev | title | evidence | attack path | proof | fix |
|---|---|---|---|---|---|---|
| V2H-01 | high | frozen recipients run their own code inside the victim's unlocked PoolManager. a bounty recipient can revert chosen swaps, take VENUE buyers' coin as tax, and front run | probe `ArtCoinsHookV2.sol:488-499` (150k gas), bounty and protocol pushes `:455-456` via `FeeDelivery.sol:195` (50k + 2300 stipend), referral `:475-486`. the flow grant or attest at `:389-396` runs before the pushes at `:399-407` | see V2H-01 detail | trace only. I chose not to write a working hostile recipient contract | no recipient code while the PoolManager is unlocked. see detail |
| V2H-02 | medium | HARD: add then remove (or increase then decrease) in one unlock leaves a free IN grant equal to the position's principal. D34 does not close this, although h1-notes says it does | marker `:254-259`, remove skipped when marked `:299-306`, add always reports `:279-281`. token `_netGrant` only nets what the hook reports | in one unlock: add X coin of liquidity, which grants IN X. remove it: the position is marked, so no OUT is reported to net against. net coin delta is 0, so nothing consumes IN X. that X can then cover a non canonical coin inflow in the same tx (side v4 pool sell, settle into claims), which `test_hard_sideV4PoolSettle_reverts` is meant to forbid. it costs only gas | `test_V2H02_hard_addThenRemoveSameTx_leavesInGrant` (leftover 4.76e18 coin wei), `test_V2H02_hard_increaseThenDecreasePrior_leavesInGrant` | in HARD, skip the marker: always report the remove as OUT, and D34 cancels it against the add's IN. this also removes the "increase then decrease reverts" residual. keep the marker for VENUE only (tstore only when `taxMode == VENUE`) |
| V2H-03 | low | partial fill refund goes to the PoolManager caller. via the universal router it is stranded forever. via routers that sweep their balance, anyone can push it out to a third party | `:402-405`. escrow `claim` is permissionless `ArtCoinsFeeEscrowV2.sol:87-90`. UR `receive` accepts only WETH9 or the PoolManager (`lib/universal-router/contracts/UniversalRouter.sol:30-32`) | UR user, partial fill (V4Router uses min/max price limits, so this needs liquidity exhaustion, e.g. buy past the last launch position). refund is credited to UR. `claim(UR)` reverts, `claimTo` needs `msg.sender == UR`, owner rescue cannot touch owed balances. for a router that forwards `address(this).balance` to its caller, anyone calls `claim(router)` and the next caller gets the refund | trace | optional refund address in hookData (only the swapper's own refund is at stake), else the sender. or document that integrators must call `claimTo` |
| V2H-04 | low | H13 fix only blocks direct PoolManager callers. every router user can name its own wallet as referrer | `:439` compares against `sender` (the router) | user swaps via UR with `referrer = own EOA`, gets `min(maxRef, protocol share)` of volume back from the protocol leg. bounded by the frozen per pool cap (at most 1%) | trace | accept as a capped rebate and document it, or let `referralPayout` keep a registry of eligible referrers |
| V2H-05 | low | referral and event "volume" base depends on swap shape | `:372` (exact in buy: trader input incl. skim; exact out sell: trader output after skim), `:383` (exact in sell: pool output before skim; exact out buy: pool input excl. skim) | the same trade pays a referral off a base that differs by up to `bps` depending on shape. `SkimSplit.quoteVolume` is not comparable across shapes | trace | use one base everywhere, e.g. pool side `r` |
| V2H-06 | low | price limited exact out sell can leave the seller owing eth at the PoolManager | `:327` grosses up, `:336` books +s; fill `r < s` makes the caller's eth delta `r - s < 0` | a seller whose limit allows a fill smaller than the grossed skim pays coin and eth, and gets eth back later via escrow. routers that only expect to take eth revert. the author's test checks only the net after the refund | trace (`test_skim_exactOutPriceLimited_refundsUnfilled` shape with a tighter limit) | cap `s` at the realized output in afterSwap and refund through the delta, or document it |
| V2H-07 | info | constructor does not check that the escrow lists the hook as core depositor | `:110-129` (only `setFeeEscrow` checks, `:631-638`) | wrong deploy order: every failed push or refund reverts swaps until the owner calls `setFeeEscrow`. D36 relies on the deploy script | n/a | assert in the deploy script (D36), or mine the address first and require `isCoreDepositor` in the constructor |
| V2H-08 | info | recipients that can never claim are accepted | `_validateSkim :594-606` | `bountyRecipient` or `protocolRecipient` set to the hook, the PoolManager or the escrow: the push fails, the escrow credits an address that can never receive eth (hook `receive` takes eth only from the PoolManager, the others have no `receive`). fees stranded | trace | reject `address(this)`, `poolManager` and `_globals.feeEscrow` |
| V2H-09 | info | the hook takes the skim before the trader settles (exact in buy) | `:387` | works only while the PoolManager holds eth from other pools. on mainnet it does. on a fresh chain with only coin side launch liquidity, the first exact in buy reverts on `take` | trace | none needed for mainnet, note for other chains |
| V2H-10 | info | owner can point future failed push and refund credits at any contract that answers `constantsHash` and `isCoreDepositor(hook) == true` | `:631-638` | owner trust (D7, D20). single eoa | n/a | runbook item. optionally pin the escrow as immutable |

### V2H-01 detail

what a recipient can do with the gas it gets, while the victim's unlock is open:

| effect | mechanism | owner lever |
|---|---|---|
| revert any swap it chooses, e.g. sells only (honeypot on a pool flagged official v2) | leave any nonzero delta on itself (a 1 wei `settle{value}` costs well under 10k gas). `PoolManager.unlock` then reverts `CurrencyNotSettled`. it can tell direction by comparing pool price in the probe against the price at push time, or filter by `tx.origin` | none. push gas min 10k (+2300 stipend) is enough. the stream floor max of 10 eth is a balance the recipient controls. recipients are frozen (D7) |
| VENUE: take buyers' coin | the bounty push runs after `attestCanonicalBudget` (`:389-396` before `:399-407`). the recipient spends the buyer's budget on its own PoolManager coin outflow (e.g. claims it holds), so the buyer's take is taxed in full. D10 lets `taxSink == bountyRecipient`, so the tax goes to the recipient. router min out checks the PoolManager delta, not the coin received | none |
| HARD: revert buys or sells | spend the OUT or IN grant meant for the victim's take or settle | none |
| front run every swap, including private orderflow | probe runs before the swap with 150k gas (500k at the owner max) | lower stream gas. this only limits the attack, because the bound is 30k |

who can do this: whoever sets `bountyRecipient` at launch. that is the deployer (`ArtCoinsFactoryV2.sol:211,479`), so anyone once the factory is opened (`deprecated = false`). it is also exposed if a legitimate recipient is upgradeable or compromised. `referralPayout` and `protocolRecipient` come from factory storage (owner trust). the pool extension (2M gas, allowlisted) is the same class but owner trusted.

this breaks the stated invariants: DESIGN b2 ("no recipient behavior ... can revert a swap"), d1 ("delivery never reverts its caller"), D35 ("cannot revert or reorder the swap"). the escrow fallback does not help, because the push itself succeeds.

fix, in order of preference:
1. no recipient code during the unlock: credit legs to the escrow (pull, about 25k per first credit and 5k after), or push with gas 0 so only the 2300 stipend is forwarded. under 2300 gas a recipient cannot send value (9000) or write storage (EIP-2200 sentry), so it cannot change a PoolManager delta.
2. drop the stream probe (D35). a stipend only probe is useless.
3. if pushes stay, at least deliver legs before `_tokenFlow` (closes the budget theft for single swap txs only).
4. in the factory, allow only EOAs or factory allowlisted contracts as `bountyRecipient`, and do not allow `taxSink == bountyRecipient` (D10) unless the recipient is allowlisted.

## claims that hold

| claim | how verified |
|---|---|
| skim math, all four shapes. exact in buy and exact out sell charged in beforeSwap (`s = a·bps/D`, `s = a·bps/(D-bps)`), trued up on fill `skim = charged·r/requested`. unspecified shapes charged on realized `r` with the same gross up | code walk against `PoolManager.swap` hook delta order. author tests `test_skim_*` |
| `charged == skim + refund` exactly. legs sum to `skim` exactly (`bounty + protocol + referral`). rounding dust goes to bounty (`skim - base`) and protocol, never stays in the hook | `:370,402,429-444` |
| no erc6909 on the hook after any swap. no mint/burn. the +s specified delta is booked after afterSwap and netted by `take(charged)` | code. author `test_hookHoldsNothing_afterEverySwapShape` |
| transient skim slots cannot be crossed by nested swaps or other pools: no external call between `tstore` (`:331-332`) and `tload`/clear (`:362-365`). probe runs before the store, pushes after the clear. nested unlocks are impossible | code walk |
| module: staticcall (no state change, no reentry with effect), 100k gas, returndata size bound read after binding `ok` (`:520-521`), clamp to [baseline, MAX_SKIM_BPS], baseline on failure, expired at `createdAt + MAX_MEV_WINDOW` for skim and add lock, garbage `active` only reaches the 90% clamp | code. author `test_hookV2_lockEndsAtCapEvenIfModuleLies`, `_revertingModule_` |
| linear skim module: hook only, once, window within [MIN, MAX], start ≤ MAX_SKIM_BPS, end ≤ start and ≤ baseline cap | `ArtCoinsMevLinearSkimV2.sol:66-113` |
| return bomb: no returndata copy anywhere (probe, pushes, notify, extension). the callee pays for its own memory | `:497,484,573`, `FeeDelivery.sol:195` |
| init: only `initializePool` creates pools. `beforeInitialize` always reverts and the PoolManager skips it for the hook's own call. fee is always DYNAMIC. reinit reverts in the PoolManager. token must name hook, pool id and launcher. lp fee set once | `:139-196,228-235` |
| poolInfo and version written once per pool, no writer afterwards. `isOfficialPool` = launcher != 0 | code |
| flags: `getHookPermissions` = DESIGN section 5, low bits 0x2DCC (0x2000+0x800+0x400+0x100+0x80+0x40+0x8+0x4). BaseHook validates against the address | `:721-738`. author `test_hookAddress_flags` |
| position marker key = v4 position identity (pid, PoolManager caller, ticks, salt). PositionManager positions are separated by tokenId salt. `liquidityDelta == 0` routes to afterRemove, so fee collect is attested or granted | code, v4 `Hooks.sol` |
| VENUE D34 wiring (working tree): a canonical sell and an lp add cancel unused budget. remove then re add nets to 0 | `test_hold_venue_removeThenReAdd_noNetBudget`, `test_hold_venue_claimsBuyThenSell_cancelsBudget` (both failed against `590049a` before the author's change) |
| owner: Ownable2Step. delivery params bounded by Constants. `setFeeEscrow` checks hash and core depositor. rescue only reaches balances the hook holds between swaps (zero). in flight eth exists only inside afterSwap, where the owner could reach it only by reentering through a recipient it controls | `:621-685` |
| `receive` only from the PoolManager | `:132-134` |
| HookCalldata never reverts. every offset and length bounded before use. dirty high bits give an empty attribution | `HookCalldata.sol:28-59`. author fuzz |
| locker: collects via its own PositionManager unlock, refuses foreign unlocks. collect is fee only (decrease 0) and is exempt or granted | `ArtCoinsLpLockerV2.sol:268-329` |

## gas (fork, PoolSwapTest, warm pool, no tick crossing)

| swap | v2 NONE | v2 VENUE | v1 live 111 pool (hook 0x636c…) |
|---|---|---|---|
| buy 0.01 eth exact in | 99,329 | 101,909 | 186,852 |
| sell exact in | 95,521 | 97,679 | 182,164 |

not apples to apples. the v1 figure includes the live 111 bounty recipient's `streamForward` (uncapped probe), v1 storage accruals and the v1 tax token. the v2 pools use an EOA bounty (no probe) and 111's skim config. a v2 pool with a contract bounty recipient above the stream floor adds that recipient's `streamForward` cost, up to 150k. test `test_gas_v2_vs_v1Live`.

## not verified

| item | why |
|---|---|
| V2H-01 end to end | deliberately no hostile recipient contract. the mechanics are standard v4 (`unlock` checks `NonzeroDeltaCount`, native `settle` credits `msg.value` when no currency is synced). the gas estimate for a 1 wei settle at the 10k push minimum (~5k inside the callee) is not measured |
| front running from inside the probe at 150k | a nested swap on the hooked pool (nested probe, take, three pushes) may need more than 150k. at the 500k owner max it fits by estimate. not measured |
| UR refund stranding on a live UR | no partial fill route through the live UR was built |
| D34 token netting under eager settle orders (a router that settles a gross amount after an opposite flow has already netted the grant down) | token scope, in progress by another agent |
| sizes at the ci profile | not rebuilt. author reports 16,230 bytes |
| HARD `donate` path | coin donation needs an IN grant, eth donation is untouched. not tested |
| live 111 recipient (0x8C72…) behavior | v1 pool, out of scope |
