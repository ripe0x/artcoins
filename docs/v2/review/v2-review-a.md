# v2 review a: token, deployer, locker, escrow, delivery, mev module, keepers

independent review of the finished v2 packages; the reviewer did not write the code. scope: `src/v2/ArtCoinsTokenV2.sol`, `utils/ArtCoinsDeployerV2.sol`, `libraries/TaxVenues.sol`, `lp-lockers/ArtCoinsLpLockerV2.sol`, `ArtCoinsFeeEscrowV2.sol`, `libraries/FeeDelivery.sol`, `mev-modules/ArtCoinsMevLinearSkimV2.sol`, `keepers/CollectFlushKeeperV1.sol`, `keepers/ArtCoinsKeeperV2.sol`, their interfaces, `src/Constants.sol`. the tax grants are half token, half hook, so the hook's liquidity and swap tax callbacks (`src/v2/hooks/ArtCoinsHookV2.sol`) were read for that path only.

code reviewed: HEAD `3f70dea` plus the uncommitted hook working tree that implements D43 (05:12 utc). D34 (token netting) and D43 (HARD reports every removal) landed during the review; V2A-01 is written and proved against them.

## proof run

file `test/v2/review-v2/a/V2A_TaxBypass.t.sol`. local v4 from the pinned lib/v4-core source, the real `ArtCoinsHookV2` at a mined address, the real `ArtCoinsTokenV2`, no rpc. the two stack suites use inline `forge-config: default.isolate = true` so each top level call is its own tx (forge otherwise keeps transient storage across calls; it does not isolate setUp, so positions that must predate the attack are parked inside the test).

```
/tmp/claude-0/forge.sh test --match-path "test/v2/review-v2/a/**" --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script --skip "src/v2/ArtCoinsFactoryV2.sol" --skip "test/v2/FactoryV2.fork.t.sol" -vv
```

the two extra skips: the factory working tree did not compile at run time (`ArtCoinsDeployerV2.factory` used in `abi.encodeCall`, factory line 697, D38 work in progress). nothing in this suite imports it.

| test | result | numbers |
|---|---|---|
| `test_V2A01_hard_addThenRemove_mintsFreeInGrant_sidePoolSellSettles` | pass | baseline reverts `CanonicalFlowRequired`; exploit sells 100 coin on a side pool for 90.66 eth, zero capital |
| `test_V2A01_hard_removeThenReadd_mintsOutGrant_sidePoolBuyTakes` | pass | baseline reverts; exploit takes 9.87 coin bought on a side pool as erc20, parked position restored |
| `test_V2A01_venue_removeThenReadd_sidePoolBuyUntaxed` | pass | baseline net 8.39 coin (15% to DEAD); exploit net 9.68 coin, DEAD unchanged |
| `test_V2A02_venue_deployerForwarderExempt_buysUntaxed` | pass | buyer gets 80 of 100 (20% tax); deployer via its exempt forwarder gets 100 |

## findings

| id | sev | title | evidence | proof |
|---|---|---|---|---|
| V2A-01 | high | canonical liquidity round trips still mint usable HARD grants and VENUE budget: D34 nets at grant time, so a grant spent before the opposite report lands is never cancelled | hook `ArtCoinsHookV2.sol:263-339` (`_beforeAddLiquidity`, `_afterAddLiquidity`, `_afterRemoveLiquidity`); token `ArtCoinsTokenV2.sol:316-330`, `:337-363`, `:386-416` | the three V2A01 tests |
| V2A-02 | medium | FT-07 not fixed: the exempt set takes any contract, so a deployer exempts its own forwarder (or the v4 PositionManager / universal router, which have public sweeps) and buys untaxed | token `:226-247`; factory `ArtCoinsFactoryV2.sol:433-442`; ui `ui/src/lib/encodeV2.ts:310-312,469` | `test_V2A02_venue_deployerForwarderExempt_buysUntaxed` |
| V2A-03 | low | HARD: listing a v2 pair after third parties added liquidity freezes their counter asset too, forever | token `:316-322`, `:456-472` | trace below |
| V2A-04 | low | venue admin is not moved by `updateAdmin` and has no transfer path; an admin handover leaves the venue (and HARD freeze) power with the old admin | token `:215`, `:474-483`, `:549-555` | read |
| V2A-05 | low | generic keeper step gas is a hard ceiling, not a floor; a collect above 950k gas reverts `InsufficientGas` on every run whatever the tx gas | `ArtCoinsKeeperV2.sol:30-34`, `:148-167` | estimate, not measured |
| V2A-06 | info | escrow wiring is not enforced in code: hook ctor skips the core depositor check its setter has; the locker never checks depositor status. D36 moves this to the deploy script | hook `:134-146` vs `:663-670`; locker `:393-398` | read |
| V2A-07 | info | locker storage default `keeperRewardBps = 50`; D28 says 0 and relies on the deploy script | locker `:62` | read |
| V2A-08 | info | escrow `storeFees` is `nonReentrant`: a locker collect run from inside an escrow claim callback reverts when a coin push falls back | escrow `:51-55` | read |
| V2A-09 | info | grants and budget are per tx, not per caller: in an erc-4337 bundle one op's unused grant covers another op's side pool flow | token `:356-416` | read |
| V2A-10 | info | both keepers read any empty revert as out of gas; a step that reverts empty for another reason bricks the keeper for that coin | `CollectFlushKeeperV1.sol:72-89`, `ArtCoinsKeeperV2.sol:160` | read |

