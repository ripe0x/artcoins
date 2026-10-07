# review: hooks + mev modules (second pass)

scope: `src/hooks/**` (ArtCoinsHook base, ArtCoinsHookSkimFee, ArtCoinsHookStaticFee, allowlist, SkimFeeInitLib, SkimFeeConstants), `src/mev-modules/**`, `IArtCoinsHook`, `IArtCoinsMevModule*`, `IPreSwapStream`. legacy hooks not reviewed.

proofs: `test/v2/review/hooks-mev/`. run:

```
/tmp/claude-0/forge.sh test --match-path "test/v2/review/hooks-mev/**" --skip "test/v2/harness/**" --skip script -vv
```

(`--skip` only because a sibling harness file did not compile at the time of writing.) 22 tests, all pass. local tests deploy a fresh PoolManager and run the hook initcode in place at a flag valid address (no HookMiner, no EIP-170 issue). `LiveStack.t.sol` forks mainnet (block ~26130400) and hits the live skim hook `0x636c…` and coin 111's canonical pool; it skips itself when no rpc answers.

live facts read on chain (coin 111 canonical pool `0xf860d8f4…`, tickSpacing 200, ETH/coin):

| field | value |
|---|---|
| baselineSkimBps / bountyBps / maxReferral / lpFee | 6000 (6%) / 8333 / 250 (0.25% of volume) / 5000 (0.5%) |
| bountyRecipient | `0x8C72…CD01`, contract, implements `streamForward` (returns 0) |
| protocolRecipient / referralPayout | `0xed3E…ba9` / `0xB03C…d4c`, both contracts |
| locker / mevModule / extension | `0x866e…` / LinearSkim `0xb038…` (window long over) / none |
| token tax | enabled, 1500 bps, canonicalHook = live hook, admin `0xA96a…` (contract) |

## findings

| id | sev | title |
|---|---|---|
| H1 | high | stream probe decodes outside try: EOA / empty fallback bounty recipient bricks the pool, and the pool's own pushes trigger it |
| H2 | medium | bid leg push reverts the swap; a recipient that rejects ETH bricks the pool forever |
| H3 | low | codeless referralPayout reverts every referred swap (extcodesize revert outside try) |
| H4 | medium | price limited exact in buy is skimmed on amountSpecified, not on the fill (live: 3 ETH skim on a 0.0028 ETH fill) |
| H5 | medium | price limited exact out sell: skim grossed on the requested output can exceed the fill, seller pays ETH to sell |
| H6 | medium | sniper extra not grossed up on exact output: ~24% discount for snipers using exactOutput |
| H7 | medium | sniper extra on exact in is charged on the unfilled amount |
| H8 | low | fee dialing modules allow 180 min, hook kills them at 15 min: LinearFees cliffs from ~54% to base |
| H9 | low | factory gates modules on the base interface only; a skim module on the static hook reverts all swaps for 15 min |
| H10 | low | static fee direction is the inverse of the interface docs |
| H11 | medium | anyone opens pools for any coin on the shared hook with own recipients and fees; only tell is `locker == 0` |
| H12 | low | `setPoolExtension` bypasses the open pool extension ban, works on never initialized pool ids |
| H13 | medium | self referral: swapper names itself in hookData and rebates up to the cap from the protocol leg |
| H14 | high | add then remove canonical liquidity in one unlock mints tax exemption budget at zero cost; side venue buys go untaxed |
| N1..N6 | low/info | see "other observations" |

### H1 high. stream probe bricks swaps

- evidence: `ArtCoinsHookSkimFee.sol:279-282`. `IPreSwapStream.streamForward()` returns `uint256`, so solc skips the extcodesize check and abi decodes the return data in the hook after the call. `try … {} catch {}` only catches a revert inside the callee. empty return data (EOA, or any contract whose fallback succeeds silently, e.g. a Safe with no fallback handler) makes the decode revert in the hook, which bubbles as `WrappedError(hook, beforeSwap, 0x, …)`.
- only call site of `streamForward` in `src`. gate is `br.balance >= PRE_SWAP_STREAM_MIN` (0.01 ETH).
- attack path: no attacker needed. bountyRecipient is frozen at init (no setter). every swap pushes the bid leg to it (`:716`), so its balance crosses 0.01 ETH by itself and from then on every buy and sell reverts. an EOA recovers only by spending below the floor, and the next push re bricks it. an empty fallback contract with no withdraw is permanent. anyone can also push it over the floor with a 0.01 ETH transfer.
- proof: `test_bug_H1_eoaBountyRecipientSelfBricksPool`, `test_bug_H1_emptyFallbackRecipientBricksForever`; control `test_control_H1_noSelectorRecipientIsCaught` (a contract with no fallback reverts inside the call and IS caught).
- live: coin 111 not affected, its recipient implements the selector. any future pool with an EOA or Safe as bounty recipient is.
- probe is also uncapped in gas (`:281`): a recipient can burn 63/64 and leave the swap to OOG. N1.
- fix v2: low level `call` with a gas cap (`Constants.STREAM_GAS_*`), ignore success and return data entirely; or drop the probe and let the recipient stream on its own cadence.

