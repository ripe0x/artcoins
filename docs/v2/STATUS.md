# artcoins v2 — status

running log for the unattended v2 session. a restarted session should read this first, then DECISIONS.md.

## local director session (2026-10-06 evening, owner's mac)

worktree `.claude/worktrees/artcoins-v2-handoff-8404d2`, local branch `v2-director` tracking `origin/v2` (push with `git push origin HEAD:v2`). forge 1.7.1 binary from the scratchpad, ci profile where the command says so. see HANDOFF lessons for the submodule and port setup.

| group | command (HANDOFF "how to run tests") | expected | result at 72479ce |
|---|---|---|---|
| v2 unit | unit command | 235 | 235 pass |
| v2 fork | fork command, block 26130269 | 354 | 354 pass |
| deploy rehearsal | DeployV2Stack.fork.t.sol | 6 | 6 pass |
| review proofs | review, review-v2 | 94 | 94 pass |
| sizes | ci profile | hook 16,716 | hook 16,716, headroom 7,860 |
| keeper runner | `cd keeper && npm test` with `MAINNET_RPC_URL` and ci artifacts built | 70 | 70 pass |
| ui unit, build, lint | `cd ui && npm test && npm run build && npm run lint` | 74 | 74 pass, build and lint green |
| ui e2e | anvil fork on port 8546, v2 stack deployed, `E2E_FORK_RPC=http://127.0.0.1:8546` | 19 | 19 pass after the harness fix: console load errors are judged by resource url against an allowlist of third party hosts (api.web3modal.org 403, pulse.walletconnect.org 400, ipfs.io 429). first run gave 3 pass, 10 fail, 6 not run on those errors alone |

after D65 to D70 (merged head, same commands):

| group | result |
|---|---|
| v2 unit | 238 pass |
| v2 fork | 364 pass |
| deploy rehearsal | 6 pass |
| review proofs | 101 pass |
| sizes (ci) | hook 16,716, factory 20,424, deployer 21,166, locker 13,626, dev buy 4,367, controller 3,971 |
| keeper runner | 70 pass |
| ui unit, build, lint | 74 pass, green |
| registry `--build --require-artifacts` | 56 contracts, 2 coins, 0 drift, 0 warnings |
| `DRY_RUN=0 script/v2/deploy.sh local` on an anvil fork | post deploy asserts ok, 10 contracts 0 drift, record tmp/v2-local-1.json |
| ui e2e on that record | 18 pass, 1 timeout in the wallet dialog (`05-deploy-closed`, element detached during the connect click); the spec passes 3 of 3 on rerun |
| `DRY_RUN=1 script/v2/deploy.sh mainnet` | refuses: TREASURY unset (owner to set TREASURY, TREASURY_BPS, DEPLOY_FEE, PROTOCOL_BPS in script/v2/env/mainnet.env) |

| open item (HANDOFF) | state |
|---|---|
| 1 runbook part 1 | owner ran action 1 (block 26135717) and action 5 (26135720, 26135723) before this session. open: action 2 collect LAYER, action 4 deprecate 0xf051, action 3 deploy 111 helper, action 8 claim owner LAYER fees. all simulated at block 26136123 |
| 2 audit tags | done. `v2-audit-1` = 9fed001, `v2-audit-2` = d8575db pushed to origin; the mirror job skipped both (not on master), public repo has none |
| D65 to D68 | accepted (D69), implemented, reviewed, merged; tag `v2-audit-3` is the reviewer's recheck target. D70 records the FeeDelivery revert |
| ui finding (item 12) | the ui loads coin images from one public gateway (`IPFS_GATEWAY = https://ipfs.io/ipfs/` in ui/src/lib/security.ts). ipfs.io answered 429 during the e2e run, so visitors see broken images whenever it throttles. fix before the site deploy: a gateway fallback list or a dedicated gateway |

## environment (session of 2026-10-06)

