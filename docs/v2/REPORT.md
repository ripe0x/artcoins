# artcoins v2: report for the owner

branch `v2`, draft pr https://github.com/ripe0x/artcoins/pull/34. nothing deployed, nothing broadcast, no key used. 59 decisions logged in docs/v2/DECISIONS.md. this is not a formal audit.

## read first

| # | item | where |
|---|---|---|
| 1 | this branch is PUBLIC (origin is ripe0x/artcoins). review docs and proof tests on live contracts went public with the first push, as the brief instructed. decide whether that stands. | D26 |
| 2 | critical, live: anyone can redirect uncollected lp fees of 111 and LAYER through `collectRewardsWithoutUnlock` on the live lockers. exposure = fees accrued since the last collect. collect now and keep collecting. | SYSTEM-REVIEW LF-01, RUNBOOK actions 1, 2, 3 |
| 3 | high, live: a capital free tax bypass on 111 (add then remove liquidity in one unlock mints exemption budget). not owner fixable on the live stack. | H14 / FT-01, action 10 |
| 4 | the open factory 0xf051 is still public with a zero deploy fee; launch hijack proved on it. one owner tx closes it. | FT-02, action 4 |

## what is done, what is not

| job | state |
|---|---|
| 1 registry | done. deployments/mainnet.json derived from chain and broadcasts, verified on chain (56 contracts, 2 coins, 0 drift), ci job, readme / AGENTS.md / ui / 32 scripts read from it via generated files. 27 wrong or stale address sites fixed. |
| 2 system review | done. 8 area reviews with 70 v1 proof tests on a mainnet fork, then a second pass on v2 itself (4 reviews, 38 findings). docs/v2/SYSTEM-REVIEW.md. |
| 3 v2 stack | done on the branch, not deployed. 36 contracts under src/v2 plus src/Constants.sol; 578 v2 tests green on a mainnet fork at block 26130269. every audit bug and every design improvement from the brief is implemented, with the two exceptions below. |
| 4 runbook | done. docs/v2/RUNBOOK.md: 10 owner actions, each simulated with `cast call --from owner` (all succeed today), then the v2 rollout order and a 14 gate public checklist. |
| not done | (a) an in swap refund of the over charged skim is impossible in v4 (the return delta can only touch the unspecified currency); refunds go to the escrow for a refund address named in hookData (D58). (b) the credits engine bundle and the audit attachments were not in the container: the treasury interface is specified from assumptions (docs/v2/CREDITS-ENGINE-INTERFACE.md). (c) no mainnet deploy, by instruction. |
| where i stopped | everything in the brief is on the branch. a container restart mid run killed ten agents once; all resumed from disk. |

## registry summary

| fact | finding |
|---|---|
| current factory | 0x4959… (2026-06-06), deprecated, 0.069 eth fee, one coin (111). matches repo head only under the `ci` profile (optimizer_runs 200, with ipfs metadata); the default profile does not match. |
| open factory | 0xf051… is live, public, zero fee, zero coins, reports version "3", not head's "1". |
| what was wrong in the repo | broadcast/ has no record of the current stack; 4 "mainnet" broadcast runs were anvil rehearsals; the LAYER launch hash recorded is not on chain. ui had every mainnet address as zero and fell back to sepolia on unknown chains. no script targeted the current stack; the wiring script hardcoded 0xf051 and renounced ownership. AGENTS.md had the wrong date, README had no addresses. foundry.lock mismatched 5 of 8 submodules. |

## findings by area (full tables in SYSTEM-REVIEW.md)

| area | critical | high | medium | low | fixed in v2 |
|---|---|---|---|---|---|
| contracts: locker, swapper, burn router, controller | 1 | 2 | 1 | 6 | all; live contracts stay exposed (immutable), runbook mitigates |
| contracts: hooks, mev | 0 | 2 | 6 | 6 | all; H7, H9, H10 not applicable (surface dropped) |
| contracts: factory, token | 0 | 1 | 4 | 5 | all |
| contracts: extensions, renderers | 0 | 0 | 2 | 9 | all generic ones; LAYER specific extensions not ported (D27). 111's 177m gas contractURI is in the permanent collection renderer, outside this repo |
| scripts and ops | 0 | 3 | 8 | 10 | addresses and guards fixed; S-01 renounce path left unused |
| website | 0 | 8 | 10 | 7 | all except items that need the deployed v2 addresses |
| keepers | 0 | 1 | 3 | 2 | two keepers built (111 helper, generic v2) |
| ci and repo hygiene | 0 | 4 | 6 | 11 | fixed except the owner decisions (public origin, review material on merge) |
| v2 second pass | 0 | 2 | 5 | 13 | all medium and above fixed with regressions; 18 info items accepted or documented |

## test totals