### H2 medium. bid leg push reverts the swap

- evidence: `ArtCoinsHookSkimFee.sol:715-718`, `.call{value: b}("")` with all gas, `revert BidForwardFailed()` on failure. documented as intended.
- attack path: recipient that rejects ETH, runs out of gas, or is later upgraded/paused bricks every swap with a non zero skim. config is frozen, so the brick is permanent.
- proof: `test_bug_H2_rejectingBountyRecipientBricksAllSwaps`.
- fix v2: push with a gas cap, on failure `feeEscrow.storeFeesNative{value: b}(bountyRecipient)`. the escrow is the only external dependency allowed to revert a swap, and it must be immutable, non pausable and accept this hook forever (today: no removeDepositor, no pause, ok).

### H3 low. codeless referralPayout

- evidence: `ArtCoinsHookSkimFee.sol:731-740`. `notify` returns nothing, so solc emits an extcodesize check before the call; that revert is in the hook, outside the try, and the escrow fallback never runs. init only checks `referralPayout != 0` (`SkimFeeInitLib.sol:59`).
- impact: every swap that names a referrer reverts (only those). live payout has code.
- proof: `test_bug_H3_codelessReferralPayoutRevertsReferredSwaps` (trace: "call to non-contract address").
- fix v2: require code at init, and use a low level call with gas cap + escrow fallback.

### H4 medium. skim on the unfilled part (exact in, quote specified)

- evidence: `ArtCoinsHookSkimFee.sol:300-319`. quote specified swaps (exact in buy, exact out sell) compute `totalSkim` from `specifiedAbs = |amountSpecified|` in beforeSwap and return it as the specified delta. v4 then swaps `amountSpecified + skim`; a `sqrtPriceLimitX96` can stop it at any fill, but the hook delta is fixed.
- math, exact in buy, `A` specified, fill `F`: trader pays `F + A*bps/1e5`. effective rate `= A*bps/(F + A*bps)`, unbounded as `F -> 0`. no PoolManager revert: the hook minted exactly the delta it returned, so accounting balances; the excess is a silent over charge.
- quote unspecified swaps (exact in sell, exact out buy, `:337-366`) use the realized delta and are correct (`test_control_H4_exactInSellUsesRealizedDelta`).
- proof local: `test_bug_H4_exactInBuyPartialFillSkimsUnfilledAmount`: 10 ETH specified, 0.505 ETH filled, 0.5 ETH skim, effective 49.7% vs nominal 5%.
- proof live: `test_bug_H4_live_priceLimitedBuyOvercharges`: 50 ETH exact in on coin 111 with a 0.05% price limit filled 0.0028 ETH and paid 3 ETH skim (effective 99.9%). protocol escrow credit asserted equal to the leg sized on 50 ETH.
- who hits it: any router or aggregator that passes a price limit instead of 0 (limit orders, partial fill routers). universal router single swaps with no limit are not affected.
- fix v2: v4 only lets afterSwap return a delta on the unspecified side, so the specified side skim cannot be trued up after the fill. options: (a) for quote specified swaps require `sqrtPriceLimitX96` at the extreme (revert otherwise, router retries without a limit); (b) in afterSwap refund the unfilled share: skim `fill*bps/1e5`, return the difference to the trader as a negative unspecified delta converted at the realized price (complex); (c) charge the skim on the realized output side instead. (a) is simplest and honest.

### H5 medium. exact out sell, seller pays ETH