| item | state |
|---|---|
| mainnet rpc | opened at 02:40 utc (owner switched the environment to open internet). tenderly public gateway, rate limited. fork tests run from then on. before that, local v4 from pinned libs. |
| attachments | artcoins-audit.md, artcoins-audit-full.tar.gz, credits-engine.bundle were not present in the container. working from the bug list in the brief. |
| forge/anvil/cast | 1.7.1 installed from the npm `@foundry-rs/*-linux-amd64` packages (github releases denied) |
| solc | native 0.8.26 from 02:40 utc; before that a node shim over solc-js 0.8.26 (same commit 8a97fa7a). |
| branch | `v2` in the private working repo ripe0x/new-material-coin-launcher (pr #35). the day one copy on the public mirror (ripe0x/artcoins v2, pr #34) is to be deleted by the owner (D63). never master. |

## jobs

| # | job | state | notes |
|---|---|---|---|
| 1 | deployment registry | done. registry verified on chain; readme, AGENTS.md, ui config, 32 scripts and script-js read from the registry via generated Addresses.sol / deployments.generated.ts; 27 wrong or stale sites fixed (docs/v2/review/address-wiring.md). |
| 2 | full system review | done. docs/v2/SYSTEM-REVIEW.md: 8 area reviews with 70 v1 proof tests, a v2 second pass (4 reviews, 38 findings, all resolved or accepted), ci hygiene fixed | |
| 3 | v2 contracts + fixes | done on the branch, not deployed. src/v2: factory, deployer, token, hook, locker, escrow, fee delivery, mev module, swapper, burn router, fee controller, airdrop, vault, dev buy, renderers, two keepers, constants. 578 v2 tests green. | |
| 4 | ops runbook | done. docs/v2/RUNBOOK.md: 10 owner actions simulated with cast (all succeed today), v2 rollout order matching script/v2/DeployV2Lib.sol, 14 gate public checklist | |
| 5 | pull request + report | done: https://github.com/ripe0x/artcoins/pull/34 (draft) | |

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

wave 2 running (from 03:40 utc): a0 constants+interfaces done; k1 keeper for 111 done (src/v2/keepers/CollectFlushKeeperV1.sol, 7/7 fork tests, docs/v2/review/keeper-111.md); m1 mev done; u1 ui done (v2 abis and encoder, deploy gating on deprecated()/deployFee(), native pool swaps, sell path proved on fork, build and lint green, docs/v2/review/ui-fixes.md); l1 locker/escrow/delivery done (53 fork tests, LF-01 regression, sizes 13,411 / 3,883); k1 part 2 generic keeper done (31 tests); t1 token and deployer done (56 tests, 5 on fork; sizes 12,363 / 20,838); r1 renderers done (23 tests, all renderers under the 8m budget at D30 caps); p1 periphery done (72 fork tests incl. D31, D32, D39, D40, D50; swapper 9,158, burn router 9,342, controller 3,935 bytes); e1 extensions done (58 tests, dev buy on fork); h1 hook done (53 fork tests, 16,230 bytes at runs 200, docs/v2/review/h1-notes.md); f1 factory done (34 fork tests on the real locker; 19,577 bytes at runs 200; D38 deployer split, D47 exempt allowlist, D52 referral floor, D53 min lp fee); t1 D34 netting done (62 tests); h1 final: D41 stipend pushes and no probe, D43/D46 taxed pools close liquidity after arming, D52 protocol floor, D58 refunds via escrow with refund address (65 fork tests, 16,716 bytes, headroom 7,860).

wave 2 plan was: v2 implementation packages from DESIGN.md, registry wiring into readme/ui/scripts, runbook, keeper helper. wave 3: independent reviews of v2 with proof tests, regression tests, SYSTEM-REVIEW.md, pr.

## wave 3 (independent reviews of v2 and fixes)

| review | output | state |
|---|---|---|
| review a: token, locker, escrow, mev, keepers | docs/v2/review/v2-review-a.md, test/v2/review-v2/a/ | done: 1 high (liquidity round trips manufacture grants; fixed by D46), 1 medium (arbitrary exempt contracts; fixed by D47), 3 low |
| review b: periphery, extensions, renderers | docs/v2/review/v2-review-b.md, test/v2/review-v2/b/ | done: 2 medium (burn router floor counts refunds; swapper sandwich; fixed by D39, D40) |
| review hook | docs/v2/review/v2-review-hook.md, test/v2/review-v2/hook/ | done: 1 high (recipient code runs during the swap; fixed by D41, pushes with 2,300 gas and no probe), 1 medium (HARD add then remove; fixed by D43/D46), 4 low |
| review factory | docs/v2/review/v2-review-factory.md | done: 1 medium (referrals drain the protocol leg; fixed by D52), 3 low (D53, D54, D55) |
| fixes | every medium and above from the v2 reviews is fixed and covered by a regression; the review proofs are flipped to regressions (test/v2/review-v2, 24 pass) |
| s1 deploy script | script/v2/DeployV2Lib.sol, DeployV2Stack.s.sol, LaunchV2Coin.s.sol, verify-v2.sh, README.md, test/v2/DeployV2Stack.fork.t.sol | done: fork dry run passes every post deploy check (30 txs, ~29.5m gas) |
| i1 integration | test/v2/integration/**, test/v2/IntegrationV2.fork.t.sol | done: 28 tests, every treasury shape, both tax modes, fee flow balanced to the wei |

## wave 4 (after the owner's morning review: continue toward deploy)

| item | output | state |
|---|---|---|
| k3 weth aware keeper for LAYER (optional per D64: a layer keeper already runs in ripe0x/new-material) | src/v2/keepers/CollectFlushKeeperLayer.sol, test/v2/KeeperLayer.fork.t.sol, script/v2/RunKeeperLayer.s.sol, keeper-111.md (LAYER keeper), RUNBOOK action 2b and gate 9b | done: 11/11 fork tests at the pin. collect, claim router and controller slots, split, burn LAYER and weth on 0x2eDB, 0xE600, 0x0EB2; owner slot never claimed. no LF-02 shape on LAYER (recipients book by balance). gas sweep 23 completed, 24 reverted, 0 skipped. run arg is a LAYER per weth rate, not an absolute minOut |
| github ci red on v2 | .github/workflows/test.yml fixes, docs/v2/review/hygiene-fixes.md | done: cause was the no network job compiling 431 files in one process (runner killed, oom); build and v1 tests now run in batches; the four floor bound v1 fork tests skip with reasons; fork job locally 402 pass 0 fail 7 skip. github run on baded9a pending |
| registry verifier profile aware bytecode compare | script-js/verify-registry.mjs, deployments/mainnet.json source.profile, registry.yml | done: 0 drift; 18 bytecode rows stay mismatch because the repo history starts 2026-06-13, after every stack was live, so the deployed source of the older contracts is not in git (documented per contract) |
| ui airdrop claim v2 abi (V2B-04), S-01 renounce guard, keeper test decoupled from swapper Config | ui/, script/DeployConversionLockerAndWire.s.sol, test/v2/DeployV2Stack.fork.t.sol | done |
| browser smoke of the ui on an anvil fork (playwright) | ui/e2e/, docs/v2/review/ui-e2e.md | done: 19/19 after fixing the six bugs it found (LAYER not tradeable, sell above balance, browser clock deadlines, stale referral copy, v2 notice wording, 111 contractURI gas). `cd ui && npm run test:e2e` |
| k4 hosted keeper runner (fly.io) | keeper/ (node 22, viem), keeper/README.md, docs/v2/review/keeper-runner.md, ci job `keeper`, RUNBOOK actions 3 and 2b hosted runner rows | done: 41/41 (`cd keeper && npm ci && npm test`, incl. one anvil fork run at 26130269: 111 run quoted and converted at 869,690 gas, LAYER run 686,184 gas, restart on the state file sends nothing). image built and run locally. fly itself, the private relay and v2 on a real stack not tested. registry ROLES has no `keeper` role yet |

## how to run tests

all commands assume `source .env` with `MAINNET_RPC_URL` (tenderly public gateway works) and forge 1.7.1. full numbers and the exact ci commands are in docs/v2/review/test-run.md.

| group | command | result |
|---|---|---|
| whole v2 tree, fork | `FOUNDRY_PROFILE=ci forge test --match-path "test/v2/**" --fork-url $MAINNET_RPC_URL --fork-block-number 26130269 --fork-retries 8 --fork-retry-backoff 2000` | 343 pass |
| v2 unit suites, no fork | `forge test --match-path "test/v2/**" --match-contract "^(EscrowV2Test|FeeDeliveryTest|TokenV2Test|ConstantsV2Test|MevLinearSkimV2Test|KeeperV2Test|ProtocolFeeControllerV2Test|RendererV2Test|AirdropV2Test|VaultV2Test)$"` | 235 pass |
| v1 suites, no fork (ci `check`) | see .github/workflows/test.yml | 565 pass, 143 skipped (fork gated) |
| v1 + v2 fork suites (ci `fork-tests`) | see test.yml | 391 pass, 4 known v1 failures (burn router floor at the pinned block) |
| review proofs (v1 bugs + flipped v2 proofs) | `forge test --match-path "test/v2/{review,review-v2}/**" --fork-url ...` | 94 pass |
| sizes | `FOUNDRY_PROFILE=ci forge build --sizes --skip "test/**" --skip script` | hook 16,716 bytes, headroom 7,860; every v2 contract under 24,576 |
| ui | `cd ui && npm ci && npm test && npm run build && npm run lint` | 51 pass, build and lint green |
| registry | `node script-js/verify-registry.mjs` | 56 contracts, 2 coins, 0 drift (bytecode compare needs artifacts built at the stack's profile) |

note: a cold full tree compile of the stale v1 test set can reach ~14 gb of solc memory; warm the cache in batches (`forge build <paths>`) on small machines.
