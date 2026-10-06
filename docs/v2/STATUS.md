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

## how to run tests

see bottom of this file once the test layout is settled.