- same code path, other direction. `totalSkim = A*bps/(1e5-bps)` on the requested ETH out `A`; trader receives `Y - skim` where `Y` is the pool's actual output. if `Y < skim` the trader's ETH delta is negative: it sells tokens AND pays ETH.
- proof: `test_bug_H5_exactOutSellPartialFillMakesSellerPayEth`: 0.25 PCT sold, seller also paid 0.276 ETH.
- fix v2: as H4.

### H6 medium. sniper extra, exact output discount (static hook / base)

- evidence: exact in `ArtCoinsHook.sol:773-774` charges `ppm` of the gross input (`amountIn*ppm/1e6`, deducted from what reaches the pool); exact out `:853` charges `ppm` of the NET input (`|inputDelta|*ppm/1e6`, added on top). the skim hook grosses up (`:594`), the base does not.
- at the default LAYER step 0 (extra 490_000): exact in pays 1/(1-0.49) = 1.96x per unit swapped, exact out pays 1.49x.
- proof: `test_bug_H6_sniperExtraExactOutputDiscount`: same tokens, 1.000 ETH exact in vs 0.760 ETH exact out.
- fix v2: exact out extra `= |inputDelta|*ppm/(1e6-ppm)`.

### H7 medium. sniper extra on unfilled input

- evidence: `ArtCoinsHook.sol:773`, same shape as H4. proof: `test_bug_H7_sniperExtraChargedOnUnfilledInput`: 4.9 ETH extra on a fill under 1 ETH.
- fix v2: as H4 / move to afterSwap realized input.

### H8 low. module window vs hook cap

| module | own max | checks hook cap | effect |
|---|---|---|---|
| LinearFees | 180 min (default 69) | no | killed at creation+15 min: cliff |
| DescendingFees | none | yes (`:102-107`) | ok |
| SniperSteppedFees | 2 h | yes (`:120`) | ok |
| TimeDelay | unbounded ctor | no | lock silently capped at 15 min |
| LinearSkim | 180 min | n/a, skim hook ignores `MAX_MEV_MODULE_DELAY` | LP add lock up to 180 min, reads `operational()` |

- proof: `test_bug_H8_linearFeesCliffAtHookCap`: lp fee 54.2% at t+899s, 1% at t+900s, module still reports ~54%.
- start time: module `startTime = block.timestamp` at `initializeMevModule`, hook window from `poolCreationTimestamp`. factory does both in the same tx (`ArtCoinsFactory.sol:246-264`), so they agree. decay starts at launch, not first swap. holds.
- fix v2: one window constant (`Constants.MAX_MEV_WINDOW`), module init rejects longer, hook enforces `createdAt + MAX` regardless of module (v2 Constants already says this).

### H9 low. skim module on the static hook

- factory `setMevModule` checks `IArtCoinsMevModuleBase` only (`ArtCoinsFactory.sol:135-141`); nothing pairs module kind with hook kind. base `_runMevModule` (`ArtCoinsHook.sol:589`) calls `beforeSwap` with no try: a LinearSkim module reverts every swap until the 15 min cap. proof: `test_bug_H9_skimModuleOnStaticHookRevertsSwapsForWindow`.
- fix v2: hook declares the module interface it accepts; init checks `supportsInterface` of that kind.

### H10 low. static fee direction

- `ArtCoinsHookStaticFee.sol:58-60` uses `pairedFee` when paired is the input (a buy). `IArtCoinsHookStaticFee` documents `artCoinFee` as the buy fee. every deploy so far is symmetric, so no live impact. proof: `test_bug_H10_staticFeeDirectionInvertedVsDocs`.
- fix v2: rename to `buyFee` / `sellFee` and test both.

### H11 medium. open pools on the shared hook

- evidence: `ArtCoinsHook.sol:384-422` `initializePoolOpen` is permissionless for any `artCoin` with code (including factory coins), any paired token, any tickSpacing, any `feeData` (up to 90% skim, 10% lp fee, any recipients).
- state written per pool only: `artCoinIsToken0`, `poolCreationTimestamp`, `_skimConfig` (incl. `taxEnabled = true` for coin 111, since the flag is derived from the token). no global pollution; attestation is gated by `locker != 0` and by the token's pinned pool id, so no tax budget leaks.
- distinguishability: only `locker[pid] == 0` and the `PoolCreatedOpen` event. no version tag, no "official" flag, same hook address.
- attack path: make a coin 111 / ETH pool at tickSpacing 10 with a 90% skim to self, seed thin liquidity, catch misrouted volume or phish UIs that filter by hook address. buyers there also pay the 15% token tax.
- proof local: `test_bug_H11_openPoolForFactoryCoinOnSharedHook` (1 ETH buy pays the attacker > 0.89 ETH). live: `test_bug_H11_live_openPoolForCoin111` on the live hook.
- fix v2: no open path on the canonical hook (factory only `beforeInitialize`), or a separate hook for open pools; plus a per pool record `{factory, stackVersion, official}` readable on chain.

