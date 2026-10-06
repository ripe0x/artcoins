# h1 notes: v2 hook

files: `src/v2/hooks/ArtCoinsHookV2.sol`, `src/v2/hooks/libraries/HookCalldata.sol`, `test/v2/HookV2.fork.t.sol`, `test/v2/mocks/HookV2ForkBase.sol`, `test/v2/mocks/HookV2Mocks.sol`.

size at the ci profile (runs 200): 16,230 bytes runtime, 8,346 bytes headroom. one contract, no cold module (D14). note: `src/hooks/legacy/ArtCoinsHookV2.sol` has the same contract name; scripts and `forge verify-contract` must use the path qualified name.

## review findings (contracts-hooks-mev.md)

| id | status | how |
|---|---|---|
| H1 | fixed | stream probe is a low level call, gas capped (`preSwapStreamGas`), no returndata copy, no decode, only when the recipient has code and balance >= `preSwapStreamMin` |
| H2 | fixed | every leg goes through `FeeDelivery.sendNative` (gas capped push, escrow on failure) |
| H3 | fixed | `referralPayout` must have code at init; `notify` is a low level capped call; failure credits the referrer in escrow (D16) |
| H4 H5 | fixed | quote specified skim trued up on the realized fill in `afterSwap`; unfilled share refunded to the PoolManager caller via escrow (D11, `SkimRefunded`) |
| H6 H7 | n/a, covered | no sniper lp fee path in v2; the anti sniper skim grosses up on exact out and is refunded on partial fills like H4 |
| H8 | fixed | hook expires any module at `createdAt + MAX_MEV_WINDOW` for both the skim clamp and the add lock |
| H9 H10 | n/a | static fee variant and lp fee modules dropped |
| H11 | fixed | `initializePoolOpen` removed; `_beforeInitialize` always reverts (the PoolManager skips it on the hook's own init); `poolInfo`, `isOfficialPool` |
| H12 | fixed | no extension setter; extension frozen at init, allowlist checked |
| H13 | mitigated | referrer == PoolManager caller refused; per pool cap frozen at init (<= 1% of volume, <= protocol share) bounds self referral through a second address |
| H14 | fixed for add then remove | same tx position marker (transient, keyed by the v4 position identity) skips attestation and out grants |
| N2 | fixed | extension sees the trader facing realized delta |
| N1 N4 | bounded | probe, pushes and extension are all gas capped |
| N5 | fixed | `receive` only from the PoolManager |

## residuals

| residual | status |
|---|---|
| remove then re add of a prior tx position in one unlock | closed by D34: the hook reports every canonical coin inflow (`grantCanonicalFlow(pid, 0, in)` on sells and lp adds, VENUE and HARD); the token cancels unused budget or out allowance. test `test_tax_removeThenAddSameTx_noNetBudget` |
| VENUE canonical buy then sell back in one unlock exempting a side pool buy | closed by D34. test `test_venue_roundTripThenSidePoolBuy_taxedInFull` |
| HARD unused per direction grants after flows net inside the PoolManager | closed by D34 token netting (at most one direction outstanding) |
| bounty recipient can front run a swap from inside the probe (150k gas, PoolManager unlocked) | open; recipient is frozen at launch and chosen by the launcher; swapper's price limit protects |
| HARD: increase then decrease of the same position in one tx reverts at take when it nets coin out | open, conservative b1 rule, document for integrators |

## bugs found by the suite and fixed in this package

| bug | effect | fix |
|---|---|---|
| module reads `and(staticcall(..), gt(returndatasize(), n))`: yul evaluates arguments right to left, so `returndatasize()` read the PREVIOUS call | anti sniper skim and add lock silently fell back to the baseline (fail open) | bind the call result first |
| redundant erc6909 mint in `beforeSwap` and burn in `afterSwap` | gas only | removed; the hook's specified delta is booked after `afterSwap`, `take` nets it |
| `setFeeEscrow` accepted an escrow that does not list the hook as core depositor | every failed push would revert swaps | additive error `EscrowNotCoreDepositor(address)` |
| add to an existing position netting coin out (fees > principal) got no grant | HARD: revert at take; VENUE: fee income taxed | `_afterAddLiquidity` attests or grants net coin out |
