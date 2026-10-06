# h1 notes: v2 hook

files: `src/v2/hooks/ArtCoinsHookV2.sol`, `src/v2/hooks/libraries/HookCalldata.sol`, `test/v2/HookV2.fork.t.sol`, `test/v2/mocks/HookV2ForkBase.sol`, `test/v2/mocks/HookV2Mocks.sol`. interface delta: `IArtCoinsHookV2.PoolInitParams.minProtocolShareBps` (D52, appended).

size at the ci profile (runs 200): 16,716 bytes runtime, 7,860 bytes headroom (gate 1,024). one contract, no cold module (D14). `src/hooks/legacy/ArtCoinsHookV2.sol` has the same contract name; scripts and `forge verify-contract` must use the path qualified name.

## current rules

| rule | decision | where |
|---|---|---|
| no recipient code with useful gas during a swap: legs pushed with gas 0, the callee runs on the evm's 2,300 stipend only; escrow on failure. `call{gas: 2300, value}` would give 4,600 | D41 | `_PUSH_GAS`, `_leg` |
| no `streamForward` probe. `setDeliveryParams` kept (bounded, stored, evented) but inert | D41 | |
| referral pushed straight to the referrer like other legs; `referralPayout` stays in the frozen config, not called during swaps | D41, D16 | `_split` |
| a recipient that `sync`s a currency from its stipend is undone (hook resets to native if it was native before the pushes) | V2H-01 hardening | `_afterSwap` |
| price limited over skim refunded via the escrow to `hookData` refund address (`mevModuleSwapData = abi.encode(address)`), else the PoolManager caller | b3, V2H-03 | `HookCalldata.refundTo` |
| referral base `volume` = realized pool side quote amount `r`, all four shapes | V2H-05 | |
| self referral via a router accepted, bounded by the frozen cap; caller cannot be referrer | D44, H13 | |
| referral never takes the protocol leg below `minProtocolShareBps` of the baseline skim | D52 | `_split` |
| taxed pool (VENUE, HARD): adds only before arming (`initializeMevModule`) and only in the creation block; nobody adds afterwards, launchers included, via PositionManager or PoolManager | D46 | `_beforeAddLiquidity` |
| taxed pool removals and collects attest (VENUE) or grant out (HARD) for any sender. safe only because adds are closed after arming | D46 | `_afterRemoveLiquidity` |
| bounty or protocol recipient = hook or PoolManager refused | V2H-08 | `_checkReceiver` |

## why D42 and D51 (refund inside the swap) are not implemented

| path | problem |
|---|---|
| afterSwap return delta (D51) | v4 applies the afterSwap return delta to the UNSPECIFIED currency only. the over charge exists only for exact in buy and exact out sell, where the quote (eth) is the specified currency and the unspecified one is the coin. an eth refund cannot ride it |
| `settleFor(sender)` (D42 first cut) | credits the caller's transient delta but not the BalanceDelta `swap()` returns. routers that settle the returned delta (dev buy, PoolSwapTest, many integrations) end with an unsettled credit and revert `CurrencyNotSettled` |
| escrow (kept) | returned delta == transient delta for every router. limits: V2H-06 (exact out seller's eth delta can be negative until the refund is claimed) and V2H-03 (a router that cannot claim, like the universal router, must pass a refund address) |

## review findings

| id | status |
|---|---|
| H1 H2 H3 H8 H11 H12 N2 N5 | fixed (first pass) |
| H4 H5 H7 | fixed: realized fill, escrow refund |
| H13 / V2H-04 | caller refused; router self referral accepted (D44), bounded by cap and D52 floor |
| H14 / V2H-02 / V2A-01 | closed by D46 (no lp on taxed pools after arming) |
| V2H-01 | fixed: stipend only pushes, no probe, sync reset |
| V2H-03 | refund address in hookData; default still the caller |
| V2H-05 | fixed |
| V2H-06 | documented (escrow refund) |
| V2H-07 | open: constructor cannot check the escrow (escrow needs the hook address first); deploy script (D36) |
| V2H-08 | fixed for hook and PoolManager; the escrow is mutable, not checked |
| V2F-01 | hook half fixed (D52) |

## residuals

| residual | note |
|---|---|
| a 2,300 gas recipient can still call cheap PoolManager functions (`sync`, `clear` of its own delta) | `sync` is reset when the caller had nothing synced; a caller that synced an erc20 before the swap (prepay style) can be disturbed. HARD forbids prepay; v4 routers sync right before settle |
| unarmed taxed pool | if a launcher never calls `initializeMevModule`, adds stay possible in the creation block only. the factory always arms in the launch tx |
| owner enabled extensions run between placement and arming | allowlisted code; no third party code runs in that window |

## reviewer suites after this pass

| suite | outcome | why |
|---|---|---|
| review-v2/hook `RvHardNettingTest` (V2H-02 x2) | setUp reverts `TaxedPoolLiquidityClosed` | the proof adds liquidity after arming |
| review-v2/hook `RvVenueNettingTest` (2 holds) | setUp reverts, same reason | same |
| review-v2/hook `RvGasTest` | passes | |
| review-v2/a `V2A01HardTest`, `V2A01VenueTest` | setUp reverts `TaxedPoolLiquidityClosed` | parked position added after arming |
| review-v2/a `V2A02ExemptTest` | passes (token scope) | |
| review-v2/b `test_holds_devBuy_partialFill_skimRefundReachesRecipient` | passes | escrow refund again |
| review-v2/factory `test_V2F01_*` | fails `LpFeeBelowMinimum` in the factory before the hook | factory D53 |
