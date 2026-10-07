# external review 1: verdict (as delivered by the reviewer)

target `9fed001e0d0ac7ef95ea161a71d4524c66a12833`, tag `v2-audit-1` (local tag; the git proxy refused the tag push, the owner tags on github). scope: the 42 files under src/v2 and src/Constants.sol. result: no new medium, high or critical vulnerability validated; three invariant statements overclaim the implementation (i1, i6, i11); no source patch warranted. fork suite 354 pass, unit 235 pass; sizes under the limit; swap gas buy 143,973 / sell 162,824 cold.

## invariant verdicts

| claim | verdict |
|---|---|
| i1 recipient isolation | broken as written: the 2,300 stipend lets `receive()` run and call `PoolManager.sync` (disclosed prepay caveat); revert, gas burn and returndata are contained |
| i2 hook balances, partial fills, deltas | holds with caveat (missing refund hookData credits the caller; temporary negative eth delta for an exact out seller) |
| i3 referral floor and conservation | holds |
| i4 taxed pool lp add gate | holds with caveat (trusted extensions can add in the pre arm window) |
| i5 HARD erc20 exits | holds with caveat (erc6909 internal claims, erc4337 shared grants) |
| i6 VENUE budget provenance | broken as written: canonical liquidity removals (the locker's collect) also attest budget; consumption still only from PoolManager outflows; no outsider bypass |
| i7 locker collection | holds |
| i8 escrow liabilities | holds with caveat (core depositor registration is a wiring precondition) |
| i9 launch address and refunds | holds |
| i10 burn and conversion bounds | holds |
| i11 setters, immutability, hash | broken as written: tax rate within cap, append only venues, metadata and admin setters are mutable; `BurnRouterV2.setMaxBurnPerCall` bounds are contract local, not in `Constants` |
| i12 size | holds |

## known residual severity

none rated higher than disclosed. an erc20 prepay style router should be tested before being declared supported.

## recommended next action

correct the three invariant statements, keep the router and deployment preconditions in the brief, recheck changed files only after `v2-audit-2`.
