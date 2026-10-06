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
| 1 | deployment registry | in progress | |
| 2 | full system review | in progress | |
| 3 | v2 contracts + fixes | not started | |
| 4 | ops runbook | not started | |
| 5 | pull request + report | not started | |

## wave 1 (running in parallel, started 02:10 utc)

| agent | output | state |
|---|---|---|
| registry miner | deployments/mainnet.json, script-js/verify-registry.mjs, .github/workflows/registry.yml, docs/v2/review/registry-notes.md | running |
| repo hygiene | docs/v2/review/repo-hygiene.md | done. 25 findings: mirror publishes any tag, origin is the public repo, broadcast has no record of the current stack, ~140 fork tests pass vacuously (return, not skip), foundry.lock mismatches 5 of 8 libs, no secrets in history. |
| ui review | docs/v2/review/ui.md | done. 25 findings, 8 high: mainnet addresses are zero, deployToken abi stale (wrong selector), deploy fee never sent, sell path always reverts, hook abi stale. ui is a stale fork and cannot launch on any live factory. |
| scripts and keepers review | docs/v2/review/scripts-and-keepers.md | done. 21 script findings (no script targets the current stack; DeployConversionLockerAndWire hardcodes the open 0xf051 factory and renounces ownership; verify-stack.sh exits 0 on failure); no keeper code exists; 111 swapper eth stranding proved on fork; live 111 has 13,404 coin uncollected. |
| mainnet fork harness (replaced the local v4 plan once the rpc opened) | test/v2/harness/ForkBase.sol, ForkStack.sol, docs/v2/review/harness.md | running |
| contracts: factory/token/escrow | docs/v2/review/contracts-factory-token.md, test/v2/review/factory-token/ | running |
| contracts: hooks/mev | docs/v2/review/contracts-hooks-mev.md, test/v2/review/hooks-mev/ (22 proof tests, 5 on fork vs live hook) | done. 14 findings, 2 high: tax bypass on live 111 via add then remove liquidity in one unlock (capital free, proved on fork); streamForward probe bricks swaps for eoa/empty fallback recipients. 6 medium: skim on unfilled price limited swaps, open pools on the live shared hook, self referral, eth refusing recipient bricks pool, referral payout without code bricks referred swaps, setPoolExtension on never created pools. |
| contracts: locker/swapper/burn/protocol fee | docs/v2/review/contracts-locker-fees.md, test/v2/review/locker-fees/ | running |
| contracts: extensions/renderers | docs/v2/review/contracts-extensions-renderers.md, test/v2/review/extensions-renderers/ | running |
| v2 architect | docs/v2/DESIGN.md | done. decisions D6 to D25 logged. |

note: the first five wave 1 agents were killed by a session interrupt at 02:3x utc and relaunched at 02:45 utc with fork access.

wave 2 (after wave 1): v2 implementation packages from DESIGN.md, registry wiring into readme/ui/scripts, runbook, keeper helper. wave 3: independent reviews of v2 with proof tests, regression tests, SYSTEM-REVIEW.md, pr.

## how to run tests

see bottom of this file once the test layout is settled.
