# artcoins v2 — status

running log for the unattended v2 session. a restarted session should read this first, then DECISIONS.md.

## environment (session of 2026-10-06)

| item | state |
|---|---|
| mainnet rpc | opened at 02:40 utc (owner switched the environment to open internet). tenderly public gateway, rate limited. fork tests run from then on. before that, local v4 from pinned libs. |
| attachments | artcoins-audit.md, artcoins-audit-full.tar.gz, credits-engine.bundle were not present in the container. working from the bug list in the brief. |
| forge/anvil/cast | 1.7.1 installed from the npm `@foundry-rs/*-linux-amd64` packages (github releases denied) |
| solc | native 0.8.26 from 02:40 utc; before that a node shim over solc-js 0.8.26 (same commit 8a97fa7a). |
| branch | `v2` (also pushed to `claude/gallant-dirac-3dezg7` for the session). never master. |

## jobs

| # | job | state | notes |
|---|---|---|---|
| 1 | deployment registry | done. registry verified on chain; readme, AGENTS.md, ui config, 32 scripts and script-js read from the registry via generated Addresses.sol / deployments.generated.ts; 27 wrong or stale sites fixed (docs/v2/review/address-wiring.md). |
| 2 | full system review | in progress | |
| 3 | v2 contracts + fixes | not started | |
| 4 | ops runbook | docs/v2/RUNBOOK.md written: 10 owner actions simulated with cast call --from (all succeed today), v2 rollout order and public gate list. needs a final pass once DeployV2Stack exists (constructor args). | |
| 5 | pull request + report | draft pr open: https://github.com/ripe0x/artcoins/pull/34 (body replaced at the end) | |

## wave 1 (running in parallel, started 02:10 utc)

| agent | output | state |
|---|---|---|
| registry | deployments/mainnet.json, script-js/verify-registry.mjs, .github/workflows/registry.yml, docs/v2/review/registry-notes.md | done. verify passes on chain: 56 contracts, 2 coins, 0 drift. current stack matches repo head only under the ci profile (runs 200, with ipfs metadata). 0xf051 has zero coins, reports version 3, still open. broadcast folder: 4 mainnet runs are anvil rehearsals, 0x4959 stack unrecorded. |
| repo hygiene | docs/v2/review/repo-hygiene.md | done. 25 findings: mirror publishes any tag, origin is the public repo, broadcast has no record of the current stack, ~140 fork tests pass vacuously (return, not skip), foundry.lock mismatches 5 of 8 libs, no secrets in history. |
| ui review | docs/v2/review/ui.md | done. 25 findings, 8 high: mainnet addresses are zero, deployToken abi stale (wrong selector), deploy fee never sent, sell path always reverts, hook abi stale. ui is a stale fork and cannot launch on any live factory. |
| scripts and keepers review | docs/v2/review/scripts-and-keepers.md | done. 21 script findings (no script targets the current stack; DeployConversionLockerAndWire hardcodes the open 0xf051 factory and renounces ownership; verify-stack.sh exits 0 on failure); no keeper code exists; 111 swapper eth stranding proved on fork; live 111 has 13,404 coin uncollected. |
| mainnet fork harness | test/v2/harness/ForkBase.sol, ForkStack.sol, Harness.t.sol, docs/v2/review/harness.md | done. 8/8 at pinned block 26130269. existing skim fork suite 13/13, rehearsal 10/11 (burn router floor). |
| contracts: factory/token/escrow | docs/v2/review/contracts-factory-token.md, test/v2/review/factory-token/ (16 proof tests, 2 on fork) | done. high: free tax exemption on live 111 (same as hooks H14). medium: launch hijack on the open 0xf051 factory (proved on fork), protocol fee settable to 0 by any caller on 0xf051, admin can change image/metadata/tax rate post launch, arbitrary tax sink. 111 was launched with protocol fee 0. |
| contracts: hooks/mev | docs/v2/review/contracts-hooks-mev.md, test/v2/review/hooks-mev/ (22 proof tests, 5 on fork vs live hook) | done. 14 findings, 2 high: tax bypass on live 111 via add then remove liquidity in one unlock (capital free, proved on fork); streamForward probe bricks swaps for eoa/empty fallback recipients. 6 medium: skim on unfilled price limited swaps, open pools on the live shared hook, self referral, eth refusing recipient bricks pool, referral payout without code bricks referred swaps, setPoolExtension on never created pools. |
| contracts: locker/swapper/burn/protocol fee | docs/v2/review/contracts-locker-fees.md, test/v2/review/locker-fees/ (13 proof tests, 4 on fork) | done. CRITICAL live: `collectRewardsWithoutUnlock` on the live lockers (0x866e for 111, legacy for LAYER) is permissionless and takes the PositionManager's full credit inside the caller's unlock, so an attacker can have the coin's uncollected lp fees pay for their own position. exposure = fees accrued since the last collect. live mitigation: collect often (keeper). high: 111 swapper eth stranding; burn router clamp loopable (LAYER pool drained 1.9 of 2 weth on fork); live LAYER burn routers swap full balance with only an owner floor. |
| contracts: extensions/renderers | docs/v2/review/contracts-extensions-renderers.md, test/v2/review/extensions-renderers/ (19 proof tests, 2 on fork) | done. medium: live 111 contractURI costs ~177M gas (unreadable at 50M call caps; cost is in the permanent-collection renderer, outside this repo); airdrop merkle root replaceable after one day if unclaimed. low: svg text unescaped in three renderers, airdrop/vault zero admin locks funds, LL auto forward reverts on native pools, auto burn keeper reward never sends, dev buy min out can be zero. src/renderer gas is fine (the prior audit's gas claim was wrong for them). |
| v2 architect | docs/v2/DESIGN.md | done. decisions D6 to D25 logged. |

note: the first five wave 1 agents were killed by a session interrupt at 02:3x utc and relaunched at 02:45 utc with fork access.

note: a container restart at about 05:10 utc killed ten running agents; all were relaunched as resume agents on their on disk files at 05:20 utc.

wave 2 running (from 03:40 utc): a0 constants+interfaces done; k1 keeper for 111 done (src/v2/keepers/CollectFlushKeeperV1.sol, 7/7 fork tests, docs/v2/review/keeper-111.md); m1 mev done; u1 ui done (v2 abis and encoder, deploy gating on deprecated()/deployFee(), native pool swaps, sell path proved on fork, build and lint green, docs/v2/review/ui-fixes.md); l1 locker/escrow/delivery done (53 fork tests, LF-01 regression, sizes 13,411 / 3,883); k1 part 2 generic keeper done (31 tests); t1 token and deployer done (56 tests, 5 on fork; sizes 12,363 / 20,838); r1 renderers done (23 tests, all renderers under the 8m budget at D30 caps); h1 hook, p1 periphery, f1 factory, e1 extensions in progress.

wave 2 plan was: v2 implementation packages from DESIGN.md, registry wiring into readme/ui/scripts, runbook, keeper helper. wave 3: independent reviews of v2 with proof tests, regression tests, SYSTEM-REVIEW.md, pr.

## how to run tests

see bottom of this file once the test layout is settled.
