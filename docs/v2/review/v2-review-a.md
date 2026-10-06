# v2 review a: token, deployer, locker, escrow, delivery, mev module, keepers

independent review of the finished v2 packages. reviewer did not write the code. scope: `src/v2/ArtCoinsTokenV2.sol`, `utils/ArtCoinsDeployerV2.sol`, `libraries/TaxVenues.sol`, `lp-lockers/ArtCoinsLpLockerV2.sol`, `ArtCoinsFeeEscrowV2.sol`, `libraries/FeeDelivery.sol`, `mev-modules/ArtCoinsMevLinearSkimV2.sol`, `keepers/CollectFlushKeeperV1.sol`, `keepers/ArtCoinsKeeperV2.sol`, their interfaces, `src/Constants.sol`. the tax grants are half token, half hook, so the hook's liquidity callbacks (`src/v2/hooks/ArtCoinsHookV2.sol`, in progress) were read for that path only.

proofs: `test/v2/review-v2/a/V2A_TaxBypass.t.sol`. local v4 from the pinned lib/v4-core source, the real hook at a mined address, the real token. no rpc.

```
/tmp/claude-0/forge.sh test --match-path "test/v2/review-v2/a/**" --skip "test/v2/harness/**" --skip "test/v2/review/**" --skip script -vv
```

RESULTS_PLACEHOLDER

## findings

| id | sev | title | evidence | proof |
|---|---|---|---|---|
| V2A-01 | high | canonical liquidity round trips mint free HARD flow grants and VENUE budget; b1 is only half fixed | hook `ArtCoinsHookV2.sol:268-285`, `:288-307`; token `ArtCoinsTokenV2.sol:316-330`, `:337-363` | `test_V2A01_hard_addThenRemove_mintsFreeInGrant_sidePoolSellSettles`, `test_V2A01_hard_removeThenReadd_mintsOutGrant_sidePoolBuyTakes`, `test_V2A01_venue_removeThenReadd_sidePoolBuyUntaxed` |
| V2A-02 | medium | FT-07 not fixed: the exempt set takes any contract, so a deployer exempts its own forwarder (or the v4 PositionManager / universal router, which have public sweeps) and buys untaxed | token `:226-247`; factory `ArtCoinsFactoryV2.sol:412-421`; ui `ui/src/lib/encodeV2.ts:310-312,469` | `test_V2A02_venue_deployerForwarderExempt_buysUntaxed` |
| V2A-03 | low | HARD: listing a v2 pair after third parties added liquidity freezes their counter asset too, forever | token `:316-322`, `:424-439` | trace below |
| V2A-04 | low | venue admin is not moved by `updateAdmin` and has no transfer path; an admin handover leaves the venue (and HARD freeze) power with the old admin | token `:215`, `:441-451`, `:517-523` | read |
| V2A-05 | low | generic keeper step gas is a hard ceiling, not a floor; a collect above 950k gas reverts `InsufficientGas` on every run whatever the tx gas | `ArtCoinsKeeperV2.sol:30-34`, `:148-167` | estimate below, not measured |
| V2A-06 | low | escrow wiring is not enforced at construction: hook ctor skips the core depositor check its setter has, locker never checks depositor status | hook `:110-122` vs `:632-639`; locker `:387-392` | read |
| V2A-07 | info | locker storage default `keeperRewardBps = 50`, D28 says 0 and relies on the deploy script | locker `:61` | read |
| V2A-08 | info | escrow `storeFees` is `nonReentrant`: a locker collect run from inside an escrow claim callback reverts when a coin push falls back | escrow `:51-55` | read |
| V2A-09 | info | grants and budget are per tx, not per caller: inside an erc-4337 bundle one op's unused canonical grant covers another op's side pool flow | token `:356-383` | read (t1 residual, extends to bundles) |
| V2A-10 | info | both keepers read any empty revert as out of gas; a step that reverts empty for another reason bricks the keeper for that coin | `CollectFlushKeeperV1.sol:72-89`, `ArtCoinsKeeperV2.sol:160` | read |

### V2A-01 high: free grants and budget from canonical liquidity round trips

b1 sets a transient marker in `_beforeAddLiquidity` and skips the grant in `_afterRemoveLiquidity` when the removed position was added in this tx. that blocks one order only. the hook still grants on every add, and still grants on the remove of any position that existed before the tx, even if it is put back.