| group | result |
|---|---|
| whole v2 tree, one fork invocation | 343 pass |
| v2 unit suites, no fork | 235 pass |
| ci `check` (v1, no fork) | 565 pass, 143 skipped (fork gated, now reported as skipped instead of passing vacuously) |
| ci `fork-tests` | 391 pass, 4 known v1 failures (LAYER burn router floor at the pinned block) |
| review proofs (v1 bugs plus v2 proofs flipped to regressions) | 94 pass |
| ui | 51 pass, build and lint green |
| sizes (ci profile) | hook 16,716 bytes (headroom 7,860); every v2 contract under 24,576 |

commands: docs/v2/STATUS.md "how to run tests" and docs/v2/review/test-run.md.

## decisions made for you (one line each; D1 to D59 in docs/v2/DECISIONS.md)

| id | decision |
|---|---|
| D5, D26 | tenderly public gateway as the default rpc; pushed to the public origin as instructed |
| D7 | boundary: every per coin field on hook and locker is written once at launch; owner keeps global pointers, bounded tunables, rescue of unowed balances |
| D10, D47 | tax sink is DEAD or the bounty recipient; exempt addresses come from an owner allowlist |
| D14 | no delegatecall cold module in the hook (headroom was ample) |
| D17 | v2 pools are native eth only |
| D20 | Ownable2Step everywhere, single eoa, no multisig or timelock |
| D22, D27 | lp fee mev modules and LAYER specific extensions not ported |
| D30 | token strings bounded (name 64, symbol 16, url 2,048, text 4,096 bytes) |
| D38 | deployer is a separate, replaceable contract |
| D41 | no recipient code runs during a swap: 2,300 gas stipend pushes, escrow fallback, stream probe removed |
| D46 | taxed pools: liquidity closes after arming (locker only); removals never grant exemptions |
| D52, D53 | referrals cannot take the protocol below its floor; min lp fee 0.3% |
| D58 | skim refunds via the escrow to a caller named refund address (in swap refund impossible in v4) |

## runbook items to do first (RUNBOOK.md part 1)

| order | action |
|---|---|
| 1 | collect 111 lp fees now (action 1), collect LAYER (action 2) |
| 2 | deploy and cron the 111 collect and flush keeper (action 3) |
| 3 | `setDeprecated(true)` on 0xf051 (action 4) |
| 4 | raise the LAYER burn router floors to ~95% of spot (action 5) |
| 5 | decide the LAYER freezes (action 6, irreversible) and claim the owner's unclaimed LAYER fees (action 8) |

## what an external auditor should look at first

1. hook swap path: skim accounting for four swap shapes, transient slots, stipend pushes and the `sync` reset, escrow refund path.
2. token HARD mode: transient per direction allowances, D34 netting, erc6909 claim residual.
3. taxed pool liquidity closure after arming and the removal grant invariant that depends on it.
4. locker collect path (the LF-01 class) and FeeDelivery fallback.
5. factory launch value accounting and validators (referral floor, min lp fee, exempt allowlist).
6. swapper and burn router floors and impact caps.
this is still not a formal audit; two independent passes by subagents with proof tests is what this is.

## credits engine interface changes

docs/v2/CREDITS-ENGINE-INTERFACE.md. in short: `streamForward` is never called; fees arrive by a 2,300 gas push or sit in the escrow for anyone to `claim(treasury, 0)`; coin side rewards need a `FeeAutoSwapperV2` slot registered as an escrow depositor; the treasury must be on the exempt allowlist if it is to hold the coin untaxed; the referral payout is the escrow; pools are native eth only.

## next steps between this branch and a mainnet deploy

| step | what |
|---|---|
| 1 | review D26 and the public exposure; run runbook actions 1 to 5 today |
| 2 | read DECISIONS.md and overrule what you disagree with; the boundary (D7), D41, D46, D58 are the ones that change behavior most |
| 3 | external review of the hook and the HARD mode token (gate 5 and 6) |
| 4 | ci green on github (note: a cold full tree compile needs ~14 gb; warm in batches or raise the runner) |
| 5 | `FOUNDRY_PROFILE=ci forge script script/v2/DeployV2Stack.s.sol --rpc-url $MAINNET_RPC_URL --sender $OWNER` dry run, then `--ledger --broadcast`, `acceptOwnership` x4, `script/v2/verify-v2.sh`, fill deployments/v2.template.json into mainnet.json, `node script-js/verify-registry.mjs` |
| 6 | pre launch owner calls for the credits engine coin: `setExemptAllowed(treasury)` if needed, `addDepositor(feeSwapper)`; then `LaunchV2Coin.s.sol` dry run and broadcast with `deployTokenAsOwner` while deprecated; run the v2 keeper once |
| 7 | ui: set the v2 stack (`VITE_V2_*` or the generator), run a fork launch and a referred swap through it |
| 8 | `setDeprecated(false)` last, after the 14 gates in RUNBOOK part 2c |