### V2A-01 high: grants spent before they are netted

D34 makes the token cancel an outstanding opposite allowance when a new canonical flow is reported, and D43 makes HARD report every removal. both act at report time. v4 lets the unlocker interleave pool calls with `sync/transfer/settle` and `take`, so an allowance consumed before the cancelling report arrives stays consumed. the canonical pool never trades.

| path (one unlock) | mode | capital | effect |
|---|---|---|---|
| add L to canonical (in grant a); side pool sell X; settle X+2 coin now; remove L (out report nets only the unused a-X-2) | HARD | none, flash accounting nets the add and remove | erc20 coin enters the PoolManager for a side pool sell; unused out grant ≈ X is left for a side buy too |
| remove a parked pre tx position (out grant a); side pool buy W; take W now; re add the position (in report nets only a-W) | HARD | the parked position (any size, earns lp fees meanwhile) | side pool coin leaves as erc20; erc6909 claims exit the same way (breaks D24 "cannot exit as erc20") |
| same remove, buy, take, re add | VENUE | the parked position | budget a covers the side pool take, untaxed; FT-01/H14 with parked capital instead of zero capital. the b1 marker does not apply because the position predates the tx |

impact: HARD's promise (coin moves in or out of the PoolManager only through canonical trades) and VENUE's side v4 pool tax are both optional for a motivated trader. no theft; the loss is the creator's and protocol's skim and lp fees and the tax. same class and rating as FT-01 and H14.

fix (hook, no token change): a transient per pool, per tx liquidity direction lock in tax modes. the first canonical `modifyLiquidity` in a tx records add or remove; a later op in the other direction reverts (`liquidityDelta == 0` fee collects count as remove). keep the b1 marker for VENUE. with only adds, every in grant is matched by coin the caller really owes the canonical pool; with only removes, every out grant is coin really leaving it. residuals after the fix all cost a canonical trade (buy then add, remove then sell). token side netting cannot close this: it has no end of unlock signal. regression: the three proofs must revert, plus add A then remove pre tx B, plus the locker collect (remove only) and launch placement (add only) still pass.

### V2A-02 medium: exempt set accepts any contract

the token and the factory check only `code.length != 0`, uniqueness and `!= token`. the t1 note says "an eoa cannot be exempt, FT-07". a 10 line forwarder deployed before launch qualifies; the proof buys 100 coin from a listed venue through it untaxed while a normal buyer pays 20%. the sink may be the bounty recipient, which is also deployer input, so "20% tax to my address, my proxy exempt" is one config away on a public factory. the token's own comment suggests exempting "a position manager": the v4 PositionManager (`SWEEP`) and the universal router (`SWEEP`) let anyone sweep their balance, so exempting either makes the tax optional for everyone (`take(coin, posm)` then sweep to self).

fix: drop the deployer supplied list. exempt only what the factory injects (the coin's locker and that coin's fee swapper), or nothing: locker collects are already covered by the remove budget. if a list stays, check each entry against an owner allowlist with no sweepable contracts.

### V2A-03 low: HARD venue listing freezes third party counter assets

anyone can pair a HARD coin on an unlisted v2 pair (only the PoolManager and listed venues are walled). once the venue admin lists it (`addDerivedTaxVenue`), `pair.burn` sends both tokens and reverts on the coin leg, so the lps' weth is stuck with no removal path. v3 lps can still `collect` the counter token alone. t1 notes say "freezes coin inside it (lp included)"; the counter asset is not mentioned. fix: say it in the launch ui and token docs next to HARD ("listing a pool traps its lps' paired asset"). a "list only empty pools" rule is griefable with a dust transfer, so documentation is the practical fix.

### V2A-04 low: venue admin decoupled from token admin

`venueAdmin` defaults to `tokenAdmin` and has no setter but renounce. `updateAdmin` moves rate, image, metadata and renderer powers, not venue powers. after a sale or multisig migration the old admin can still list venues, which in HARD freezes them. fix: a two step `transferVenueAdmin`, or show the split in the ui.

