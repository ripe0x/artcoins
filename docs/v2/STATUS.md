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
| repo hygiene | docs/v2/review/repo-hygiene.md | running |
| ui review | docs/v2/review/ui.md | running |
| scripts and keepers review | docs/v2/review/scripts-and-keepers.md | running |
| mainnet fork harness (replaced the local v4 plan once the rpc opened) | test/v2/harness/ForkBase.sol, ForkStack.sol, docs/v2/review/harness.md | running |
| contracts: factory/token/escrow | docs/v2/review/contracts-factory-token.md, test/v2/review/factory-token/ | running |
| contracts: hooks/mev | docs/v2/review/contracts-hooks-mev.md, test/v2/review/hooks-mev/ | running |
| contracts: locker/swapper/burn/protocol fee | docs/v2/review/contracts-locker-fees.md, test/v2/review/locker-fees/ | running |
| contracts: extensions/renderers | docs/v2/review/contracts-extensions-renderers.md, test/v2/review/extensions-renderers/ | running |
| v2 architect | docs/v2/DESIGN.md | running |

note: the first five wave 1 agents were killed by a session interrupt at 02:3x utc and relaunched at 02:45 utc with fork access.

wave 2 (after wave 1): v2 implementation packages from DESIGN.md, registry wiring into readme/ui/scripts, runbook, keeper helper. wave 3: independent reviews of v2 with proof tests, regression tests, SYSTEM-REVIEW.md, pr.

## how to run tests

see bottom of this file once the test layout is settled.