### H12 low. extension on open / ghost pools

- `setPoolExtension` (`ArtCoinsHook.sol:216-246`) checks token admin (`_artCoinFor` -> `artCoinIsToken0[id]`, false by default, so currency1) and the allowlist, not that the pool is a factory pool or even initialized. any token creator attaches an allowlisted extension to an open pool (the ban at `:413` is bypassed) or to a pool id that does not exist, and the extension's init callbacks run with `locker == 0` and an arbitrary key.
- proof: `test_bug_H12_setPoolExtensionBypassesOpenPoolBan`. impact depends on each allowlisted extension trusting `msg.sender == hook`.
- fix v2: require `locker[id] != 0` (factory pool) and initialized.

### H13 medium. self referral rebate

- evidence: `_processSkimAndAttribution` (`ArtCoinsHookSkimFee.sol:539-566`) takes `referrer` and `referralBps` straight from swapper hookData, clamps to `maxReferralBpsOfVolume`, pays out of the protocol leg. nothing binds the referrer to anyone but the swapper.
- live: cap 250 = 0.25% of volume; protocol leg = 6% x (1-0.8333) = 1% of volume, so self referral cuts protocol revenue ~25% for any trader who sets it. token admin can raise the cap to 1% (no lock, `:189-197`), which would zero the protocol leg at the live split.
- bounty leg is not affected (holds). malformed hookData cannot revert (tolerant decode, holds).
- proof: `test_bug_H13_selfReferralRebate` (1% cap: 0.01 ETH to the swapper, protocol 0.025 -> 0.015), live `test_bug_H13_live_selfReferralRebate` (0.0025 ETH per 1 ETH).
- fix v2: referrers must be registered (allowlist or signed by the frontend), or accept it as a rebate and price it in; freeze the cap at launch.

### H14 high. zero capital tax exemption budget

- evidence: `_afterRemoveLiquidity` (`ArtCoinsHookSkimFee.sol:455-467`) attests every canonical LP removal's PCT delta via `attestCanonicalBudget`. the budget is tx scoped and fungible (`ArtCoinsToken.sol:342-356`, `:282-305`). flash accounting lets an add and a remove of the same liquidity net to ~0 inside one unlock with no PCT ever transferred, yet the removal attests the full PCT amount. after the mev window `beforeAddLiquidity` allows anyone.
- attack path: one unlock: `modifyLiquidity(+L)` then `(-L)` on canonical in a PCT only range (attests ~any amount), then buy on a side venue (any other v4 pool; v2/v3 venues too) and `take`. the outflow consumes the budget, no tax. the router never holds PCT.
- proof local: `test_bug_H14_addRemoveCanonicalLiquidityMintsTaxBudget` (0.847 vs 0.996 received, burn sink 0). live: `test_bug_H14_live_addRemoveBudgetBypassesTax` on coin 111 with its real 15% tax: 1.185M vs 1.395M PCT.
- the canonical buy path has a weaker variant: buy then sell back on canonical in one unlock attests the buy; costs two skims, profitable only when tax > round trip cost.
- fix v2: attest only what actually leaves the PoolManager: net per tx of canonical outflows minus canonical inflows, or have the token check at transfer time that the PoolManager's outflow matches a canonical `take` (hard). simplest: drop the removal attestation and exempt LP exits by recipient (position manager / locker) instead, and make the budget non fungible (consume only by the same `to` the swap credits, via the router's recipient).

## other observations