| path | mode | capital | what the attacker gets per tx |
|---|---|---|---|
| add L, remove L, same salt, one unlock | HARD | none (flash accounting nets it, 1 to 2 wei dust) | IN grant = coin principal of L, unbounded. erc20 coin enters the PoolManager for side pool sells and side pool liquidity |
| remove a parked pre tx position, re add it later in the unlock | HARD | the parked position (any size, earns lp fees meanwhile) | OUT grant and IN grant = its coin. side pool buys leave as erc20; erc6909 claims exit as erc20 (breaks the D24 "cannot exit" claim) |
| same remove then re add | VENUE | the parked position | budget = its coin; side v4 pool buys up to that size untaxed. this is FT-01/H14 with capital parked instead of zero capital |

attack path (HARD sell, zero capital), from the test: `unlock { modifyLiquidity(canon, +1e22, salt 99); modifyLiquidity(canon, -1e22, salt 99); swap(side, coin for eth, 100e18); sync; coin.transfer(pm, 100e18 + dust); settle; take eth }`. baseline without the two modifies reverts `CanonicalFlowRequired(attacker, pm, 100e18)`. with them the sell settles and about 1e4 coin of in grant is left for the rest of the tx.

attack path (HARD buy, VENUE buy): `unlock { modifyLiquidity(canon, -Lparked); swap(side, eth for coin); modifyLiquidity(canon, +Lparked); settle eth; take coin }`. HARD baseline reverts `CanonicalFlowRequired`; VENUE baseline pays 15% to DEAD, exploit pays 0. the parked position is restored exactly.

impact: HARD's whole promise (coin moves in and out of the PoolManager only through canonical trades) is void, and VENUE's tax on side v4 pools is optional for anyone with a parked lp position. no theft; the loss is the creator's and protocol's skim and lp fees and the tax. rated as FT-01 and H14 were.

fix (hook): never let liquidity ops in one tx net out. simplest: a transient per pool "liquidity direction" flag set by the first canonical add or remove in a tx (tax modes only); an add after a remove, or a remove after an add, in the same tx reverts. keep the b1 marker. residual after the fix: canonical buy then add (or remove then canonical sell) leaves grants, but each costs a real canonical trade. regression tests: the three proofs above must revert, plus add A then remove pre tx B in one tx. revocation on the token side does not work: the attacker consumes the grant before the re add.

### V2A-02 medium: exempt set accepts any contract

the token and the factory check only `code.length != 0`, uniqueness and `!= token`. the t1 note says "an eoa cannot be exempt, FT-07". a 10 line forwarder deployed before launch qualifies; the proof buys 100 coin from a listed venue through it untaxed while a normal buyer pays 20%. the sink may be the bounty recipient, which is also deployer input, so "20% tax to my address, my proxy exempt" is still one config away on a public factory (the factory ships deprecated, the owner flips it). worse, the token's own doc suggests exempting "a position manager": the v4 PositionManager (SWEEP) and the universal router (SWEEP) hold nothing between calls and let anyone sweep, so exempting either makes the tax optional for everyone (`take(coin, posm)` then `SWEEP` to self).

