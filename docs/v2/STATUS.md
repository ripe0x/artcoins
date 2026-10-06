# artcoins v2 — status

running log for the unattended v2 session. a restarted session should read this first, then DECISIONS.md.

## environment (session of 2026-10-06)

| item | state |
|---|---|
| mainnet rpc | none reachable (every public rpc host and alchemy/infura denied by the sandbox egress policy). no fork tests possible here. |
| attachments | artcoins-audit.md, artcoins-audit-full.tar.gz, credits-engine.bundle were not present in the container. working from the bug list in the brief. |
| forge/anvil/cast | 1.7.1 installed from the npm `@foundry-rs/*-linux-amd64` packages (github releases denied) |
| solc | no native binary reachable; forge runs through a node shim over solc-js 0.8.26 (same commit hash 8a97fa7a). see scratchpad `bin/solc`. |
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
| local v4 harness | test/v2/harness/**, docs/v2/review/harness.md | running |
| contracts: factory/token/escrow | docs/v2/review/contracts-factory-token.md, test/v2/review/factory-token/ | running |
| contracts: hooks/mev | docs/v2/review/contracts-hooks-mev.md, test/v2/review/hooks-mev/ | running |
| contracts: locker/swapper/burn/protocol fee | docs/v2/review/contracts-locker-fees.md, test/v2/review/locker-fees/ | running |
| contracts: extensions/renderers | docs/v2/review/contracts-extensions-renderers.md, test/v2/review/extensions-renderers/ | running |
| v2 architect | docs/v2/DESIGN.md | running |

wave 2 (after wave 1): v2 implementation packages from DESIGN.md, registry wiring into readme/ui/scripts, runbook, keeper helper. wave 3: independent reviews of v2 with proof tests, regression tests, SYSTEM-REVIEW.md, pr.

## how to run tests

see bottom of this file once the test layout is settled.