| id | sev | note |
|---|---|---|
| N1 | low | `streamForward` and the bid push run with all gas while the PoolManager is unlocked by the swapper's router. a recipient can re enter `swap` (nested swap on the same pool is safe: accruals are zeroed before the push, `:704-706`), or burn gas. trusted at launch, but frozen. cap gas. |
| N2 | low | extension sees `amountSpecified` instead of the fill on partial fills (`ArtCoinsHook.sol:903-909`, `ArtCoinsHookSkimFee.sol:368-374`), with an unchecked `int128(int256)` cast. volume counters over count limit order swaps. |
| N3 | low | base sniper flush pushes ERC20 to `sniperFeeRecipient` via `take` (`ArtCoinsHook.sol:727`); a blacklisting paired token (USDC) or a locked bad recipient bricks the next swap. ETH goes via escrow (ok). |
| N4 | info | extension `try` forwards 63/64 gas; an allowlisted extension can starve the rest of `_afterSwap` unless the swapper over provisions gas. |
| N5 | info | hook `receive()` accepts stray ETH with no sweep. |
| N6 | info | escrow `storeFeesNative` is `nonReentrant`; a swap made from inside an escrow `claim` ETH callback reverts. self affecting only. |

## claims that hold

| claim | evidence |
|---|---|
| fee split has no dust: `b + p + r == totalSkim`, burn and take balance exactly | `:535-566`, `:701-711`; baseline <= total since reported bps clamped to `[baseline, MAX]` (`:611-612`) |
| bounty leg cannot be reduced by a referral | referral capped at `protocolShare` (`:553`) |
| malformed hookData cannot revert a swap | `_decodeSwapDataTolerant` `ArtCoinsHook.sol:651-662`, `_decodeAttribution` `:632-653`; `HookMevDecodeTolerance` |
| skim hook has a protocol leg; "no protocol skim" only applies to the static hook | `HookCanonicalNoProtocolSkim` targets `ArtCoinsHookStaticFee`; `HookProtocolFeeNumeratorZero` targets legacy V2 on sepolia |
| skim hook is native ETH only, static hook supports ETH and ERC20 (WETH) pairs | `SkimFeeInitLib.sol:62-67`; `ArtCoinsHook.sol:432-448` |
| no division by zero | skim exact out denominator `>= 10_000`; module durations `>= 60s` / `> 0`; descending `timeDecay >= 1` |
| int128 bounds | `require(totalSkim <= int128.max)` `:317,:357`; sniper `:775` |
| delta signs | `require` on quote delta sign `:343,:346`; quote unspecified branch uses realized delta |
| lp fee bounds | skim `lpFee <= 10%` at init, set each swap (`:253`); static `<= 10%`; mev `<= 99%`, only raises (`ArtCoinsHook.sol:535-547`) |
| mev module cannot be replaced after launch | `mevModule[id]` written only in `initializePool`; no setter |
| a fee dialing module can revert swaps for at most 15 min | `mevModuleOperational` `:504-516` |
| hook entry points are PoolManager / factory / self gated | BaseHook `onlyPoolManager`; `onlyFactory`; `_runPoolExtensionHelper` self only |
| tax: open pools never earn budget | `locker != 0` gate `:485` plus token pool id check |
| decay starts at launch, same tx as pool init | factory `:246-264` |

## per pool state today (v2 must choose this boundary)

| state | set by | mutable after launch by | lockable |
|---|---|---|---|
| `artCoinIsToken0`, `poolCreationTimestamp`, `locker`, `mevModule` | factory at init | nobody | n/a |
| skim `baselineSkimBps`, `bountyBps`, `lpFee`, recipients, `quoteToken`, `taxEnabled` | factory at init | nobody | n/a |
| skim `maxReferralBpsOfVolume` | factory at init | token admin, `<= 1%` | no |
| static `artCoinFee`, `pairedFee` | factory at init | nobody | n/a |
| `poolExtension` | factory at init | token admin, allowlisted ext | yes, one way |
| `sniperFeeRecipient` | factory | token admin | yes, one way |
| mev module schedule | module init | nobody | n/a |

| global | owner |
|---|---|
| hook `factory`, `poolExtensionAllowlist`, `weth`, `feeEscrow` | immutable, hook has no owner |
| extension allowlist | allowlist owner/admins. disabling does not detach from existing pools |
| escrow depositors | escrow owner, add only |
| factory `enabledHooks`, `enabledMevModules` | factory owner/admin, affects new launches only |

## not verified

- legacy hooks (`src/hooks/legacy/**`), LAYER's live pool.
- each allowlisted extension's behaviour under H12 (which extensions are enabled live was not enumerated).
- coin 111 bounty recipient `0x8C72…` internals beyond "implements streamForward, returns 0"; whether it is upgradeable (H1/H2 would then apply via upgrade).
- token admin `0xA96a…` powers (setMaxReferralBpsOfVolume, setTaxBps) in practice.
- aggregator behaviour with price limits (H4 real world frequency).