fix: drop the deployer supplied exempt list. exempt only addresses the factory injects (the coin's locker, the fee swapper of that coin) or nothing: locker collects are already covered by the remove budget. if a list stays, the factory must check each entry against an owner allowlist and never allow anything with a public sweep.

### V2A-03 low: HARD venue listing freezes third party counter assets

a HARD coin can be paired on an unlisted v2 pair by anyone (only the PoolManager and listed venues are walled). once the venue admin lists that pair (`addDerivedTaxVenue`), `pair.burn` transfers both tokens and reverts on the coin leg, so lp weth is stuck with no removal path. v3 lps can still `collect` the counter token alone. t1 notes call this "freezes coin inside it (lp included)"; the counter asset is not mentioned. fix: document it in the launch ui and token docs next to HARD ("listing a pool traps its lps' paired asset"),. a "list only empty pools" rule is griefable with a dust transfer, so documentation is the practical fix.

### V2A-04 low: venue admin decoupled from token admin

`venueAdmin` defaults to `tokenAdmin` at launch and has no setter except renounce. `updateAdmin` moves rate, image, metadata and renderer powers but not venue powers. after a handover (sale, multisig migration) the old admin can still add venues, which in HARD freezes them. fix: add `transferVenueAdmin` (two step) or note it in the launch ui.

### V2A-05 low: keeper gas caps

`_step` forwards exactly `cost + 50k`. a collect on a 14 position coin with the real hook pays a token call per `afterRemoveLiquidity` on top of the v1 measured 658k, and the locker forwards up to 150k per native push (7 recipients, gas burning recipients are escrowed after burning the full 150k). anything above 950k fails out of gas inside the step, returns empty, and the keeper reverts `InsufficientGas(1)` on every run, whatever gas the caller sends. liveness only: `collectRewards` stays callable directly. fix: forward `gasleft() - reserve` and keep the constants as minimums.

### V2A-06 low: escrow wiring

`ArtCoinsHookV2` constructor runs `_checkConstants(escrow)` only; `setFeeEscrow` also requires `isCoreDepositor(hook)`. the locker's `_setFeeEscrow` checks neither. with the wrong deploy order every failed push reverts the swap (hook) or the collect (locker) until fixed. fix: check `isDepositor(address(this))` in the locker setter, and assert the hook is core in the deploy script (the hook address is known from the miner before deploy, so `escrow.addDepositor(predicted, true)` can precede it).

### V2A-07 to V2A-10 info

| id | note |
|---|---|
| 07 | make the storage default 0 to match D28 instead of trusting the script |
| 08 | only reachable through a reentrant collect from a claim callback; the reentrant call reverts, nothing is lost |
| 09 | not exploitable for theft (a grant only permits a transfer the PoolManager already owes); it widens V2A-01 style dodges to bundles |
| 10 | live 111 and v2 lockers revert with selectors, so not hit today; a gas probe with `gasleft()` before and after is more robust than the empty data test |

## claims that hold

| claim | check |
|---|---|
| HARD grant then revert in the same unlock | tstore is journaled; a reverting frame (or try/catch around a swap) rolls the grant back |
| HARD direction | coin is always currency1 (eth sorts first); hook reads `amount1`; token derives the pool id with currency0 = 0; the hook never alters the coin side delta (skim is eth only) |
| HARD arithmetic | grants add with checked math (int128 bounded inputs), consume reverts above the remaining amount |
| HARD prepay | a transfer before the swap reverts unless an earlier grant exists in the tx (documented limit) |
| VENUE b1 order add then remove | marker suppresses the budget (only the reverse order leaks, V2A-01) |
| VENUE budget scope | drawn only when `from == poolManager`, also for exempt recipients; listed v2/v3 outflows never draw it |
| tax math | floor rounding; untaxed only below `BPS / bps` wei (7 wei at 15%); `taxBps <= taxBpsMax <= 2000` in ctor and setter; NONE accepts no tax data |
| venue lifecycle | add only; PoolManager, hook, launcher, token refused; probe gas capped at 30k and one word; derived venues are CREATE2 hashes (no preimage aim); renounce zeroes the admin |
| deployer | factory only, launcher must be the factory; factory salts with `msg.sender` and `keccak256(abi.encode(c))` (injective); initcode carries every ctor arg; no selfdestruct or delegatecall, so no metamorphic redeploy |
| LF-01 | `collectRewards` reverts when the PoolManager is unlocked; it opens its own unlock via `modifyLiquidities`; `nonReentrant` is global, so a recipient push cannot re enter for any coin |
| collect accounting | eth can only arrive from the PoolManager (`receive` guard); coin delta measured across a window with no third party code (posm is locked, erc20 has no hooks); the paired side is native only |
| position ids | `nextTokenId()` read before one locked `modifyLiquidities` that mints n sequential ids; no other mint can interleave |
| split dust | last slot takes the remainder (locker); hook legs sum to the skim exactly |
| rescue | locker holds nothing between calls and rescue is `nonReentrant`; escrow rescue is capped at `balance - totalOwed[token]`, native and erc20 keyed separately |
| escrow | effects before the push; `selfClaimOnly` read at claim time; core depositors cannot be removed or downgraded |
| FeeDelivery gas griefing | the caller can starve a push below its cap only by keeping under cap/63 gas (159 gas at 10k, 2.4k at 150k), which cannot pay the escrow fallback, so the tx reverts; native returndata never copied, erc20 at most one word |
| mev module | hook only init, once; window and start bounded; decay monotone and hits `end` at the window; a module bound to another hook reverts the launch |
| keeper reward | bps and cap bounded by Constants; eth side only; unpayable keeper gets 0, collect continues |

## not verified

| item | why |
|---|---|
| hook, factory, fee swapper, burn router, protocol fee, extensions, renderer | in progress; only the hook's liquidity and tax callbacks were read |
| keeper gas floors against the real v2 stack | needs factory plus locker plus posm; V2A-05 is an estimate |
| locker with the real hook and a taxed coin end to end | locker tests use a stub hook and a mock token; collect under HARD/VENUE relies on the remove grant, read only |
| fork runs | proofs run on local v4 from source; no live state is involved |
| CollectFlushKeeperV1 against live 111 | existing fork tests not rerun |