### V2A-05 low: keeper gas caps

`_step` forwards exactly `cost + 50k`. a 14 position collect with the real hook pays a token call per `afterRemoveLiquidity` on top of the v1 measured 658k, and the locker forwards up to 150k per native push (7 slots; a gas burning recipient burns the full 150k before its escrow fallback). anything above 950k runs out of gas inside the step, returns empty, and the keeper reverts `InsufficientGas(1)` on every run, whatever gas the caller sends. liveness only: `collectRewards` stays directly callable. fix: forward `gasleft() - reserve`, keep the constants as minimums.

### info notes

| id | note |
|---|---|
| 06 | D36 accepts this as a deploy order rule; the locker setter could still check `isDepositor(address(this))` cheaply |
| 07 | make the storage default 0 to match D28 |
| 08 | only reachable through a reentrant collect from a claim callback; that call reverts, nothing is lost |
| 09 | a grant only permits a transfer the PoolManager already owes, so no theft; it widens V2A-01 style dodges to bundles |
| 10 | the live 111 and v2 lockers revert with selectors, so not hit today; comparing `gasleft()` before and after the call is more robust than the empty data test |

## claims that hold

| claim | check |
|---|---|
| HARD grant then revert inside one unlock | tstore is journaled; a reverting frame (or try/catch around a swap) rolls the grant back |
| HARD direction | coin is always currency1 (eth sorts first); hook reads `amount1`; token derives the pool id with currency0 = 0; the hook never alters the coin side delta (skim is eth only) |
| HARD arithmetic | grants add with checked math on int128 bounded inputs; consume and `_netGrant` never underflow |
| HARD prepay | a transfer before the swap reverts unless an earlier grant exists in the tx (documented limit) |
| D34 on plain round trips | buy then sell, add then remove, remove then re add leave nothing when no transfer happens between them (read; V2A-01 needs the interleaved transfer or take) |
| VENUE b1 add then remove | marker suppresses the budget |
| VENUE budget scope | drawn only when `from == poolManager`, also for exempt recipients; listed v2/v3 outflows never draw it |
| tax math | floor rounding; untaxed only below `BPS / bps` wei (7 wei at 15%); `taxBps <= taxBpsMax <= 2000` in ctor and setter; NONE accepts no tax data |
| venue lifecycle | add only; PoolManager, hook, launcher, token refused; probe gas capped at 30k, one word read; derived venues are CREATE2 hashes (no preimage aim); renounce zeroes the admin |
| deployer | factory only, launcher must be the factory; factory salts with `msg.sender` and `keccak256(abi.encode(c))` (injective); initcode carries every ctor arg; no selfdestruct or delegatecall, so no metamorphic redeploy |
| LF-01 | `collectRewards` reverts when the PoolManager is unlocked and opens its own unlock via `modifyLiquidities`; the global `nonReentrant` stops a recipient push from re entering for any coin |
| collect accounting | eth can only arrive from the PoolManager (`receive` guard); the coin delta window runs no third party code (posm locked, erc20 without hooks); paired side is native only |
| position ids | `nextTokenId()` read before one locked `modifyLiquidities` that mints n sequential ids |
| split dust | last slot takes the remainder (locker); hook legs sum to the skim exactly |
| rescue | locker holds nothing between calls and rescue is `nonReentrant`; escrow rescue capped at `balance - totalOwed[token]`, native and erc20 keyed apart |
| escrow | effects before the push; `selfClaimOnly` read at claim time; core depositors cannot be removed or downgraded |
| FeeDelivery gas griefing | a caller can starve a push below its cap only by keeping under cap/63 gas (159 at 10k, 2.4k at 150k), which cannot pay the escrow fallback, so the tx reverts; native returndata never copied, erc20 at most one word |
| mev module | hook only init, once; window and start bounded; decay monotone and lands on `end` at the window; a module bound to another hook reverts the launch |
| keeper reward | bps and cap bounded by Constants; eth side only; an unpayable keeper gets 0 and collect continues |

## not verified

| item | why |
|---|---|
| hook beyond the tax callbacks, factory, fee swapper, burn router, protocol fee, extensions, renderer | out of scope or in progress (factory working tree did not compile during the run) |
| keeper gas against the real v2 stack | needs factory, locker and posm together; V2A-05 is an estimate |
| locker with the real hook and a taxed coin end to end | locker tests use a stub hook and a mock token; collect under HARD/VENUE relies on the remove grant, read only |
| D41 (2,300 gas fee pushes, no stream probe) | the working tree hook drops the stream probe but still pushes with the owner tunable cap (10k..150k); the FeeDelivery griefing row above is for that cap |
| fork runs | proofs use local v4 from source; no live state is involved |
| CollectFlushKeeperV1 against live 111 | existing fork tests not rerun |
